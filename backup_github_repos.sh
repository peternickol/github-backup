#!/usr/bin/env bash
#
# backup_github_repos.sh
#
# Crawls a directory tree looking for GitHub repositories and then git pulls them
# periodically every night. Designed to be run as a periodic cron job or systemd
# scheduled task to keep local mirrors of GitHub repositories in sync.
#
# License: MIT (see LICENSE file)
#
# Usage:
#   backup_github_repos.sh [--base-dir DIR] [--dry-run] [--verbose] [--debug]
#   backup_github_repos.sh --install              # Install to /usr/local/bin
#   backup_github_repos.sh --update              # Download latest and reinstall
#   backup_github_repos.sh --uninstall           # Remove installed script
#
# Environment variables:
#   GITHUB_BACKUP_BASE_DIR  Base directory to search for git repos (default: /root)
#   GITHUB_BACKUP_DRY_RUN   If set to "1", only report repos that would be pulled
#   GITHUB_BACKUP_VERBOSE   If set, print each repo as it's processed
#   GITHUB_BACKUP_LOG_FILE  Path to log file (default: /var/log/github-backup.log)
#   GITHUB_BACKUP_EMAIL     Email address for completion notification
#   GITHUB_BACKUP_SKIP_LIST Comma-separated list of repo names/dirs to skip
#

set -u  # abort on unset variable

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

ok() {
  printf '%sOK\n' "$C_OK"
}

die() {
  printf '%sError: %s\n' "$C_ERR" "$*" >&2
  exit 1
}

warn() {
  printf '%sWarning: %s\n' "$C_WARN" "$*" >&2
}

self_path() {
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$0" 2>/dev/null || echo "$0"
  else
    echo "$0"
  fi
}

# ── Install configuration ──────────────────────────────────────────────────────
INSTALL_PATH="/usr/local/bin/backup_github_repos"

# ── Management commands ───────────────────────────────────────────────────────

cmd_install() {
  local src dest
  src="$(self_path)"
  dest="$INSTALL_PATH"

  if [[ -e "$dest" && "$FORCE" -ne 1 ]]; then
    die "$dest already exists. Re-run with --force to overwrite."
  fi

  log "Installing $src → $dest"
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
      comp_file="$comp_dir/backup_github_repos"
      if [[ -e "$comp_file" && "$FORCE" -ne 1 ]]; then
        die "Completion already exists at $comp_file (use --force to overwrite)."
      fi
      log "Installing bash completion → $comp_file"
      # Simple completion: just list the main options
      echo "# backup_github_repos.sh bash completion" > "$comp_file"
      echo "_complete_backup_github_repos() {" >> "$comp_file"
      echo "    local cur prev opts" >> "$comp_file"
      echo "    COMPREPLY=()" >> "$comp_file"
      echo "    cur=\"${COMP_WORDS[COMP_CWORD]}\"" >> "$comp_file"
      echo "    prev=\"${COMP_WORDS[COMP_CWORD-1]}\"" >> "$comp_file"
      echo "    opts=\"--base-dir --dry-run --verbose --debug --skip --skip-list --help\"" >> "$comp_file"
      echo "    COMPREPLY=( \$(compgen -W \"\$opts\" -- \"\$cur\") )" >> "$comp_file"
      echo "}" >> "$comp_file"
      echo "complete -F _complete_backup_github_repos backup_github_repos" >> "$comp_file"
      ok "Bash completion installed → $comp_file"
    fi
  fi

  log "Installation complete. Try: backup_github_repos.sh --help"
}

cmd_update() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/backup-github-update.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN

  log "Downloading latest backup_github_repos from GitHub"
  # Download using curl or wget
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "https://raw.githubusercontent.com/peternickol/github-backup/main/backup_github_repos.sh" -o "$tmp" || die "Failed to download update"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "https://raw.githubusercontent.com/peternickol/github-backup/main/backup_github_repos.sh" || die "Failed to download update"
  else
    die "Neither curl nor wget is installed. Install one of them to use update."
  fi

  [[ -s "$tmp" ]] || die "Downloaded update is empty."
  bash -n "$tmp" || die "Downloaded update failed syntax check."

  log "Installing update → $INSTALL_PATH"
  install -m 0755 -o root -g root "$tmp" "$INSTALL_PATH"
  ok "Updated binary: $INSTALL_PATH"

  log "Update complete. Try: backup_github_repos.sh --help"
}

cmd_uninstall() {
  local dest="$INSTALL_PATH"

  if [[ ! -e "$dest" ]]; then
    warn "Not installed: $dest does not exist."
    exit 0
  fi

  log "Removing $dest"
  rm -f "$dest"
  ok "Removed: $dest"

  # Also remove completion if it exists
  if [[ -e /usr/share/bash-completion/completions/backup_github_repos ]]; then
    rm -f /usr/share/bash-completion/completions/backup_github_repos
    ok "Removed bash completion"
  fi
  if [[ -e /etc/bash_completion.d/backup_github_repos ]]; then
    rm -f /etc/bash_completion.d/backup_github_repos
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
    --install) cmd_install; exit 0;;
    --update) cmd_update; exit 0;;
    --uninstall) cmd_uninstall; exit 0;;
    --help|-h)
      echo "Usage: $0 [--base-dir DIR] [--dry-run] [--verbose] [--debug] [--skip REPO] [--skip-list LIST] [--install] [--update] [--uninstall]"
      echo ""
      echo "Management commands:"
      echo "  --install      Install script to $INSTALL_PATH"
      echo "  --update       Download latest and reinstall"
      echo "  --uninstall    Remove installed script from $INSTALL_PATH"
      echo ""
      echo "Full options:"
      echo "  --base-dir DIR       Base directory to search (default: /root)"
      echo "  --dry-run            Report repos without pulling"
      echo "  --verbose            Print each repo as it's processed"
      echo "  --debug              Print debug information (repo paths, git urls)"
      echo "  --skip REPO          Skip a specific repo name/dir"
      echo "  --skip-list LIST     Comma-separated list of repos to skip"
      echo "  --help/-h          Show this help message"
      exit 0;;
    *)
      echo "Unknown option: $1" >&2; exit 1;;
  esac
done

# ── Parse skip-list from env var ──────────────────────────────────────────────
if [[ -n "$SKIP_LIST_STR" ]]; then
  IFS=',' read -ra SKIP_LIST <<< "$SKIP_LIST_STR"
fi

# ── Main backup flow ─────────────────────────────────────────────────────────

# Ensure log directory exists
LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p "$LOG_DIR"

# Clear/initialize log
: > "$LOG_FILE"
log_msg "=== GitHub Backup Job Started ==="
log_msg "Base directory: $BASE_DIR"
log_msg "Dry run: $DRY_RUN"
[[ $VERBOSE -eq 1 ]] && log_msg "Verbose mode enabled"

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
  send_notification "GitHub Backup Completed" \
    "Base: $BASE_DIR\nPulled: $pulled_count\nSkipped: $skipped_count\nFailed: $failed_count\nLog: $LOG_FILE"
fi

exit 0