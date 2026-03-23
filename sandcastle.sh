#!/bin/bash
set -euo pipefail

# sandcastle — autonomous AI development loop
# Runs Claude Code inside Docker to implement GitHub issues

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SANDCASTLE_DIR=".sandcastle"
CONTAINER_NAME=""
IMAGE_NAME=""
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
  # Check we're in a git repo
  git rev-parse --is-inside-work-tree &>/dev/null \
    || die "Not in a git repo. Run this from a project directory."

  # Check .sandcastle/ exists
  [[ -d "$SANDCASTLE_DIR" ]] \
    || die "No .sandcastle/ directory found. Create one with Dockerfile, config.json, and prompt.md."

  # Check required files
  [[ -f "$SANDCASTLE_DIR/Dockerfile" ]] \
    || die "No Dockerfile in .sandcastle/."
  [[ -f "$SANDCASTLE_DIR/prompt.md" ]] \
    || die "No prompt.md in .sandcastle/."
  [[ -f "$SANDCASTLE_DIR/config.json" ]] \
    || die "No config.json in .sandcastle/."
  [[ -f "$SANDCASTLE_DIR/.env" ]] \
    || die "No .env file in .sandcastle/. Copy .env.example and fill in your tokens."

  # Check Docker is running
  docker info &>/dev/null \
    || die "Docker is not running. Start Docker Desktop and try again."

  # Check gh auth
  gh auth status &>/dev/null \
    || die "GitHub CLI not authenticated. Run 'gh auth login'."

  # Get repo info
  REPO=$(gh repo view --json name -q '.name')
  OWNER=$(gh repo view --json owner -q '.owner.login')
  IMAGE_NAME="sandcastle-${REPO}"
  CONTAINER_NAME="sandcastle-${REPO}"

  # Read iterations from config
  ITERATIONS=$(jq -r '.defaultIterations // 100' "$SANDCASTLE_DIR/config.json")
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

  # Fetch open milestones
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

  # Validate numeric input
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
  # Slugify milestone name for branch
  BRANCH="ralph/$(echo "$MILESTONE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')"

  info "Selected milestone: ${MILESTONE} (${open_count} open issues)"
}

# --- Container Management ---

build_image() {
  if docker image inspect "$IMAGE_NAME" &>/dev/null; then
    info "Image ${IMAGE_NAME} already exists, skipping build"
    return
  fi

  info "Building Docker image: ${IMAGE_NAME}..."
  docker build -t "$IMAGE_NAME" -f "$SANDCASTLE_DIR/Dockerfile" . \
    || die "Docker build failed"
  success "Image built: ${IMAGE_NAME}"
}

start_container() {
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    info "Container ${CONTAINER_NAME} already running"
    return
  fi

  # Remove stopped container if exists
  docker rm -f "$CONTAINER_NAME" &>/dev/null || true

  info "Starting container: ${CONTAINER_NAME}..."

  # Load .env and pass as env vars
  docker run -d \
    --name "$CONTAINER_NAME" \
    --env-file "$SANDCASTLE_DIR/.env" \
    "$IMAGE_NAME" \
    || die "Failed to start container"

  success "Container started: ${CONTAINER_NAME}"
}

