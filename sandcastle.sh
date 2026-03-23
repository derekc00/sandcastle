#!/bin/bash
set -euo pipefail

# sandcastle — autonomous AI development loop
# Uses Docker Sandbox + Claude Code to implement GitHub issues

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

  git fetch origin 2>/dev/null || true

  if git show-ref --verify "refs/remotes/origin/${BRANCH}" &>/dev/null; then
    git checkout "${BRANCH}" 2>/dev/null || git checkout -b "${BRANCH}" --track "origin/${BRANCH}"
    git pull origin "${BRANCH}" --rebase 2>/dev/null || true
  else
    git checkout -b "${BRANCH}" 2>/dev/null || git checkout "${BRANCH}"
  fi

  success "On branch ${BRANCH}"
}

# --- Issue Fetching ---

fetch_issues() {
  local issue_args="--state open --json number,title,body,labels --limit 30"

  if [[ -n "$MILESTONE_FILTER" ]]; then
    issue_args="$issue_args --milestone \"${MILESTONE_FILTER}\""
  fi

  if [[ -n "$SINGLE_ISSUE" ]]; then
    gh issue view "${SINGLE_ISSUE}" --json number,title,body,labels 2>/dev/null
    return
  fi

  eval "gh issue list ${issue_args}" 2>/dev/null
}

fetch_ralph_commits() {
  git log --grep='RALPH:' --oneline -10 --format='%h %ad %s' --date=short 2>/dev/null || echo "No RALPH commits yet"
}

# --- Iteration Loop ---

