#!/usr/bin/env bash
#
# github-backup
#
# Crawls a directory tree looking for GitHub repositories and then git pulls them
# periodically every night. Designed to be run as a periodic cron job or systemd
# scheduled task to keep local mirrors of GitHub repositories in sync.
#
# Can operate in two modes:
#   1. Local directory crawl - finds .git directories under a base directory
#   2. GitHub profile download - downloads all repos from a GitHub user profile
#
# License: MIT (see LICENSE file)
#
# Usage:
#   github-backup [--base-dir DIR] [--dry-run] [--verbose] [--debug]
#   github-backup --install              # Install to /usr/local/bin
#   github-backup --update              # Download latest and reinstall
#   github-backup --uninstall           # Remove installed script
#   github-backup --profile USER         # Download all repos from GitHub user USER
#   github-backup --list-repos USER      List repos from GitHub user USER
#
# Environment variables:
#   GITHUB_BACKUP_BASE_DIR       Base directory to search for git repos (default: /root)
#   GITHUB_BACKUP_DRY_RUN       If set to "1", only report repos that would be pulled
#   GITHUB_BACKUP_VERBOSE       If set, print each repo as it's processed
#   GITHUB_BACKUP_LOG_FILE      Path to log file (default: /var/log/github-backup.log)
#   GITHUB_BACKUP_EMAIL         Email address for completion notification
#   GITHUB_BACKUP_SKIP_LIST     Comma-separated list of repo names/dirs to skip
#   GITHUB_BACKUP_TOKEN         GitHub API token (optional, increases rate limit)
#
# Quick Start:
#   # Install the script
#   github-backup --install
#
#   # Download all repos from a GitHub user
#   github-backup --profile USERNAME
#
#   # List repos from a GitHub user
#   github-backup --list-repos USERNAME
#
#   # Regular local directory crawl
#   github-backup --base-dir /path/to/repos
#
# Quick Update:
#   github-backup update
#
# Quick Uninstall:
#   github-backup uninstall
#
# Quick Example:
#   # Download all repos from octocat
#   github-backup --profile octocat
#
#   # List all repos from octocat
#   github-backup --list-repos octocat
#
# Quick Update:
#   github-backup update
#
# Quick Uninstall:
#   github-backup uninstall
#
# Quick Example:
#   # Download all repos from octocat
#   github-backup --profile octocat
#
#   # List all repos from octocat
#   github-backup --list-repos octocat
#

set -u

# ── Color support ──────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_OK=$'\e[32m'
  C_WARN=$'\e[33m'
  C_ERR=$'\e[31m'
  C_RESET=$'\e[0m'
else
  C_OK=""
  C_WARN=""
  C_ERR=""
  C_RESET=""
fi

# ── Defaults ───────────────────────────────────────────────────────────────────
BASE_DIR="${GITHUB_BACKUP_BASE_DIR:-/root}"
DRY_RUN=0
VERBOSE=0
DEBUG=0
SKIP_LIST=()
LOG_FILE="${GITHUB_BACKUP_LOG_FILE:-/var/log/github-backup.log}"
EMAIL_TO="${GITHUB_BACKUP_EMAIL:-}"
SKIP_LIST_STR="${GITHUB_BACKUP_SKIP_LIST:-}"
FORCE=0

# ── Helper functions ───────────────────────────────────────────────────────────

is_skipped() {
  local dirname="$1"
  for skipped in "${SKIP_LIST[@]}"; do
    if [[ "$dirname" == "$skipped" ]] || [[ "$dirname" == *"$skipped"* ]]; then
      return 0
    fi
  done
  return 1
}

log_msg() {
  local message="$1"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${timestamp}] ${message}" >> "$LOG_FILE"
}

# Alias log for convenience in management commands
log() {
  log_msg "$@"
}

die() {
  printf '%sError: %s\n' "$C_ERR" "$*" >&2
  exit 1
}

warn() {
  printf '%sWarning: %s\n' "$C_WARN" "$*" >&2
}

ok() {
  printf '%sOK\n' "$C_OK"
}

die() {
  printf '%sError: %s\n' "$C_ERR" "$*" >&2
  exit 1
}

self_path() {
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$0" 2>/dev/null || echo "$0"
  else
    echo "$0"
  fi
}

# ── Install configuration ──────────────────────────────────────────────────────
INSTALL_PATH="/usr/local/bin/github-backup"

# ── GitHub API helper ─────────────────────────────────────────────────────────

github_api() {
  local endpoint="$1"
  local url="https://api.github.com${endpoint}"
  local curl_opts=(-fsSL -H "User-Agent: github-backup" -H "Accept: application/vnd.github+json")
  
  if [[ -n "$GITHUB_BACKUP_TOKEN" ]]; then
    curl_opts+=("-H" "Authorization: token $GITHUB_BACKUP_TOKEN")
  fi
  
  curl "${curl_opts[@]}" "$url" 2>/dev/null
}