setup_repo() {
  info "Syncing repo into sandbox..."

  # Source the .env to get GITHUB_TOKEN and GITHUB_REPO
  local github_token github_repo
  github_token=$(grep '^GITHUB_TOKEN=' "$SANDCASTLE_DIR/.env" | cut -d= -f2-)
  github_repo=$(grep '^GITHUB_REPO=' "$SANDCASTLE_DIR/.env" | cut -d= -f2-)

  [[ -n "$github_token" ]] || die "GITHUB_TOKEN not found in .env"
  [[ -n "$github_repo" ]] || die "GITHUB_REPO not found in .env"

  # Clone repo inside container
  docker exec "$CONTAINER_NAME" bash -c "
    cd /home/agent/repos
    if [ -d '${REPO}' ]; then
      cd '${REPO}'
      git fetch origin
      git checkout main 2>/dev/null || git checkout master
      git pull
    else
      git clone 'https://x-access-token:${github_token}@github.com/${github_repo}.git' '${REPO}'
      cd '${REPO}'
    fi

    # Configure git
    git config user.name 'Ralph (Sandcastle)'
    git config user.email 'ralph@sandcastle.dev'

    # Create and checkout ralph branch
    git checkout -B '${BRANCH}' 2>/dev/null

    # Install dependencies
    if [ -f pnpm-lock.yaml ]; then
      pnpm install --frozen-lockfile 2>/dev/null || pnpm install
    elif [ -f package-lock.json ]; then
      npm ci 2>/dev/null || npm install
    elif [ -f yarn.lock ]; then
      yarn install --frozen-lockfile 2>/dev/null || yarn install
    fi
  " || die "Failed to sync repo into container"

  # Configure gh auth inside container
  docker exec "$CONTAINER_NAME" bash -c "
    echo '${github_token}' | gh auth login --with-token 2>/dev/null
  " || warn "gh auth setup failed — Claude may not be able to close issues"

  success "Repo synced and branch '${BRANCH}' created"
}

# --- Issue Fetching ---

fetch_issues() {
  local issue_args="--state open --json number,title,body,labels,comments --limit 100"

  if [[ -n "$MILESTONE_FILTER" ]]; then
    issue_args="$issue_args --milestone \"${MILESTONE_FILTER}\""
  fi

  if [[ -n "$SINGLE_ISSUE" ]]; then
    # Fetch single issue
    docker exec "$CONTAINER_NAME" bash -c "
      cd /home/agent/repos/${REPO}
      gh issue view ${SINGLE_ISSUE} --json number,title,body,labels,comments
    " 2>/dev/null
    return
  fi

  docker exec "$CONTAINER_NAME" bash -c "
    cd /home/agent/repos/${REPO}
    gh issue list ${issue_args}
  " 2>/dev/null
}

fetch_ralph_commits() {
  docker exec "$CONTAINER_NAME" bash -c "
    cd /home/agent/repos/${REPO}
    git log --grep='RALPH:' --oneline -10 --format='%h %ad %s' --date=short 2>/dev/null || echo '[]'
  " 2>/dev/null
}

# --- Iteration Loop ---

