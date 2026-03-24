#!/bin/bash
set -euo pipefail

# sandcastle — autonomous AI development loop
# Uses Docker Sandbox + ralph-loop plugin for iterative development

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SANDCASTLE_DIR=".sandcastle"
REPO=""
OWNER=""
BRANCH=""
ITERATIONS=100
MILESTONE=""
MILESTONE_FILTER=""
RUN_ALL=false
DRY_RUN=false
SINGLE_ISSUE=""

# --- Cleanup on exit ---

cleanup() {
  pkill -P $$ 2>/dev/null || true
  rm -f .sandcastle/issues.json .sandcastle/ralph-commits.txt
}
trap cleanup EXIT INT TERM

# --- Helpers ---

die() { echo -e "${RED}Error:${NC} $1" >&2; exit 1; }
info() { echo -e "${BLUE}$1${NC}"; }
success() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }

# --- Preflight Checks ---

preflight() {
  git rev-parse --is-inside-work-tree &>/dev/null \
    || die "Not in a git repo."

  [[ -f "$SANDCASTLE_DIR/prompt.md" ]] \
    || die "No prompt.md in .sandcastle/. Run /ralph to scaffold."

  docker info &>/dev/null \
    || die "Docker is not running. Start Docker Desktop 4.50+."

  gh auth status &>/dev/null \
    || die "GitHub CLI not authenticated. Run 'gh auth login'."

  REPO=$(gh repo view --json name -q '.name')
  OWNER=$(gh repo view --json owner -q '.owner.login')

  # Read config
  if [[ -f "$SANDCASTLE_DIR/config.json" ]]; then
    ITERATIONS=$(jq -r '.defaultIterations // 100' "$SANDCASTLE_DIR/config.json")
  fi
}

# --- Milestone Picker ---