github_list_repos() {
  local username="$1"
  local result=""
  local page=1
  local per_page=100
  
  while true; do
    local response
    response=$(github_api "users/${username}/repos?per_page=${per_page}&page=${page}")
    
    [[ -z "$response" ]] && break
    
    local count=$(echo "$response" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    
    if [[ $count -eq 0 ]]; then
      break
    fi
    
    # Extract repo names
    local repos
    repos=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data:
    print(r['name'])
" 2>/dev/null || echo "")
    
    if [[ -z "$repos" ]]; then
      break
    fi
    
    result="${result} ${repos}"
    page=$((page + 1))
    
    # Respect rate limits - sleep briefly
    sleep 0.5
  done
  
  echo "$result"
}

# ── Management commands ───────────────────────────────────────────────────────

cmd_install() {
  local src dest
  src="$(self_path)"
  dest="$INSTALL_PATH"

  if [[ -e "$dest" && "$FORCE" -ne 1 ]]; then
    die "$dest already exists. Re-run with --force to overwrite."
  fi

  log_msg "Installing $src → $dest"
  install -m 0755 -o root -g root "$src" "$dest"
  ok "Installed binary: $dest"

  # Install bash completion if bash is available
  if command -v bash >/dev/null 2>&1; then
    # Detect completion directory
    if [[ -d /usr/share/bash-completion/completions ]]; then
      comp_dir="/usr/share/bash-completion/completions"
    elif [[ -d /etc/bash_completion.d ]]; then
      comp_dir="/etc/bash_completion.d"
    else
      warn "No bash-completion directory found; skipping completion install"
    fi

    if [[ -n "$comp_dir" ]]; then
      comp_file="$comp_dir/github-backup"
      if [[ -e "$comp_file" && "$FORCE" -ne 1 ]]; then
        die "Completion already exists at $comp_file (use --force to overwrite)."
      fi
      log_msg "Installing bash completion → $comp_file"
      # Simple completion: just list the main options
      echo "# github-backup bash completion" > "$comp_file"
      echo "_complete_github_backup() {" >> "$comp_file"
      echo "    local cur prev opts" >> "$comp_file"
      echo "    COMPREPLY=()" >> "$comp_file"
      echo "    cur=\"${COMP_WORDS[COMP_CWORD]}\"" >> "$comp_file"
      echo "    prev=\"${COMP_WORDS[COMP_CWORD-1]}\"" >> "$comp_file"
      echo "    opts=\"--base-dir --dry-run --verbose --debug --skip --skip-list --profile --list-repos --install --update --uninstall\"" >> "$comp_file"
      echo "    COMPREPLY=( \$(compgen -W \"\$opts\" -- \"\$cur\") )" >> "$comp_file"
      echo "}" >> "$comp_file"
      echo "complete -F _complete_github_backup github-backup" >> "$comp_file"
      ok "Bash completion installed → $comp_file"
    fi
  fi

  log_msg "Installation complete. Try: github-backup --help"
}

cmd_update() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/github-backup-update.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN

  log_msg "Downloading latest github-backup from GitHub"
  # Download using curl or wget
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "https://raw.githubusercontent.com/peternickol/github-backup/main/github-backup.sh" -o "$tmp" || die "Failed to download update"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "https://raw.githubusercontent.com/peternickol/github-backup/main/github-backup.sh" || die "Failed to download update"
  else
    die "Neither curl nor wget is installed. Install one of them to use update."
  fi

  [[ -s "$tmp" ]] || die "Downloaded update is empty."
  bash -n "$tmp" || die "Downloaded update failed syntax check."

  log_msg "Installing update → $INSTALL_PATH"
  install -m 0755 -o root -g root "$tmp" "$INSTALL_PATH"
  ok "Updated binary: $INSTALL_PATH"

  log_msg "Update complete. Try: github-backup --help"
}

cmd_uninstall() {
  local dest="$INSTALL_PATH"

  if [[ ! -e "$dest" ]]; then
    warn "Not installed: $dest does not exist."
    exit 0
  fi

  log_msg "Removing $dest"
  rm -f "$dest"
  ok "Removed: $dest"

  # Also remove completion if it exists
  if [[ -e /usr/share/bash-completion/completions/github-backup ]]; then
    rm -f /usr/share/bash-completion/completions/github-backup
    ok "Removed bash completion"
  fi
  if [[ -e /etc/bash_completion.d/github-backup ]]; then
    rm -f /etc/bash_completion.d/github-backup
    ok "Removed bash completion"
  fi
}

