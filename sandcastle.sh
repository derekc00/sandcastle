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
MAX_TURNS=75
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

  # Read config
  if [[ -f "$SANDCASTLE_DIR/config.json" ]]; then
    ITERATIONS=$(jq -r '.defaultIterations // 100' "$SANDCASTLE_DIR/config.json")
    MAX_TURNS=$(jq -r '.maxTurns // 75' "$SANDCASTLE_DIR/config.json")
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

fetch_issues_summary() {
  # Only fetch number + title (lightweight) for the issue list
  # Claude will use `gh issue view #N` to read the full body of whichever it picks
  local issue_args="--state open --json number,title,labels --limit 10"

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

# --- Quality Gate ---

run_quality_gate() {
  info "Running quality gate..."

  local failed=false

  # Detect and run typecheck
  if [[ -f "tsconfig.json" ]]; then
    if command -v npx &>/dev/null; then
      echo -n "  typecheck... "
      if npx tsc --noEmit 2>&1 | tail -3; then
        echo "  typecheck passed"
      else
        warn "  typecheck FAILED"
        failed=true
      fi
    fi
  fi

  # Detect and run tests (quick check, not full suite)
  if [[ -f "package.json" ]]; then
    local test_cmd
    test_cmd=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
    if [[ -n "$test_cmd" ]]; then
      echo -n "  tests... "
      if npm test --if-present 2>&1 | tail -5; then
        echo "  tests passed"
      else
        warn "  tests FAILED"
        failed=true
      fi
    fi
  fi

  if [[ "$failed" == true ]]; then
    return 1
  fi
  return 0
}

# --- Iteration Loop ---

run_loop() {
  local loop_start_time=$SECONDS

  for i in $(seq 1 "$ITERATIONS"); do
    echo ""
    echo "=== Iteration ${i}/${ITERATIONS} === $(date '+%H:%M:%S') ==="
    echo ""

    local issues commits

    issues=$(fetch_issues_summary)
    commits=$(fetch_ralph_commits)

    local issue_count
    issue_count=$(echo "$issues" | jq 'if type == "array" then length else 1 end' 2>/dev/null || echo "0")

    if [[ "$issue_count" -eq 0 ]]; then
      success "No open issues remaining. Done."
      break
    fi

    # Show issue titles
    info "Issues available: ${issue_count}"
    echo "$issues" | jq -r 'if type == "array" then .[:5][] | "  #\(.number) \(.title)" else "  #\(.number) \(.title)" end' 2>/dev/null || true
    if [[ "$issue_count" -gt 5 ]]; then
      echo "  ... and $((issue_count - 5)) more"
    fi
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
      info "[DRY RUN] ${issue_count} issues available"
      continue
    fi

    # Write lightweight issue list to working dir (Docker sandbox mounts it)
    echo "$issues" > .sandcastle/issues.json
    echo "$commits" > .sandcastle/ralph-commits.txt

    local iter_start=$SECONDS

    # Start heartbeat
    (
      while true; do
        sleep 60
        local elapsed=$(( SECONDS - iter_start ))
        local mins=$(( elapsed / 60 ))
        echo -e "\033[0;34m  [heartbeat] ${mins}m elapsed — agent still running...\033[0m"
      done
    ) &
    local heartbeat_pid=$!

    info "Running agent... (${MAX_TURNS} max turns)"

    # Run Claude in Docker Sandbox
    local result
    result=$(docker sandbox run claude \
      --dangerously-skip-permissions \
      --model sonnet \
      --max-turns "${MAX_TURNS}" \
      -p "@.sandcastle/prompt.md @.sandcastle/issues.json @.sandcastle/ralph-commits.txt \
ONLY WORK ON A SINGLE TASK. \
Use 'gh issue view #N' to read the full details of the issue you pick. \
If all tasks are complete, output <promise>COMPLETE</promise>." \
      2>&1) || true

    # Stop heartbeat
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true

    # Show Claude's output (last 50 lines to avoid flooding)
    if [[ -n "$result" ]]; then
      echo "$result" | tail -50
    fi

    # Clean up temp files
    rm -f .sandcastle/issues.json .sandcastle/ralph-commits.txt

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

    # Check for COMPLETE signal
    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
      success "All tasks complete!"
      break
    fi

    # Safety net: auto-commit any uncommitted work
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      # Run quality gate before committing
      if run_quality_gate; then
        info "Quality gate passed — committing"
        git add -A
        git commit -m "RALPH: auto-commit work from iteration ${i}"
      else
        warn "Quality gate failed — reverting uncommitted changes"
        git checkout -- . 2>/dev/null || true
        git clean -fd 2>/dev/null || true
      fi
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
  echo "Max turns:  ${MAX_TURNS} per iteration"
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