run_loop() {
  local prompt_content
  prompt_content=$(cat "$SANDCASTLE_DIR/prompt.md")

  for i in $(seq 1 "$ITERATIONS"); do
    echo ""
    echo "=== Iteration ${i}/${ITERATIONS} ==="
    echo ""

    # Fetch fresh issues and commits
    info "Running agent..."
    local issues commits full_prompt output

    issues=$(fetch_issues)
    commits=$(fetch_ralph_commits)

    # Check if any issues remain
    local issue_count
    issue_count=$(echo "$issues" | jq 'if type == "array" then length else 1 end' 2>/dev/null || echo "0")

    if [[ "$issue_count" -eq 0 ]]; then
      success "No open issues remaining. Done."
      break
    fi

    # Construct prompt
    full_prompt="# ISSUES JSON
${issues}

# RECENT RALPH COMMITS
${commits}

${prompt_content}"

    if [[ "$DRY_RUN" == true ]]; then
      info "[DRY RUN] Would invoke claude -p with ${#full_prompt} char prompt"
      info "[DRY RUN] Issues: ${issue_count}"
      continue
    fi

    # Run Claude inside container
    output=$(docker exec "$CONTAINER_NAME" bash -c "
      cd /home/agent/repos/${REPO}
      claude -p '$(echo "$full_prompt" | sed "s/'/'\\\\''/g")' \
        --dangerously-skip-permissions \
        --output-format text \
        2>/dev/null || true
    " 2>/dev/null) || true

    # Display Claude's output
    if [[ -n "$output" ]]; then
      echo "$output"
    fi

    # Check for COMPLETE signal
    if echo "$output" | grep -q '<promise>COMPLETE</promise>'; then
      success "All tasks complete!"
      break
    fi

    # Push commits
    docker exec "$CONTAINER_NAME" bash -c "
      cd /home/agent/repos/${REPO}
      git push origin '${BRANCH}' 2>/dev/null || true
    " || true

  done
}

# --- PR Creation ---

create_pr() {
  # Check if there are commits on the branch
  local commit_count
  commit_count=$(docker exec "$CONTAINER_NAME" bash -c "
    cd /home/agent/repos/${REPO}
    git log origin/main..HEAD --oneline 2>/dev/null | wc -l || \
    git log origin/develop..HEAD --oneline 2>/dev/null | wc -l || \
    echo 0
  " 2>/dev/null | tr -d '[:space:]')

  if [[ "$commit_count" -eq 0 ]]; then
    warn "No changes made. Skipping PR creation."
    return
  fi

  # Determine target branch
  local target_branch="develop"
  docker exec "$CONTAINER_NAME" bash -c "
    cd /home/agent/repos/${REPO}
    git ls-remote --heads origin develop | grep -q develop
  " 2>/dev/null || target_branch="main"

  # Collect PR body data
  local pr_title closed_issues commit_log
  if [[ -n "$MILESTONE_FILTER" ]]; then
    pr_title="[Ralph] ${MILESTONE_FILTER}"
  else
    pr_title="[Ralph] All issues — $(date +%Y-%m-%d)"
  fi

  closed_issues=$(docker exec "$CONTAINER_NAME" bash -c "
    cd /home/agent/repos/${REPO}
    git log --grep='RALPH:' --oneline --format='%s' | grep -oP '#\d+' | sort -u | while read issue; do
      echo \"- \${issue}\"
    done
  " 2>/dev/null || echo "- No issues referenced")

  commit_log=$(docker exec "$CONTAINER_NAME" bash -c "
    cd /home/agent/repos/${REPO}
    git log --grep='RALPH:' --oneline --format='- %h %s' -20
  " 2>/dev/null || echo "- No commits")

  # Push final state
  docker exec "$CONTAINER_NAME" bash -c "
    cd /home/agent/repos/${REPO}
    git push origin '${BRANCH}' 2>/dev/null
  " || die "Failed to push branch"

  # Check for existing PR
  local existing_pr
  existing_pr=$(docker exec "$CONTAINER_NAME" bash -c "
    cd /home/agent/repos/${REPO}
    gh pr list --head '${BRANCH}' --json url -q '.[0].url' 2>/dev/null
  " 2>/dev/null)

  if [[ -n "$existing_pr" ]]; then
    info "PR already exists: ${existing_pr}"
    return
  fi

  # Create PR
  local pr_url
  pr_url=$(docker exec "$CONTAINER_NAME" bash -c "
    cd /home/agent/repos/${REPO}
    gh pr create \
      --title '${pr_title}' \
      --base '${target_branch}' \
      --head '${BRANCH}' \
      --body '## Ralph Autonomous Run

### Issues Referenced
${closed_issues}

### Commits
${commit_log}

### Stats
- Iterations: up to ${ITERATIONS}
- Milestone: ${MILESTONE_FILTER:-all issues}

---
_Generated by [sandcastle](https://github.com/derekc00/sandcastle)_'
  " 2>/dev/null) || warn "PR creation failed"

  if [[ -n "$pr_url" ]]; then
    success "PR created: ${pr_url}"
    echo "$pr_url"
  fi
}

# --- Notification ---

notify() {
  local title="$1"
  local message="$2"

  # macOS notification
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"${message}\" with title \"Sandcastle\" subtitle \"${title}\"" 2>/dev/null || true
  fi
}

# --- CLI Parsing ---

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
  echo "Container:  ${CONTAINER_NAME}"
  echo "Iterations: ${ITERATIONS}"
  echo ""

  pick_milestone

  build_image
  start_container
  setup_repo

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