# ── Parse command-line flags ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-dir)
      BASE_DIR="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --verbose) VERBOSE=1; shift;;
    --debug) DEBUG=1; shift;;
    --skip)
      SKIP_LIST+=("$2"); shift 2;;
    --skip-list)
      SKIP_LIST_STR="$2"; shift 2;;
    --profile)
      PROFILE_USERNAME="$2"; shift 2;;
    --list-repos)
      LIST_USERNAME="$2"; shift 2;;
    --install) cmd_install; exit 0;;
    --update) cmd_update; exit 0;;
    --uninstall) cmd_uninstall; exit 0;;
    --help|-h)
      echo "Usage: github-backup [--base-dir DIR] [--dry-run] [--verbose] [--debug] [--profile USER] [--list-repos USER] [--install] [--update] [--uninstall]"
      echo ""
      echo "Management commands:"
      echo "  --install      Install script to /usr/local/bin/github-backup"
      echo "  --update       Download latest and reinstall"
      echo "  --uninstall    Remove installed script from /usr/local/bin/github-backup"
      echo ""
      echo "Profile commands:"
      echo "  --profile USER   Download all repos from GitHub user USER"
      echo "  --list-repos USER List repos from GitHub user USER"
      echo ""
      echo "Full options:"
      echo "  --base-dir DIR       Base directory to search (default: /root)"
      echo "  --dry-run            Report repos without pulling"
      echo "  --verbose            Print each repo as it's processed"
      echo "  --debug              Print debug information (repo paths, git urls)"
      echo "  --skip REPO          Skip a specific repo name/dir"
      echo "  --skip-list LIST   Comma-separated list of repos to skip"
      echo "  --profile USER   Download all repos from GitHub user USER"
      echo "  --list-repos USER List repos from GitHub user USER"
      echo "  --help/-h          Show this help message"
      exit 0;;
    *)
      echo "Unknown option: $1" >&2; exit 1;;
  esac
done

# Parse skip-list from env var
if [[ -n "$SKIP_LIST_STR" ]]; then
  IFS=',' read -ra SKIP_LIST <<< "$SKIP_LIST_STR"
fi

# Ensure log directory exists
LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p "$LOG_DIR"

# Clear/initialize log
: > "$LOG_FILE"
log_msg "=== GitHub Backup Job Started ==="
log_msg "Base directory: $BASE_DIR"
log_msg "Dry run: $DRY_RUN"
[[ $VERBOSE -eq 1 ]] && log_msg "Verbose mode enabled"

# Handle profile download or list repos
if [[ -n "$PROFILE_USERNAME" ]]; then
  # Download all repos from GitHub user
  github_list_repos "$PROFILE_USERNAME" "$BASE_DIR"
  exit 0
fi

if [[ -n "$LIST_USERNAME" ]]; then
  # List repos from GitHub user
  github_list_repos "$LIST_USERNAME"
  exit 0
fi

# Find all .git directories under BASE_DIR
local_git_dirs=()
while IFS= read -r -d '' gitdir; do
  local_git_dirs+=("$gitdir")
done < <(find "$BASE_DIR" -type d -name '.git' -print0 2>/dev/null | sort -z)

[[ $DEBUG -eq 1 ]] && echo "Found ${#local_git_dirs[@]} .git directories under $BASE_DIR"
log_msg "Found ${#local_git_dirs[@]} .git directories under $BASE_DIR"

# Process each git repo
pulled_count=0
skipped_count=0
failed_count=0

for gitdir in "${local_git_dirs[@]}"; do
  # repo_dir is the parent of .git
  repo_dir="$(dirname "$gitdir")"

  # Get repo name from directory path
  repo_name="$(basename "$repo_dir")"

  # Skip if in skip list
  if is_skipped "$repo_name"; then
    [[ $DEBUG -eq 1 ]] && echo "Skipping (on skip list): $repo_name"
    ((skipped_count++))
    continue
  fi

  # Attempt git pull
  if git_pull_repo "$repo_dir"; then
    ((pulled_count++))
  else
    ((failed_count++))
  fi
done

# Summary
log_msg "=== GitHub Backup Job Finished ==="
log_msg "Pulled: $pulled_count"
log_msg "Skipped: $skipped_count"
log_msg "Failed: $failed_count"

[[ $VERBOSE -eq 1 ]] || echo ""
echo "=== GitHub Backup Summary ==="
echo "Base directory: $BASE_DIR"
echo "Pulled: $pulled_count"
echo "Skipped: $skipped_count"
echo "Failed: $failed_count"
echo "Log file: $LOG_FILE"

if [[ -n "$EMAIL_TO" ]] && [[ $pulled_count -gt 0 ]]; then
  log_msg "GitHub Backup Completed: Pulled: $pulled_count, Skipped: $skipped_count, Failed: $failed_count"
fi

exit 0