pick_milestone() {
  if [[ "$RUN_ALL" == true ]]; then
    info "Processing all open issues"
    MILESTONE_FILTER=""
    BRANCH="ralph/all-$(date +%Y%m%d)"
    return
  fi

  if [[ -n "$SINGLE_ISSUE" ]]; then
    info "Processing single issue #${SINGLE_ISSUE}"
    MILESTONE_FILTER=""
    BRANCH="ralph/issue-${SINGLE_ISSUE}"
    return
  fi

  local milestones
  milestones=$(gh api "repos/${OWNER}/${REPO}/milestones?state=open&per_page=100" 2>/dev/null)

  local count
  count=$(echo "$milestones" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    warn "No open milestones found. Use --all to process all open issues."
    exit 0
  fi

  echo ""
  echo "=== Select Milestone ==="
  echo ""

  local i=1
  echo "$milestones" | jq -r '.[] | "\(.title)|\(.open_issues)|\(.closed_issues)|\(.description // "")"' | while IFS='|' read -r title open closed desc; do
    local total=$((open + closed))
    local desc_short="${desc:0:60}"
    echo "  $i. ${title} (${open} open / ${total} total) ${desc_short}"
    i=$((i + 1))
  done

  echo ""
  read -rp "Enter number or 'all': " choice

  if [[ "$choice" == "all" ]]; then
    RUN_ALL=true
    MILESTONE_FILTER=""
    BRANCH="ralph/all-$(date +%Y%m%d)"
    return
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$count" ]]; then
    die "Invalid selection: $choice"
  fi

  local idx=$((choice - 1))
  MILESTONE=$(echo "$milestones" | jq -r ".[$idx].title")
  local open_count
  open_count=$(echo "$milestones" | jq -r ".[$idx].open_issues")

  if [[ "$open_count" -eq 0 ]]; then
    success "All issues in '${MILESTONE}' are closed. Nothing to do."
    exit 0
  fi

  MILESTONE_FILTER="$MILESTONE"
  BRANCH="ralph/$(echo "$MILESTONE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')"

  info "Selected milestone: ${MILESTONE} (${open_count} open issues)"
}

# --- Git Setup ---

setup_branch() {
  info "Setting up branch: ${BRANCH}"

  # Stash any dirty state before switching branches
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git stash --include-untracked 2>/dev/null || true
  fi

  git fetch origin 2>/dev/null || true

  if git show-ref --verify "refs/remotes/origin/${BRANCH}" &>/dev/null; then
    git checkout "${BRANCH}" 2>/dev/null || git checkout -b "${BRANCH}" --track "origin/${BRANCH}"
    git pull origin "${BRANCH}" --rebase 2>/dev/null || true
  else
    git checkout -b "${BRANCH}" 2>/dev/null || git checkout "${BRANCH}"
  fi

  # Restore stashed changes
  git stash pop 2>/dev/null || true

  success "On branch ${BRANCH}"
}

# --- Prepare Context ---

prepare_context() {
  info "Preparing issue context..."

  # Fetch issues (lightweight: number + title only)
  local issue_args="--state open --json number,title,labels --limit 10"
  if [[ -n "$MILESTONE_FILTER" ]]; then
    issue_args="$issue_args --milestone \"${MILESTONE_FILTER}\""
  fi

  local issues
  if [[ -n "$SINGLE_ISSUE" ]]; then
    issues=$(gh issue view "${SINGLE_ISSUE}" --json number,title,body,labels 2>/dev/null)
  else
    issues=$(eval "gh issue list ${issue_args}" 2>/dev/null)
  fi

  local commits
  commits=$(git log --grep='RALPH:' --oneline -10 --format='%h %ad %s' --date=short 2>/dev/null || echo "No RALPH commits yet")

  # Write to .sandcastle/ (Docker sandbox mounts the working dir)
  echo "$issues" > .sandcastle/issues.json
  echo "$commits" > .sandcastle/ralph-commits.txt

  local issue_count
  issue_count=$(echo "$issues" | jq 'if type == "array" then length else 1 end' 2>/dev/null || echo "0")
  info "Issues: ${issue_count} | RALPH commits: $(echo "$commits" | wc -l | tr -d '[:space:]')"
}

# --- Build Prompt ---

build_prompt() {
  # Read the static prompt template
  local prompt_content
  prompt_content=$(cat "$SANDCASTLE_DIR/prompt.md")

  # The prompt for /ralph-loop — Claude reads the files itself
  cat <<EOF
$prompt_content

# CONTEXT FILES
Read these files for current state:
- .sandcastle/issues.json — open GitHub issues (use 'gh issue view #N' for full details)
- .sandcastle/ralph-commits.txt — recent RALPH commits showing completed work

ONLY WORK ON A SINGLE TASK.
Use 'gh issue view #N' to read the full details of the issue you pick.
Commit with RALPH: prefix. Close the issue when done.
Push your commits with 'git push origin ${BRANCH}'.
EOF
}

# --- Run Loop ---

run_loop() {
  local loop_start_time=$SECONDS

  for i in $(seq 1 "$ITERATIONS"); do
    echo ""
    echo "=== Iteration ${i}/${ITERATIONS} === $(date '+%H:%M:%S') ==="
    echo ""

    # Refresh issues each iteration (reflects closed issues from prior iterations)
    prepare_context

    if [[ "$DRY_RUN" == true ]]; then
      info "[DRY RUN] Would run agent"
      continue
    fi

    local iter_start=$SECONDS
    local output_file="/tmp/sandcastle-output-${i}.txt"
    > "$output_file"

    info "Running agent..."

    # Background file watcher — monitors git activity every 30s
    # since docker sandbox buffers all -p output until completion
    local last_commit_hash
    last_commit_hash=$(git rev-parse HEAD 2>/dev/null || echo "none")
    local last_file_count=0
    (
      while true; do
        sleep 30
        local elapsed=$(( SECONDS - iter_start ))
        local mins=$(( elapsed / 60 ))

        # Check for new commits
        local current_hash
        current_hash=$(git rev-parse HEAD 2>/dev/null || echo "none")
        if [[ "$current_hash" != "$last_commit_hash" ]]; then
          local new_msg
          new_msg=$(git log --oneline -1 2>/dev/null)
          echo -e "\033[0;32m  [${mins}m] NEW COMMIT: ${new_msg}\033[0m"
          last_commit_hash="$current_hash"
        fi

        # Check for file changes
        local changed
        changed=$(git status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')
        if [[ "$changed" -gt 0 ]] && [[ "$changed" -ne "$last_file_count" ]]; then
          local latest_file
          latest_file=$(git status --porcelain 2>/dev/null | tail -1 | sed 's/^...//')
          echo -e "\033[0;33m  [${mins}m] ${changed} files changed — latest: ${latest_file}\033[0m"
          last_file_count="$changed"
        elif [[ "$changed" -eq 0 ]] && [[ "$last_file_count" -eq 0 ]]; then
          echo -e "\033[0;34m  [${mins}m] agent working...\033[0m"
        fi
      done
    ) &
    local watcher_pid=$!

    # Build the full prompt by reading files (@ syntax doesn't work in -p mode)
    local prompt_content issues_content commits_content full_prompt
    prompt_content=$(cat "$SANDCASTLE_DIR/prompt.md")
    issues_content=$(cat .sandcastle/issues.json 2>/dev/null || echo "[]")
    commits_content=$(cat .sandcastle/ralph-commits.txt 2>/dev/null || echo "No RALPH commits yet")

    full_prompt="${prompt_content}

# OPEN ISSUES
${issues_content}

# RECENT RALPH COMMITS
${commits_content}

ONLY WORK ON A SINGLE TASK.
Use 'gh issue view #N' to read the full details of the issue you pick.
Commit with RALPH: prefix. Close the issue when done.
Push your commits with 'git push origin ${BRANCH}'.
If all tasks are complete, output <promise>COMPLETE</promise>."

    # Write prompt to temp file to avoid shell arg length limits
    local prompt_file
    prompt_file=$(mktemp /tmp/sandcastle-prompt-XXXXXX.md)
    echo "$full_prompt" > "$prompt_file"

    # Run Claude in Docker Sandbox — one invocation per iteration
    # Note: docker sandbox buffers -p output until completion
    docker sandbox run claude -- \
      --dangerously-skip-permissions \
      --model sonnet \
      --max-turns 75 \
      -p "$(cat "$prompt_file")" \
      2>&1 | tee "$output_file" || true

    rm -f "$prompt_file"

    # Stop watcher
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true

    # Check for auth failure — don't keep looping if not authenticated
    if grep -q 'authentication_error\|Failed to authenticate\|Not logged in' "$output_file" 2>/dev/null; then
      echo ""
      die "Authentication failed. Run 'docker sandbox run claude' to log in first, then retry."
    fi

    # Iteration summary
    local iter_elapsed=$(( SECONDS - iter_start ))
    local iter_mins=$(( iter_elapsed / 60 ))
    local iter_secs=$(( iter_elapsed % 60 ))
    echo ""
    info "Iteration ${i} completed in ${iter_mins}m ${iter_secs}s"

    # Show recent commits
    local new_commits
    new_commits=$(git log --oneline -3 --since="$(( iter_elapsed + 10 )) seconds ago" 2>/dev/null || true)
    if [[ -n "$new_commits" ]]; then
      info "Recent commits:"
      echo "$new_commits" | sed 's/^/  /'
    fi

    # Check for COMPLETE signal
    if grep -q '<promise>COMPLETE</promise>' "$output_file" 2>/dev/null; then
      rm -f "$output_file"
      success "All tasks complete!"
      break
    fi
    rm -f "$output_file"

    # Auto-commit any uncommitted work (skip hooks — these are RALPH auto-commits)
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      warn "Auto-committing uncommitted changes..."
      git add -A
      git commit --no-verify -m "RALPH: auto-commit work from iteration ${i}"
    fi

    # Push after each iteration
    git push origin "${BRANCH}" 2>&1 || true

    # Total elapsed
    local total_elapsed=$(( SECONDS - loop_start_time ))
    local total_mins=$(( total_elapsed / 60 ))
    info "Total elapsed: ${total_mins}m | Next: iteration $((i + 1))/${ITERATIONS}"
  done
}

# --- Post-Loop ---

post_loop() {
  # Clean up temp files
  rm -f .sandcastle/issues.json .sandcastle/ralph-commits.txt

  # Auto-commit any leftover uncommitted work (skip hooks)
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    warn "Auto-committing uncommitted changes..."
    git add -A
    git commit --no-verify -m "RALPH: auto-commit final uncommitted work"
  fi

  # Push
  git push origin "${BRANCH}" 2>&1 || true

  # Show summary
  echo ""
  info "=== Summary ==="
  local ralph_commits
  ralph_commits=$(git log --grep='RALPH:' --oneline --format='  %h %s' -20 2>/dev/null || echo "  No RALPH commits")
  echo "$ralph_commits"

  # Create PR
  create_pr

  # Notify
  local milestone_label="${MILESTONE_FILTER:-all issues}"
  notify "$milestone_label" "Ralph finished processing ${milestone_label}"
}

# --- PR Creation ---

create_pr() {
  local commit_count
  commit_count=$(git log origin/main..HEAD --oneline 2>/dev/null | wc -l | tr -d '[:space:]')

  if [[ "$commit_count" -eq 0 ]]; then
    warn "No changes made. Skipping PR creation."
    return
  fi

  local target_branch="develop"
  git ls-remote --heads origin develop 2>/dev/null | grep -q develop || target_branch="main"

  local pr_title
  if [[ -n "$MILESTONE_FILTER" ]]; then
    pr_title="[Ralph] ${MILESTONE_FILTER}"
  else
    pr_title="[Ralph] All issues — $(date +%Y-%m-%d)"
  fi

  git push origin "${BRANCH}" 2>&1 || die "Failed to push branch"

  local existing_pr
  existing_pr=$(gh pr list --head "${BRANCH}" --json url -q '.[0].url' 2>/dev/null || true)

  if [[ -n "$existing_pr" ]]; then
    info "PR already exists: ${existing_pr}"
    return
  fi

  local commit_log
  commit_log=$(git log --grep='RALPH:' --oneline --format='- %h %s' -20 2>/dev/null || echo "- No commits")

  gh pr create \
    --title "${pr_title}" \
    --base "${target_branch}" \
    --head "${BRANCH}" \
    --body "$(cat <<EOF
## Ralph Autonomous Run

### Commits
${commit_log}

### Stats
- Iterations: up to ${ITERATIONS}
- Milestone: ${MILESTONE_FILTER:-all issues}

---
_Generated by [sandcastle](https://github.com/derekc00/sandcastle)_
EOF
)" 2>&1 || warn "PR creation failed"
}

# --- Notification ---

notify() {
  local title="$1"
  local message="$2"
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"${message}\" with title \"Sandcastle\" subtitle \"${title}\"" 2>/dev/null || true
  fi
}

# --- CLI ---

usage() {
  echo "Usage: sandcastle <command> [options]"
  echo ""
  echo "Commands:"
  echo "  run         Start the autonomous development loop"
  echo ""
  echo "Options:"
  echo "  --all       Process all open issues (skip milestone picker)"
  echo "  --issue N   Process a single issue"
  echo "  --dry-run   Show what would be done without doing it"
  echo "  --help      Show this help"
}

parse_args() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    run) ;;
    --help|-h|help|"") usage; exit 0 ;;
    *) die "Unknown command: $cmd. Run 'sandcastle --help'." ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) RUN_ALL=true ;;
      --issue) SINGLE_ISSUE="${2:-}"; [[ -n "$SINGLE_ISSUE" ]] || die "--issue requires an issue number"; shift ;;
      --dry-run) DRY_RUN=true ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

# --- Main ---

main() {
  parse_args "$@"

  echo ""
  echo "=== SANDCASTLE RUN ==="
  echo ""

  preflight

  echo "Repo:       ${OWNER}/${REPO}"
  echo "Iterations: ${ITERATIONS}"
  echo ""

  pick_milestone
  setup_branch
  run_loop

  if [[ "$DRY_RUN" != true ]]; then
    post_loop
    echo ""
    success "=== SANDCASTLE COMPLETE ==="
  fi
}

main "$@"