run_loop() {
  local prompt_content
  prompt_content=$(cat "$SANDCASTLE_DIR/prompt.md")
  local loop_start_time=$SECONDS

  for i in $(seq 1 "$ITERATIONS"); do
    echo ""
    echo "=== Iteration ${i}/${ITERATIONS} === $(date '+%H:%M:%S') ==="
    echo ""

    local issues commits full_prompt

    issues=$(fetch_issues)
    commits=$(fetch_ralph_commits)

    local issue_count
    issue_count=$(echo "$issues" | jq 'if type == "array" then length else 1 end' 2>/dev/null || echo "0")

    if [[ "$issue_count" -eq 0 ]]; then
      success "No open issues remaining. Done."
      break
    fi

    # Show issue titles for visibility
    info "Issues available: ${issue_count}"
    echo "$issues" | jq -r 'if type == "array" then .[:5][] | "  #\(.number) \(.title)"  else "#\(.number) \(.title)" end' 2>/dev/null || true
    if [[ "$issue_count" -gt 5 ]]; then
      echo "  ... and $((issue_count - 5)) more"
    fi
    echo ""

    # Construct prompt
    full_prompt="# ISSUES JSON
${issues}

# RECENT RALPH COMMITS
${commits}

${prompt_content}"

    if [[ "$DRY_RUN" == true ]]; then
      info "[DRY RUN] Would invoke claude -p with ${#full_prompt} char prompt (${issue_count} issues)"
      continue
    fi

    # Write prompt to temp file (avoids bash escaping issues with large JSON)
    local prompt_file
    prompt_file=$(mktemp /tmp/sandcastle-prompt-XXXXXX.md)
    echo "$full_prompt" > "$prompt_file"

    local iter_start=$SECONDS

    # Start heartbeat in background — fallback if stream-json is quiet
    (
      while true; do
        sleep 120
        local elapsed=$(( SECONDS - iter_start ))
        local mins=$(( elapsed / 60 ))
        echo -e "\033[0;34m  [heartbeat] ${mins}m elapsed\033[0m"
      done
    ) &
    local heartbeat_pid=$!

    info "Running agent..."

    # Run Claude in Docker Sandbox with stream-json for live activity feed
    local output_file="/tmp/sandcastle-output-${i}.txt"
    local result_file="/tmp/sandcastle-result-${i}.txt"
    > "$output_file"
    > "$result_file"

    docker sandbox run claude -- \
      --permission-mode acceptEdits \
      -p "$(cat "$prompt_file")" \
      --model sonnet \
      --output-format stream-json \
      2>&1 | while IFS= read -r line; do
        # Save raw output
        echo "$line" >> "$output_file"

        # Try to parse as JSON
        if ! echo "$line" | jq -e '.' &>/dev/null; then
          # Not JSON — show as plain text (docker messages, errors, etc.)
          [[ -n "$line" ]] && echo "  $line"
          continue
        fi

        # Parse JSON events into live status
        local msg_type tool_name file_path cmd_text result_text

        msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)

        case "$msg_type" in
          tool_use)
            tool_name=$(echo "$line" | jq -r '.name // .tool // empty' 2>/dev/null)
            case "$tool_name" in
              Read|NotebookRead)
                file_path=$(echo "$line" | jq -r '.input.file_path // empty' 2>/dev/null)
                [[ -n "$file_path" ]] && echo -e "  \033[0;34m[reading]\033[0m  ${file_path##*/}"
                ;;
              Write)
                file_path=$(echo "$line" | jq -r '.input.file_path // empty' 2>/dev/null)
                [[ -n "$file_path" ]] && echo -e "  \033[0;32m[writing]\033[0m  ${file_path##*/}"
                ;;
              Edit)
                file_path=$(echo "$line" | jq -r '.input.file_path // empty' 2>/dev/null)
                [[ -n "$file_path" ]] && echo -e "  \033[0;33m[editing]\033[0m  ${file_path##*/}"
                ;;
              Bash)
                cmd_text=$(echo "$line" | jq -r '.input.command // empty' 2>/dev/null | head -c 80)
                [[ -n "$cmd_text" ]] && echo -e "  \033[0;35m[running]\033[0m  ${cmd_text}"
                ;;
              Glob|Grep)
                local pattern
                pattern=$(echo "$line" | jq -r '.input.pattern // empty' 2>/dev/null)
                [[ -n "$pattern" ]] && echo -e "  \033[0;34m[search]\033[0m   ${pattern}" || echo -e "  \033[0;34m[search]\033[0m"
                ;;
              *)
                [[ -n "$tool_name" ]] && echo -e "  \033[0;36m[${tool_name}]\033[0m"
                ;;
            esac
            ;;
          result)
            result_text=$(echo "$line" | jq -r '.result // empty' 2>/dev/null)
            [[ -n "$result_text" ]] && echo "$result_text" > "$result_file"
            ;;
          system)
            local subtype
            subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null)
            [[ -n "$subtype" ]] && echo -e "  \033[0;34m[system]\033[0m  ${subtype}"
            ;;
          error)
            local error_msg
            error_msg=$(echo "$line" | jq -r '.error // .message // empty' 2>/dev/null)
            [[ -n "$error_msg" ]] && echo -e "  \033[0;31m[error]\033[0m   ${error_msg}"
            ;;
          *)
            # Show unknown types so nothing is silently swallowed
            [[ -n "$msg_type" ]] && echo -e "  \033[0;90m[${msg_type}]\033[0m"
            ;;
        esac
      done || true

    # Stop heartbeat
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true

    rm -f "$prompt_file"

    # Show iteration summary
    local iter_elapsed=$(( SECONDS - iter_start ))
    local iter_mins=$(( iter_elapsed / 60 ))
    local iter_secs=$(( iter_elapsed % 60 ))
    echo ""
    info "Iteration ${i} completed in ${iter_mins}m ${iter_secs}s"

    # Show what changed
    local changed_files
    changed_files=$(git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
    local new_commits
    new_commits=$(git log --oneline -3 --since="$(( iter_elapsed + 10 )) seconds ago" 2>/dev/null || true)

    if [[ -n "$changed_files" ]]; then
      local file_count
      file_count=$(echo "$changed_files" | wc -l | tr -d '[:space:]')
      info "Files changed: ${file_count}"
      echo "$changed_files" | head -5 | sed 's/^/  /'
      if [[ "$file_count" -gt 5 ]]; then
        echo "  ... and $((file_count - 5)) more"
      fi
    fi

    if [[ -n "$new_commits" ]]; then
      info "Recent commits:"
      echo "$new_commits" | sed 's/^/  /'
    fi

    # Check for COMPLETE signal in result or raw output
    if grep -q '<promise>COMPLETE</promise>' "$result_file" 2>/dev/null || \
       grep -q '<promise>COMPLETE</promise>' "$output_file" 2>/dev/null; then
      rm -f "$output_file" "$result_file"
      success "All tasks complete!"
      break
    fi
    rm -f "$output_file" "$result_file"

    # Safety net: auto-commit any uncommitted work
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      warn "Auto-committing uncommitted changes..."
      git add -A
      git commit -m "RALPH: auto-commit uncommitted work from iteration ${i}"
    fi

    # Push after each iteration
    git push origin "${BRANCH}" 2>&1 || true

    # Show total elapsed
    local total_elapsed=$(( SECONDS - loop_start_time ))
    local total_mins=$(( total_elapsed / 60 ))
    echo ""
    info "Total elapsed: ${total_mins}m | Next: iteration $((i + 1))/${ITERATIONS}"

  done
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

  # Push final state
  git push origin "${BRANCH}" 2>&1 || die "Failed to push branch"

  # Check for existing PR
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
    create_pr

    local milestone_label="${MILESTONE_FILTER:-all issues}"
    notify "$milestone_label" "Ralph finished processing ${milestone_label}"
    echo ""
    success "=== SANDCASTLE COMPLETE ==="
  else
    echo ""
    info "=== DRY RUN COMPLETE ==="
  fi
}

main "$@"
