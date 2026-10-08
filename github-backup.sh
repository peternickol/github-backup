#!/usr/bin/env bash
# github-backup: safely keep local GitHub working trees current.
# Install, setup, and systemd control follow the same shape as wg-manager:
#   install   copies this script and Bash completion
#   setup     writes configuration, the base directory, and systemd units
#   enable    arms the timer; start runs a backup now
# SPDX-License-Identifier: MIT

set -euo pipefail

VERSION="1.4.7"
PROGRAM="github-backup"
INSTALL_PATH="${GITHUB_BACKUP_INSTALL_PATH:-/usr/local/bin/github-backup}"
UPDATE_URL="${GITHUB_BACKUP_UPDATE_URL:-https://raw.githubusercontent.com/peternickol/github-backup/master/github-backup.sh}"
SYSTEMD_DIR="${GITHUB_BACKUP_SYSTEMD_DIR:-/etc/systemd/system}"
DEFAULTS_FILE="${GITHUB_BACKUP_DEFAULTS_FILE:-/etc/default/github-backup}"
CONFIG_PATH="${GITHUB_BACKUP_CONFIG:-/etc/github-backup/github-backup.conf}"
API_URL="${GITHUB_BACKUP_API_URL:-https://api.github.com}"
SYSTEMCTL_BIN="${GITHUB_BACKUP_SYSTEMCTL:-systemctl}"
SERVICE_NAME="github-backup.service"
TIMER_NAME="github-backup.timer"

COMMAND="sync"
DRY_RUN=0
VERBOSE=0
DEBUG=0
QUIET=0
FORCE=0
FORCE_FAST_FORWARD=0
NO_COMPLETION=0
COMPLETION_ONLY=0
UNINSTALL_COMPLETION=0
INSTALL_SYSTEMD=1
PURGE_CONFIG=0

BASE_DIR=""
PROFILE=""
LOG_FILE=""
NOTIFY_URL=""
NOTIFY_ON_ERROR=0
TOKEN=""
SKIP_LIST_RAW=""
CONFIG_FILE=""
CONFIG_FROM_CLI=0
OPTION_ORIGIN=""
APPLYING_CLI=0
CLI_SKIP_RESET=0
SAVED_SKIP_RAW=""
SCHEDULE="*-*-* 02:00:00"
PROFILE_USERNAME=""
LIST_USERNAME=""
SKIP_LIST=()
declare -A FILE_CFG=()

updated_count=0
unchanged_count=0
cloned_count=0
skipped_count=0
failed_count=0
LOG_WARNED=0
LOCK_ACQUIRED=0
REPORT_RUN=0
REPORT_FINISHED=0
REPORT_SUBMITTED=0
REPORT_ABORTED=0
REPORT_NOTES=""
REPORT_NOTE_COUNT=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_INFO=$'\e[36m'
    C_OK=$'\e[32m'
    C_WARN=$'\e[33m'
    C_ERR=$'\e[31m'
    C_RESET=$'\e[0m'
else
    C_INFO="" C_OK="" C_WARN="" C_ERR="" C_RESET=""
fi

info() {
    [[ "$QUIET" -eq 0 ]] || return 0
    printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RESET" "$*"
}
ok() {
    [[ "$QUIET" -eq 0 ]] || return 0
    printf '%s[OK]%s %s\n' "$C_OK" "$C_RESET" "$*"
}
warn() {
    [[ "$QUIET" -eq 0 ]] || return 0
    printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2
}
error() { printf '%s[ERROR]%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }
die() {
    error "$*"
    if [[ "$REPORT_RUN" -eq 1 ]]; then
        REPORT_ABORTED=1
        append_report_note "$*"
    fi
    exit 1
}
die_code() {
    local code="$1"
    shift
    error "$*"
    exit "$code"
}
debug() {
    if [[ "$DEBUG" -eq 1 ]]; then
        printf '[DEBUG] %s\n' "$*" >&2
    fi
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }

log_message() {
    local level="$1"
    shift
    local message="$*"
    local directory
    directory="$(dirname "$LOG_FILE")"
    if [[ -n "$LOG_FILE" ]] && mkdir -p "$directory" 2>/dev/null && touch "$LOG_FILE" 2>/dev/null; then
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$LOG_FILE"
        return 0
    fi
    if [[ "$LOG_WARNED" -eq 0 ]]; then
        LOG_WARNED=1
        printf '%s[WARN]%s Could not write log file: %s\n' "$C_WARN" "$C_RESET" "$LOG_FILE" >&2
    fi
}

need_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == -* ]]; then
        error_option "$option requires a value."
        usage 1
    fi
}

error_option() {
    if [[ -n "$OPTION_ORIGIN" ]]; then
        error "$OPTION_ORIGIN: $*"
    else
        error "$*"
    fi
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local path
    for path in "$@"; do
        case "$path" in
            /etc|/etc/*|/usr/local|/usr/local/*|/usr/share|/usr/share/*|/var/log|/var/log/*|/run|/run/*)
                die_code 2 "must be run as root. Try: sudo $PROGRAM ${COMMAND:-}"
                ;;
        esac
    done
}

self_path() {
    if have_cmd readlink; then
        readlink -f "$0" 2>/dev/null || printf '%s\n' "$0"
    else
        printf '%s\n' "$0"
    fi
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

usage() {
    local code="${1:-0}"
    cat <<EOF
Usage:
  $PROGRAM
  $PROGRAM sync [options]
  $PROGRAM profile USER [options]
  $PROGRAM list-repos USER [options]
  $PROGRAM setup [options]
  $PROGRAM install [options]
  $PROGRAM update [--no-completion]
  $PROGRAM uninstall [--purge-config]
  $PROGRAM enable|disable|start|stop|restart|status|journal
  $PROGRAM is-enabled|is-active

Commands:
  sync                 Update GitHub working trees under the base directory.
                       A token downloads every repository that account owns.
                       --profile selects a different user or organization.
  profile USER         Clone missing owned repositories and update the rest.
  list-repos USER      Print repository names. Nothing is cloned or locked.
  setup                Write configuration, the base directory, and systemd units.
                       Does not arm the timer. Run enable after setup.
  install              Copy this script to $INSTALL_PATH and install completion.
  update               Download the published script and install it.
  uninstall            Remove the command, units, and completion. Data stays.
  enable               systemctl enable --now $TIMER_NAME
  disable              systemctl disable --now $TIMER_NAME
  start                systemctl start $SERVICE_NAME (run one backup now)
  stop                 systemctl stop $SERVICE_NAME
  restart              systemctl restart $SERVICE_NAME (run one backup now)
  is-enabled           Print enabled or disabled for the timer. Exit 0 or 1.
  is-active            Print active or inactive for the timer. Exit 0 or 1.
  status               Show the timer, then the service. The exit status is the timer.
  journal              Follow the service journal.

Repository options:
  --base-dir DIR           Repository root or profile clone destination
                           (default: \$HOME/github-backup)
  --profile USER           On sync, clone and update USER instead of the account
                           that owns the token. On setup, save USER.
  --list-repos USER        Run list-repos for USER
  --skip REPO              Skip one repository name (repeatable, exact match)
  --skip-list A,B,C        Skip comma-separated names. Replaces the saved list.
  --dry-run                Show what the recorded upstream would do. Does not fetch or merge
  --verbose                Also print repositories that are already current.
                           For list-repos, add a public or private column.
  --debug                  Print each fetch target on stderr, even with --quiet
  --quiet, -q              Hide [INFO], [OK], [WARN], skip lines, and the summary.
                           Errors still print. The log file is still written.
  --notify-on-error        Submit the form report only when the run fails.
                           The default submits after every real sync or profile.
  --force-fast-forward     Reset a branch that has a GitHub upstream, then
                           git clean -fd. Refuses detached HEAD, a missing
                           upstream, a non-GitHub remote, and a Git operation
                           already in progress.
  --log-file FILE          Log path for this run (default: /var/log/github-backup.log)
  --token TOKEN            GitHub token. Save it in the conf file so a later
                           run does not need it again. setup does not copy it
                           into the defaults file.

Setup options:
  --schedule CALENDAR      systemd OnCalendar value (default: *-*-* 02:00:00).
                           setup --force without this resets the timer to 02:00.
  --no-systemd             Write configuration and skip the service and timer
  --force, -f              Replace existing units and rewrite the configuration.
                           An uncommented GITHUB_BACKUP_TOKEN= line is kept.
                           A token from --token or the environment is never written.

Install options:
  --force, -f              Overwrite an existing binary or completion file
  --no-completion          Install or update the binary only
  --completion-only        Install Bash completion and exit
  --uninstall-completion   Remove Bash completion and exit

Uninstall options:
  --purge-config           Also remove $DEFAULTS_FILE and $CONFIG_PATH.
                           Repositories, the base directory, and the log stay.

Other:
  --config FILE            Use FILE instead of $CONFIG_PATH. The file is
                           read first. A flag on the command line replaces
                           the same option from the file.
  -V, --version            Show version
  -h, --help               Show this help

Flags may appear before or after the command. These older forms still work:
--profile USER, --list-repos USER, --install, --update, and --uninstall.
An option value cannot be empty or start with "-". --skip adds names to the
skip list from the environment or the defaults file. --skip-list replaces
that list for this run. On the command line, either one replaces skip names
from the conf file.
setup installs $CONFIG_PATH. The command reads that file first. Remove the
leading "# " from a line to set it. A command-line flag replaces the same
option. Pass --config FILE to use a different file. Put --token in the
option file so the GitHub token does not have to be supplied again. The
command itself stays on the command line.

--quiet also hides the enabled/active word from is-enabled and is-active, and
hides systemctl output from enable, disable, start, stop, restart, and status.
The exit status stays. journal still follows the log.

Nested checkouts and submodules are left alone. Clean branches behind GitHub
are fast-forwarded. Dirty, ahead, and diverged branches are skipped.

Run report:
  When GITHUB_BACKUP_NOTIFY_URL is an http or https form endpoint, sync and
  profile POST one report after every real run. --notify-on-error submits
  only when a repository fails or the run stops early. A dry run does not
  submit. The log names every repository and what happened to it. A
  fast-forward also shows git's diffstat: the files and how many lines
  changed. The form is the only notification. The fields are _subject, host,
  program, status, summary, and log. A failed POST is a warning and does not
  change the exit status. The GitHub token is not included.

With no arguments, this help is printed and nothing is backed up.
The backup command is: $PROGRAM sync

Examples:
  github-backup
  github-backup sync --base-dir ~/src --dry-run --verbose
  github-backup sync --config /etc/github-backup/github-backup.conf --dry-run
  github-backup sync --base-dir ~/src --skip repo-one --skip-list repo-two,repo-three
  github-backup sync --base-dir ~/src --force-fast-forward --dry-run
  github-backup profile octocat --base-dir /mnt/nas/github/octocat --dry-run
  github-backup list-repos octocat --verbose
  sudo github-backup install
  sudo github-backup install --no-completion
  sudo github-backup install --completion-only
  sudo github-backup setup --base-dir /mnt/nas/github --profile USER --schedule '*-*-* 02:00:00'
  sudo github-backup setup --no-systemd --base-dir /mnt/nas/github --profile USER
  sudo github-backup setup --force --schedule 'Mon *-*-* 03:00:00'
  sudo github-backup enable
  sudo github-backup disable
  sudo github-backup start
  sudo github-backup stop
  sudo github-backup restart
  sudo github-backup is-enabled
  sudo github-backup is-enabled --quiet
  sudo github-backup is-active
  sudo github-backup status
  sudo github-backup journal
  sudo github-backup update
  sudo github-backup update --no-completion
  sudo github-backup uninstall
  sudo github-backup uninstall --purge-config
  github-backup --version
EOF
    exit "$code"
}

unquote_value() {
    local value="$1"
    if [[ ${#value} -ge 2 && "$value" == \"*\" ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\\n/$'\n'}"
        value="${value//\\\"/\"}"
        value="${value//\\\\/\\}"
    elif [[ ${#value} -ge 2 && "$value" == \'*\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

load_file_cfg() {
    FILE_CFG=()
    [[ -f "$DEFAULTS_FILE" && -r "$DEFAULTS_FILE" ]] || return 0
    local line="" key="" value=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *=* ]] || continue
        key="$(trim "${line%%=*}")"
        value="$(unquote_value "${line#*=}")"
        case "$key" in
            GITHUB_BACKUP_BASE_DIR|GITHUB_BACKUP_PROFILE|GITHUB_BACKUP_LOG_FILE|GITHUB_BACKUP_NOTIFY_URL|GITHUB_BACKUP_TOKEN|GITHUB_BACKUP_SKIP_LIST)
                FILE_CFG["$key"]="$value"
                ;;
        esac
    done < "$DEFAULTS_FILE"
}

config_value() {
    local name="$1"
    local fallback="$2"
    if [[ -n "${!name+x}" ]]; then
        printf '%s' "${!name}"
    elif [[ -n "${FILE_CFG[$name]+x}" ]]; then
        printf '%s' "${FILE_CFG[$name]}"
    else
        printf '%s' "$fallback"
    fi
}

apply_config() {
    load_file_cfg
    BASE_DIR="$(config_value GITHUB_BACKUP_BASE_DIR "$HOME/github-backup")"
    PROFILE="$(config_value GITHUB_BACKUP_PROFILE "")"
    LOG_FILE="$(config_value GITHUB_BACKUP_LOG_FILE "/var/log/github-backup.log")"
    NOTIFY_URL="$(config_value GITHUB_BACKUP_NOTIFY_URL "")"
    if [[ -n "${GITHUB_BACKUP_TOKEN+x}" ]]; then
        TOKEN="$GITHUB_BACKUP_TOKEN"
    elif [[ -n "${GH_TOKEN+x}" ]]; then
        TOKEN="$GH_TOKEN"
    else
        TOKEN="$(config_value GITHUB_BACKUP_TOKEN "")"
    fi
    SKIP_LIST_RAW="$(config_value GITHUB_BACKUP_SKIP_LIST "")"
    if [[ -n "${GITHUB_BACKUP_SCHEDULE+x}" ]]; then
        SCHEDULE="$GITHUB_BACKUP_SCHEDULE"
    fi
}

append_skip_name() {
    local name
    name="$(trim "$1")"
    [[ -n "$name" ]] || return 0
    SKIP_LIST+=("$name")
}

append_csv_skip() {
    local raw="$1"
    local item
    local -a parts=()
    IFS=',' read -r -a parts <<< "$raw" || true
    [[ "${#parts[@]}" -gt 0 ]] || return 0
    for item in "${parts[@]}"; do
        append_skip_name "$item"
    done
}

option_takes_value() {
    case "$1" in
        --base-dir|--profile|--list-repos|--skip|--skip-list|--log-file|--schedule|--config|--token)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

strip_wrapping_quotes() {
    local value="$1"
    if [[ ${#value} -ge 2 && "$value" == \"*\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 && "$value" == \'*\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

apply_saved_option() {
    local option="$1"
    local has_value="$2"
    local value="${3-}"
    case "$option" in
        --profile)
            need_value "$option" "$value"
            PROFILE="$value"
            PROFILE_USERNAME="$value"
            if [[ "$COMMAND" == "sync" ]]; then
                COMMAND="profile"
            fi
            ;;
        --list-repos)
            need_value "$option" "$value"
            COMMAND="list-repos"
            LIST_USERNAME="$value"
            ;;
        --base-dir)
            need_value "$option" "$value"
            BASE_DIR="$value"
            ;;
        --skip)
            need_value "$option" "$value"
            if [[ "$APPLYING_CLI" -eq 1 ]]; then
                reset_skips_for_command_line
            fi
            append_skip_name "$value"
            ;;
        --skip-list)
            need_value "$option" "$value"
            if [[ "$APPLYING_CLI" -eq 1 ]]; then
                reset_skips_for_command_line
            fi
            SKIP_LIST_RAW="$value"
            ;;
        --log-file)
            need_value "$option" "$value"
            LOG_FILE="$value"
            ;;
        --schedule)
            need_value "$option" "$value"
            SCHEDULE="$value"
            ;;
        --token)
            need_value "$option" "$value"
            TOKEN="$value"
            ;;
        --dry-run|--verbose|--debug|-q|--quiet|--notify-on-error|--force-fast-forward|--force|-f|--no-completion|--completion-only|--uninstall-completion|--no-systemd|--purge-config|--install|--update|--uninstall|-V|--version|-h|--help)
            if [[ "$has_value" -eq 1 ]]; then
                error_option "$option does not take a value."
                usage 1
            fi
            case "$option" in
                --dry-run) DRY_RUN=1 ;;
                --verbose) VERBOSE=1 ;;
                --debug) DEBUG=1 ;;
                -q|--quiet) QUIET=1 ;;
                --notify-on-error) NOTIFY_ON_ERROR=1 ;;
                --force-fast-forward) FORCE_FAST_FORWARD=1 ;;
                --force|-f) FORCE=1 ;;
                --no-completion) NO_COMPLETION=1 ;;
                --completion-only) COMPLETION_ONLY=1 ;;
                --uninstall-completion) UNINSTALL_COMPLETION=1 ;;
                --no-systemd) INSTALL_SYSTEMD=0 ;;
                --purge-config) PURGE_CONFIG=1 ;;
                --install) COMMAND="install" ;;
                --update) COMMAND="update" ;;
                --uninstall) COMMAND="uninstall" ;;
                -V|--version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
                -h|--help) usage ;;
            esac
            ;;
        *)
            error_option "Unknown argument: $option"
            usage 1
            ;;
    esac
}

find_config_file() {
    local -a args=("$@")
    local index=0 token="" option="" value=""
    CONFIG_FILE=""
    while [[ "$index" -lt "${#args[@]}" ]]; do
        token="${args[$index]}"
        if [[ "$token" == "--config" ]]; then
            value="${args[$((index + 1))]:-}"
            need_value "--config" "$value"
            if [[ -n "$CONFIG_FILE" ]]; then
                error "--config was given more than once."
                usage 1
            fi
            CONFIG_FILE="$value"
            index=$((index + 2))
            continue
        fi
        if [[ "$token" == --config=* ]]; then
            value="${token#--config=}"
            need_value "--config" "$value"
            if [[ -n "$CONFIG_FILE" ]]; then
                error "--config was given more than once."
                usage 1
            fi
            CONFIG_FILE="$value"
            index=$((index + 1))
            continue
        fi
        if [[ "$token" == --*=* ]]; then
            option="${token%%=*}"
            if option_takes_value "$option"; then
                index=$((index + 1))
                continue
            fi
        fi
        if option_takes_value "$token"; then
            index=$((index + 2))
            continue
        fi
        index=$((index + 1))
    done
}

load_option_file() {
    local file="$1"
    local line="" trimmed="" option="" value="" number=0
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        die "Configuration file is not a readable file: $file"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        number=$((number + 1))
        line="${line%$'\r'}"
        trimmed="$(trim "$line")"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        OPTION_ORIGIN="$file:$number"
        if [[ "$trimmed" != -* ]]; then
            error_option "expected an option, found: $trimmed"
            usage 1
        fi
        if [[ "$trimmed" == "--config" || "$trimmed" == --config=* || "$trimmed" == "--config "* ]]; then
            error_option "--config cannot be nested."
            usage 1
        fi
        option="${trimmed%%[[:space:]]*}"
        if [[ "$option" == --*=* ]]; then
            value="$(strip_wrapping_quotes "$(trim "${option#*=}")")"
            option="${option%%=*}"
            if ! option_takes_value "$option"; then
                error_option "$option does not take a value."
                usage 1
            fi
            apply_saved_option "$option" 1 "$value"
        elif [[ "$option" == "$trimmed" ]]; then
            if option_takes_value "$option"; then
                error_option "$option requires a value."
                usage 1
            fi
            apply_saved_option "$option" 0
        else
            value="$(strip_wrapping_quotes "$(trim "${trimmed#"$option"}")")"
            if ! option_takes_value "$option"; then
                error_option "$option does not take a value."
                usage 1
            fi
            apply_saved_option "$option" 1 "$value"
        fi
    done < "$file"
    OPTION_ORIGIN=""
}

reset_skips_for_command_line() {
    [[ "$CLI_SKIP_RESET" -eq 1 ]] && return 0
    CLI_SKIP_RESET=1
    SKIP_LIST=()
    SKIP_LIST_RAW="$SAVED_SKIP_RAW"
}

parse_command_line() {
    local option="" value=""
    APPLYING_CLI=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            sync) COMMAND="sync"; shift ;;
            profile)
                COMMAND="profile"
                need_value "$1" "${2:-}"
                PROFILE_USERNAME="$2"
                shift 2
                ;;
            list-repos)
                COMMAND="list-repos"
                need_value "$1" "${2:-}"
                LIST_USERNAME="$2"
                shift 2
                ;;
            setup) COMMAND="setup"; shift ;;
            install|--install) COMMAND="install"; shift ;;
            update|--update) COMMAND="update"; shift ;;
            uninstall|--uninstall) COMMAND="uninstall"; shift ;;
            enable|disable|start|stop|restart|is-enabled|is-active|status|journal)
                COMMAND="$1"
                shift
                ;;
            --config)
                shift 2
                ;;
            --config=*)
                shift
                ;;
            --base-dir|--profile|--list-repos|--skip|--skip-list|--log-file|--schedule|--token)
                need_value "$1" "${2:-}"
                apply_saved_option "$1" 1 "$2"
                shift 2
                ;;
            *)
                if [[ "$1" == --*=* ]]; then
                    option="${1%%=*}"
                    value="$(strip_wrapping_quotes "${1#*=}")"
                    if option_takes_value "$option"; then
                        apply_saved_option "$option" 1 "$value"
                    else
                        error_option "$option does not take a value."
                        usage 1
                    fi
                else
                    apply_saved_option "$1" 0
                fi
                shift
                ;;
        esac
    done
    APPLYING_CLI=0
}

parse_args() {
    local -a saved=("$@")
    SAVED_SKIP_RAW="$SKIP_LIST_RAW"
    find_config_file "${saved[@]}"
    if [[ -n "$CONFIG_FILE" ]]; then
        CONFIG_FROM_CLI=1
        load_option_file "$CONFIG_FILE"
    elif [[ -f "$CONFIG_PATH" && -r "$CONFIG_PATH" ]]; then
        CONFIG_FILE="$CONFIG_PATH"
        load_option_file "$CONFIG_FILE"
    elif [[ -e "$CONFIG_PATH" ]]; then
        warn "Option file is not a readable file: $CONFIG_PATH"
    fi
    parse_command_line "${saved[@]}"
    if [[ -n "$SKIP_LIST_RAW" ]]; then
        append_csv_skip "$SKIP_LIST_RAW"
    fi
    if [[ "$SCHEDULE" == *$'\n'* ]]; then
        die "Schedule must be a single line."
    fi
    if [[ "$COMMAND" == "sync" && -n "$PROFILE" ]]; then
        COMMAND="profile"
        PROFILE_USERNAME="$PROFILE"
    fi
}

is_skipped() {
    local name="$1"
    local skipped
    [[ "${#SKIP_LIST[@]}" -gt 0 ]] || return 1
    for skipped in "${SKIP_LIST[@]}"; do
        if [[ -n "$skipped" && "$name" == "$skipped" ]]; then
            return 0
        fi
    done
    return 1
}

is_github_url() {
    local url="$1"
    [[ "$url" =~ (^|@|://)github\.com[:/] ]]
}

operation_in_progress() {
    local repo="$1"
    local marker git_dir
    git_dir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || true)"
    [[ -n "$git_dir" ]] || return 1
    for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply sequencer; do
        if [[ -e "$git_dir/$marker" ]]; then
            return 0
        fi
    done
    return 1
}

repo_is_dirty() {
    local repo="$1"
    [[ -n "$(git -C "$repo" status --porcelain=v1 --untracked-files=all 2>/dev/null)" ]]
}

repo_root() {
    git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

physical_dir() {
    local target="$1"
    local resolved=""
    resolved="$(CDPATH='' cd -P -- "$target" 2>/dev/null && pwd -P)" || resolved=""
    if [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"
    else
        printf '%s\n' "$target"
    fi
}

is_nested_repository() {
    local toplevel="$1"
    local base_phys dir
    base_phys="$(physical_dir "$BASE_DIR")"
    toplevel="$(physical_dir "$toplevel")"
    [[ "$toplevel" == "$base_phys" ]] && return 1
    dir="$(dirname "$toplevel")"
    while [[ "$dir" == "$base_phys"/* ]]; do
        if [[ -e "$dir/.git" ]]; then
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    if [[ -e "$base_phys/.git" ]]; then
        return 0
    fi
    return 1
}

git_with_auth() {
    if [[ -n "$TOKEN" ]]; then
        local auth_header
        printf -v auth_header 'Authorization: Bearer %s' "$TOKEN"
        # SSH remotes ignore an HTTP header. Rewrite GitHub SSH URLs to HTTPS
        # for this command only; the remote saved in the repository stays put.
        GIT_TERMINAL_PROMPT=0 \
            GIT_CONFIG_COUNT=3 \
            GIT_CONFIG_KEY_0=http.extraHeader \
            GIT_CONFIG_VALUE_0="$auth_header" \
            GIT_CONFIG_KEY_1='url.https://github.com/.insteadOf' \
            GIT_CONFIG_VALUE_1='git@github.com:' \
            GIT_CONFIG_KEY_2='url.https://github.com/.insteadOf' \
            GIT_CONFIG_VALUE_2='ssh://git@github.com/' \
            git "$@"
    else
        GIT_TERMINAL_PROMPT=0 git "$@"
    fi
}

record_skip() {
    local repo="$1"
    local reason="$2"
    skipped_count=$((skipped_count + 1))
    warn "Skipping $(basename "$repo"): $reason"
    log_message WARN "Skipped $repo: $reason"
    append_report_note "Skipping $(basename "$repo"): $reason"
}

record_failure() {
    local repo="$1"
    local reason="$2"
    reason="${reason%%$'\n'*}"
    failed_count=$((failed_count + 1))
    error "$(basename "$repo"): $reason"
    log_message ERROR "$repo: $reason"
    append_report_note "$(basename "$repo"): $reason"
}

record_result() {
    local name="$1"
    local outcome="$2"
    append_report_note "$name: $outcome"
}

record_diffstat() {
    local repo="$1"
    local old="$2"
    local new="$3"
    local line=""
    [[ -n "$old" && -n "$new" && "$old" != "$new" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        if [[ "$QUIET" -eq 0 ]]; then
            printf '  %s\n' "$line"
        fi
        log_message INFO "$line"
        append_report_note "  $line"
    done < <(git --no-pager -C "$repo" -c color.ui=never diff --stat "$old" "$new" 2>/dev/null || true)
}

acquire_lock() {
    [[ "$LOCK_ACQUIRED" -eq 1 ]] && return 0
    local lock="$BASE_DIR/.github-backup.lock"
    have_cmd flock || die "flock is required (util-linux)."
    exec 9>"$lock" || die "Could not create lock file: $lock"
    if ! flock -n 9; then
        die "Another github-backup is already running for $BASE_DIR."
    fi
    LOCK_ACQUIRED=1
}

commit_phrase() {
    local count="$1"
    if [[ "$count" -eq 1 ]]; then
        printf '1 commit'
    else
        printf '%s commits' "$count"
    fi
}

read_upstream_tip() {
    local repo="$1"
    local remote="$2"
    local upstream="$3"
    local output="" oid=""
    UPSTREAM_TIP=""
    FETCH_ERROR=""
    if [[ "$DRY_RUN" -eq 1 ]]; then
        oid="$(git -C "$repo" rev-parse "${upstream}^{commit}" 2>/dev/null || true)"
    else
        debug "Fetching $remote for $repo"
        if ! output="$(git_with_auth -C "$repo" fetch --prune "$remote" 2>&1)"; then
            FETCH_ERROR="${output%%$'\n'*}"
            return 1
        fi
        oid="$(git -C "$repo" rev-parse "${upstream}^{commit}" 2>/dev/null || true)"
    fi
    if [[ -z "$oid" ]]; then
        return 1
    fi
    UPSTREAM_TIP="$oid"
}

sync_repo() {
    local repo="$1"
    local name branch upstream remote remote_url local_oid upstream_oid output ahead behind
    name="$(basename "$repo")"

    if is_skipped "$name"; then
        record_skip "$repo" "listed in skip configuration"
        return 0
    fi

    if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        record_skip "$repo" "not a Git working tree"
        return 0
    fi

    if operation_in_progress "$repo"; then
        record_skip "$repo" "a merge, rebase, cherry-pick, revert, or bisect is in progress"
        return 0
    fi

    local git_dir index_lock
    git_dir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || true)"
    index_lock="$git_dir/index.lock"
    if [[ -n "$git_dir" && -e "$index_lock" ]]; then
        record_skip "$repo" "Git index is locked"
        return 0
    fi

    branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
        record_skip "$repo" "detached HEAD"
        return 0
    fi

    upstream="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    if [[ -z "$upstream" ]]; then
        record_skip "$repo" "branch '$branch' has no upstream"
        return 0
    fi

    remote="${upstream%%/*}"
    remote_url="$(git -C "$repo" config --get "remote.$remote.url" 2>/dev/null || true)"
    if [[ -z "$remote_url" ]] || ! is_github_url "$remote_url"; then
        record_skip "$repo" "upstream remote is not GitHub"
        return 0
    fi

    if [[ "$FORCE_FAST_FORWARD" -eq 0 ]] && repo_is_dirty "$repo"; then
        record_skip "$repo" "working tree contains staged, unstaged, or untracked work"
        return 0
    fi

    local_oid="$(git -C "$repo" rev-parse 'HEAD^{commit}' 2>/dev/null || true)"
    if [[ -z "$local_oid" ]]; then
        record_failure "$repo" "could not resolve local or upstream commit"
        return 0
    fi
    if ! read_upstream_tip "$repo" "$remote" "$upstream"; then
        if [[ -n "$FETCH_ERROR" ]]; then
            record_failure "$repo" "fetch failed: $FETCH_ERROR"
        else
            record_failure "$repo" "could not resolve local or upstream commit"
        fi
        return 0
    fi
    upstream_oid="$UPSTREAM_TIP"

    if [[ "$FORCE_FAST_FORWARD" -eq 1 ]]; then
        if [[ "$local_oid" == "$upstream_oid" ]] && ! repo_is_dirty "$repo"; then
            unchanged_count=$((unchanged_count + 1))
            [[ "$VERBOSE" -eq 1 ]] && ok "$name: up to date"
            log_message OK "$repo up to date"
            record_result "$name" "up to date"
            return 0
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "$name: would reset to $upstream and delete untracked files"
            updated_count=$((updated_count + 1))
            log_message INFO "$repo would reset to $upstream"
            record_result "$name" "would reset to $upstream and delete untracked files"
            record_diffstat "$repo" "$local_oid" "$upstream_oid"
            return 0
        fi
        warn "Force-aligning $name to $upstream; local changes and local-only commits will be discarded"
        if ! output="$(git -C "$repo" reset --hard "$upstream_oid" 2>&1)"; then
            record_failure "$repo" "hard reset failed: $output"
            return 0
        fi
        if ! output="$(git -C "$repo" clean -fd 2>&1)"; then
            record_failure "$repo" "removing untracked files failed: $output"
            return 0
        fi
        updated_count=$((updated_count + 1))
        ok "$name aligned to $upstream"
        log_message OK "$repo aligned to $upstream"
        record_result "$name" "aligned to $upstream"
        record_diffstat "$repo" "$local_oid" "$upstream_oid"
        return 0
    fi

    if repo_is_dirty "$repo"; then
        record_skip "$repo" "working tree changed while the remote was being fetched"
        return 0
    fi

    if [[ "$local_oid" == "$upstream_oid" ]]; then
        unchanged_count=$((unchanged_count + 1))
        [[ "$VERBOSE" -eq 1 ]] && ok "$name: up to date"
        log_message OK "$repo up to date"
        record_result "$name" "up to date"
        return 0
    fi

    behind="$(git -C "$repo" rev-list --count "${local_oid}..${upstream_oid}" 2>/dev/null || printf '0')"
    ahead="$(git -C "$repo" rev-list --count "${upstream_oid}..${local_oid}" 2>/dev/null || printf '0')"
    if [[ "$ahead" -eq 0 && "$behind" -gt 0 ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "$name: would fast-forward $(commit_phrase "$behind") to $upstream"
            updated_count=$((updated_count + 1))
            log_message INFO "$repo would fast-forward $(commit_phrase "$behind") to $upstream"
            record_result "$name" "would fast-forward $(commit_phrase "$behind") to $upstream"
            record_diffstat "$repo" "$local_oid" "$upstream_oid"
            return 0
        fi
        if output="$(git -C "$repo" merge --ff-only --no-edit "$upstream_oid" 2>&1)"; then
            updated_count=$((updated_count + 1))
            ok "$name fast-forwarded $(commit_phrase "$behind") to $upstream"
            log_message OK "$repo fast-forwarded to $upstream"
            record_result "$name" "fast-forwarded $(commit_phrase "$behind") to $upstream"
            record_diffstat "$repo" "$local_oid" "$upstream_oid"
        else
            record_failure "$repo" "fast-forward failed: $output"
        fi
    elif [[ "$behind" -eq 0 && "$ahead" -gt 0 ]]; then
        record_skip "$repo" "$(commit_phrase "$ahead") ahead of $upstream"
    else
        record_skip "$repo" "diverged from $upstream ($(commit_phrase "$ahead") ahead, $(commit_phrase "$behind") behind)"
    fi
}

sync_tree() {
    [[ -d "$BASE_DIR" ]] || die "Base directory does not exist: $BASE_DIR"
    acquire_lock
    local -A seen=()
    local marker repo toplevel
    while IFS= read -r -d '' marker; do
        repo="$(dirname "$marker")"
        toplevel="$(repo_root "$repo" || true)"
        [[ -n "$toplevel" ]] || continue
        toplevel="$(physical_dir "$toplevel")"
        if [[ -n "${seen[$toplevel]+x}" ]]; then
            continue
        fi
        seen["$toplevel"]=1
        if is_nested_repository "$toplevel"; then
            record_skip "$toplevel" "inside another repository"
            continue
        fi
        sync_repo "$toplevel"
    done < <(find "$BASE_DIR" -name .git \( -type d -o -type f \) -prune -print0 2>/dev/null)
}

github_api() {
    local endpoint="$1"
    local -a options=(--fail-with-body --silent --show-error --location
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
        -H "User-Agent: github-backup/$VERSION")
    if [[ -n "$TOKEN" ]]; then
        local auth_header
        printf -v auth_header 'Authorization: Bearer %s' "$TOKEN"
        options+=(-H "$auth_header")
    fi
    curl "${options[@]}" "$API_URL$endpoint"
}

validate_owner() {
    local owner="$1"
    [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]
}

authenticated_login() {
    local response="" quiet="${1:-0}"
    [[ -n "$TOKEN" ]] || return 0
    response="$(github_api /user 2>/dev/null || true)"
    if [[ -z "$response" ]]; then
        if [[ "$quiet" -eq 0 ]]; then
            warn "Could not read the authenticated GitHub login. Private repositories may be omitted."
        fi
        return 0
    fi
    printf '%s' "$response" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("login") or "")
except Exception:
    print("")
' 2>/dev/null || true
}

github_owner_kind() {
    local owner="$1"
    local response=""
    response="$(github_api "/users/$owner" 2>/dev/null || true)"
    printf '%s' "$response" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    print("user")
    raise SystemExit(0)
print("org" if data.get("type") == "Organization" else "user")
' 2>/dev/null || printf '%s\n' user
}

github_repo_rows() {
    local owner="$1"
    local auth_login="" kind="" endpoint page response count first_name="" page_marker=""
    if ! validate_owner "$owner"; then
        error "Invalid GitHub profile name: $owner"
        append_report_note "Invalid GitHub profile name: $owner"
        return 2
    fi
    auth_login="$(authenticated_login)"
    kind="$(github_owner_kind "$owner")"
    page=1

    while true; do
        if [[ "$kind" == "org" ]]; then
            endpoint="/orgs/$owner/repos?type=all&sort=full_name&per_page=100&page=$page"
        elif [[ -n "$auth_login" && "${auth_login,,}" == "${owner,,}" ]]; then
            endpoint="/user/repos?affiliation=owner&visibility=all&sort=full_name&per_page=100&page=$page"
        else
            endpoint="/users/$owner/repos?type=owner&sort=full_name&per_page=100&page=$page"
        fi

        if ! response="$(github_api "$endpoint")"; then
            return 1
        fi
        count="$(python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    print(-1)
    raise SystemExit(0)
print(len(data) if isinstance(data, list) else -1)' <<< "$response" 2>/dev/null || printf '%s' '-1')"
        if [[ "$count" -lt 0 ]]; then
            error "Could not parse the GitHub repository list for '$owner'."
            append_report_note "Could not parse the GitHub repository list for '$owner'."
            return 2
        fi
        if [[ "$count" -eq 0 ]]; then
            break
        fi

        first_name="$(OWNER_FILTER="$owner" python3 -c '
import json, os, sys
owner = os.environ["OWNER_FILTER"].casefold()
for repo in json.load(sys.stdin):
    if str(repo.get("owner", {}).get("login", "")).casefold() != owner:
        continue
    print(repo.get("name", ""))
    break
' <<< "$response" 2>/dev/null || true)"
        if [[ -n "$first_name" && "$page" -gt 1 && "$first_name" == "$page_marker" ]]; then
            break
        fi
        if [[ "$page" -eq 1 && -n "$first_name" ]]; then
            page_marker="$first_name"
        fi

        OWNER_FILTER="$owner" python3 -c '
import json, os, sys
owner = os.environ["OWNER_FILTER"].casefold()
for repo in json.load(sys.stdin):
    if str(repo.get("owner", {}).get("login", "")).casefold() != owner:
        continue
    fields = [
        repo.get("name", ""),
        repo.get("clone_url", ""),
        "private" if repo.get("private") else "public",
    ]
    print("\t".join(str(field) for field in fields))
' <<< "$response" || {
            error "Could not parse the GitHub repository list for '$owner'."
            append_report_note "Could not parse the GitHub repository list for '$owner'."
            return 2
        }
        page=$((page + 1))
    done
}

load_profile_rows() {
    local owner="$1"
    local rows_file="" status=0 old_umask=""
    PROFILE_ROWS=""
    old_umask="$(umask)"
    umask 077
    rows_file="$(mktemp)" || {
        umask "$old_umask"
        die "Could not create a temporary file"
    }
    umask "$old_umask"
    github_repo_rows "$owner" >"$rows_file" || status=$?
    PROFILE_ROWS="$(cat "$rows_file")"
    rm -f "$rows_file"
    if [[ "$status" -eq 2 ]]; then
        exit 1
    fi
    return "$status"
}

list_profile_repositories() {
    local owner="$1"
    local rows=""
    if ! load_profile_rows "$owner"; then
        die "GitHub API request failed for profile '$owner'."
    fi
    rows="$PROFILE_ROWS"
    if [[ -z "$rows" ]]; then
        warn "No repositories visible for GitHub profile '$owner'."
        return 0
    fi
    printf '%s\n' "$rows" | while IFS=$'\t' read -r name _clone visibility; do
        if [[ "$VERBOSE" -eq 1 ]]; then
            printf '%-48s %s\n' "$name" "$visibility"
        else
            printf '%s\n' "$name"
        fi
    done
}

clone_repo() {
    local owner="$1" name="$2" clone_url="$3" visibility="$4"
    local destination="$BASE_DIR/$name"
    if is_skipped "$name"; then
        record_skip "$destination" "listed in skip configuration"
        return 0
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
        if [[ -L "$destination" ]]; then
            record_skip "$destination" "destination is a symbolic link"
        elif [[ ! -d "$destination/.git" && ! -f "$destination/.git" ]]; then
            record_skip "$destination" "destination is not a repository root"
        elif git -C "$destination" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            local destination_root="" destination_physical=""
            destination_root="$(repo_root "$destination" || true)"
            destination_physical="$(CDPATH='' cd -P -- "$destination" 2>/dev/null && pwd -P)" || destination_physical=""
            if [[ -z "$destination_root" || "$destination_root" != "$destination_physical" ]]; then
                record_skip "$destination" "destination is inside another repository, not a repository root"
            else
                sync_repo "$destination"
            fi
        else
            record_skip "$destination" "destination exists but is not a Git repository"
        fi
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$owner/$name: would clone into $destination"
        cloned_count=$((cloned_count + 1))
        record_result "$owner/$name" "would clone into $destination"
        return 0
    fi

    mkdir -p "$BASE_DIR" || {
        record_failure "$destination" "could not create base directory"
        return 0
    }

    local output=""
    if output="$(git_with_auth clone --origin origin "$clone_url" "$destination" 2>&1)"; then
        cloned_count=$((cloned_count + 1))
        ok "Cloned $owner/$name"
        log_message OK "Cloned $destination"
        record_result "$owner/$name" "cloned"
    else
        record_failure "$destination" "clone failed: $output"
    fi
}

sync_profile() {
    local owner="$1"
    local rows=""
    if ! load_profile_rows "$owner"; then
        die "GitHub API request failed for profile '$owner'."
    fi
    rows="$PROFILE_ROWS"
    if [[ -z "$rows" ]]; then
        warn "No repositories visible for GitHub profile '$owner'."
        return 0
    fi
    if [[ -d "$BASE_DIR" ]]; then
        acquire_lock
    elif [[ "$DRY_RUN" -eq 0 ]]; then
        mkdir -p "$BASE_DIR" || die "Could not create base directory: $BASE_DIR"
        acquire_lock
    fi
    while IFS=$'\t' read -r name clone_url visibility; do
        [[ -n "$name" ]] || continue
        clone_repo "$owner" "$name" "$clone_url" "$visibility"
    done <<< "$rows"
}

print_summary() {
    local summary
    if [[ "$DRY_RUN" -eq 1 ]]; then
        summary="Summary: $updated_count would update, $cloned_count would clone, $unchanged_count unchanged, $skipped_count skipped, $failed_count failed"
    else
        summary="Summary: $updated_count updated, $cloned_count cloned, $unchanged_count unchanged, $skipped_count skipped, $failed_count failed"
    fi
    if [[ "$QUIET" -eq 0 ]]; then
        printf '\n%s\n' "$summary"
    fi
    log_message INFO "$summary"
}

finish_backup() {
    REPORT_FINISHED=1
    print_summary
    [[ "$failed_count" -eq 0 ]]
}

append_report_note() {
    local line="$1"
    line="${line//$'\r'/}"
    line="${line%%$'\n'*}"
    [[ -n "$line" ]] || return 0
    if [[ "$REPORT_NOTE_COUNT" -gt 2000 ]]; then
        return 0
    fi
    if [[ "${#line}" -gt 500 ]]; then
        line="${line:0:500}..."
    fi
    if [[ "$REPORT_NOTE_COUNT" -eq 2000 || "${#REPORT_NOTES}" -ge 262144 ]]; then
        REPORT_NOTES+=$'...\n'
        REPORT_NOTE_COUNT=2001
        return 0
    fi
    REPORT_NOTES+="$line"$'\n'
    REPORT_NOTE_COUNT=$((REPORT_NOTE_COUNT + 1))
}

report_host() {
    local host="${HOSTNAME:-}"
    if [[ -z "$host" ]]; then
        host="$(uname -n 2>/dev/null || true)"
    fi
    host="${host%%.*}"
    host="${host//$'\n'/}"
    host="${host//$'\r'/}"
    [[ -n "$host" ]] || host="unknown"
    printf '%s' "$host"
}

notify_url_acceptable() {
    local url="$1"
    [[ "$url" != *$'\n'* ]] || return 1
    [[ "$url" != *$'\r'* ]] || return 1
    [[ "$url" != *" "* ]] || return 1
    [[ "$url" == http://* || "$url" == https://* ]]
}

# Post one application/x-www-form-urlencoded report. Other scripts can copy
# this request: fields are _subject, host, program, status, summary, and log.
# Accept: application/json asks the endpoint for JSON when it supports that.
# Formester's form endpoint is one host this works with.
submit_run_report() {
    [[ "$REPORT_SUBMITTED" -eq 0 ]] || return 0
    REPORT_SUBMITTED=1
    [[ "$REPORT_RUN" -eq 1 ]] || return 0
    [[ "$DRY_RUN" -eq 0 ]] || return 0
    [[ -n "$NOTIFY_URL" ]] || return 0

    local host status summary subject
    host="$(report_host)"
    if [[ "$REPORT_ABORTED" -eq 1 || "$failed_count" -gt 0 ]]; then
        status="failed"
    else
        status="ok"
    fi
    if [[ "$NOTIFY_ON_ERROR" -eq 1 && "$status" == "ok" ]]; then
        return 0
    fi

    if ! notify_url_acceptable "$NOTIFY_URL"; then
        warn "Ignoring the run-report URL because it is not a single http or https URL."
        log_message WARN "Ignoring the run-report URL because it is not a single http or https URL."
        return 0
    fi
    if ! have_cmd curl; then
        warn "Run report requested but curl is not installed."
        log_message WARN "Run report requested but curl is not installed."
        return 0
    fi

    summary="Summary: $updated_count updated, $cloned_count cloned, $unchanged_count unchanged, $skipped_count skipped, $failed_count failed"
    if [[ "$REPORT_ABORTED" -eq 1 && "$failed_count" -eq 0 ]]; then
        subject="$PROGRAM $host: stopped before finishing"
    else
        subject="$PROGRAM $host: $failed_count failed, $skipped_count skipped, $updated_count updated"
    fi
    if [[ "${#subject}" -gt 180 ]]; then
        subject="${subject:0:179}..."
    fi

    if ! curl --silent --fail \
        --max-time 20 \
        --connect-timeout 10 \
        --proto '=http,https' \
        --proto-redir '=http,https' \
        --max-redirs 3 \
        -H "Accept: application/json" \
        -H "User-Agent: $PROGRAM/$VERSION" \
        --data-urlencode "_subject=$subject" \
        --data-urlencode "host=$host" \
        --data-urlencode "program=$PROGRAM" \
        --data-urlencode "status=$status" \
        --data-urlencode "summary=$summary" \
        --data-urlencode "log=$REPORT_NOTES" \
        -o /dev/null \
        -- "$NOTIFY_URL" \
        2>/dev/null
    then
        warn "Could not submit the run report."
        log_message WARN "Could not submit the run report."
        return 0
    fi
    info "Submitted the run report."
}

on_exit_report() {
    local status=$?
    if [[ "$REPORT_RUN" -eq 1 && "$REPORT_FINISHED" -ne 1 && "$status" -ne 0 ]]; then
        REPORT_ABORTED=1
    fi
    submit_run_report || true
    exit "$status"
}

begin_run_report() {
    REPORT_RUN=1
    trap on_exit_report EXIT
}

generate_bash_completion() {
    cat <<'EOF'
# bash completion for github-backup
_github_backup() {
    local cur prev words cword
    if declare -F _init_completion >/dev/null 2>&1; then
        _init_completion || return
    else
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
    fi
    local commands="sync profile list-repos setup install update uninstall enable disable start stop restart is-enabled is-active status journal"
    local options="--base-dir --profile --list-repos --skip --skip-list --dry-run --verbose --debug --quiet --notify-on-error --force-fast-forward --log-file --schedule --config --token --no-systemd --purge-config --force --no-completion --completion-only --uninstall-completion --version --help -q -f -V -h"
    if [[ "$prev" == "--base-dir" || "$prev" == "--log-file" ]]; then
        COMPREPLY=( $(compgen -d -- "$cur") )
        return 0
    fi
    if [[ "$prev" == "--config" ]]; then
        COMPREPLY=( $(compgen -f -- "$cur") )
        return 0
    fi
    COMPREPLY=( $(compgen -W "$commands $options" -- "$cur") )
}
complete -F _github_backup github-backup
EOF
}

detect_completion_dir() {
    if [[ -n "${GITHUB_BACKUP_COMPLETION_DIR:-}" ]]; then
        printf '%s\n' "$GITHUB_BACKUP_COMPLETION_DIR"
        return 0
    fi
    if [[ -d /usr/share/bash-completion/completions ]]; then
        printf '%s\n' /usr/share/bash-completion/completions
        return 0
    fi
    if [[ -d /etc/bash_completion.d ]]; then
        printf '%s\n' /etc/bash_completion.d
        return 0
    fi
    return 1
}

install_completion() {
    local directory="" file="" temporary=""
    directory="$(detect_completion_dir)" || {
        warn "bash-completion directory not found; skipping completion"
        return 0
    }
    require_root "$directory"
    file="$directory/github-backup"
    [[ ! -d "$file" ]] || die "$file is a directory, expected a completion file"
    mkdir -p "$directory" || die "Could not create $directory"
    if [[ -e "$file" && "$FORCE" -ne 1 ]]; then
        die "Completion already exists at $file (use --force to overwrite)."
    fi
    temporary="$(mktemp "$directory/.github-backup.XXXXXX")" || die "Could not stage Bash completion"
    generate_bash_completion > "$temporary" || { rm -f "$temporary"; die "Could not generate Bash completion"; }
    chmod 0644 "$temporary" || { rm -f "$temporary"; die "Could not set completion permissions"; }
    mv -f "$temporary" "$file" || { rm -f "$temporary"; die "Could not install Bash completion"; }
    ok "Bash completion installed."
}

uninstall_completion() {
    local directory="" file=""
    directory="$(detect_completion_dir)" || {
        warn "No bash-completion directory found."
        return 0
    }
    require_root "$directory"
    file="$directory/github-backup"
    if [[ ! -e "$file" ]]; then
        warn "No completion installed at $file"
        return 0
    fi
    rm -f "$file"
    ok "Bash completion removed."
}

install_binary() {
    local src="$1"
    local dest="$2"
    if [[ "$(id -u)" -eq 0 ]]; then
        install -m 0755 -o root -g root "$src" "$dest"
    else
        install -m 0755 "$src" "$dest"
    fi
}

write_env_assignment() {
    local key="$1"
    local value="$2"
    local escaped
    if [[ "$value" =~ ^[A-Za-z0-9_@%+=:,./-]*$ ]]; then
        printf '%s=%s\n' "$key" "$value"
        return 0
    fi
    escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    escaped="${escaped//$'\n'/\\n}"
    printf '%s="%s"\n' "$key" "$escaped"
}

preserved_assignment() {
    local key="$1"
    local line=""
    [[ -f "$DEFAULTS_FILE" ]] || return 1
    line="$(grep -E "^${key}=" "$DEFAULTS_FILE" || true)"
    line="${line%%$'\n'*}"
    [[ -n "$line" ]] || return 1
    printf '%s\n' "$line"
}

write_defaults_file() {
    local directory="" temporary="" token_line=""
    directory="$(dirname "$DEFAULTS_FILE")"
    mkdir -p "$directory" || die "Could not create $directory"
    if [[ -d "$DEFAULTS_FILE" ]]; then
        die "$DEFAULTS_FILE is a directory, expected a file"
    fi
    if [[ -e "$DEFAULTS_FILE" && "$FORCE" -ne 1 ]]; then
        warn "Configuration already exists at $DEFAULTS_FILE; preserving it"
        return 0
    fi
    token_line="$(preserved_assignment GITHUB_BACKUP_TOKEN || true)"
    temporary="$(mktemp "$directory/.github-backup.XXXXXX")" || die "Could not stage configuration in $directory"
    if ! {
        write_env_assignment GITHUB_BACKUP_BASE_DIR "$BASE_DIR"
        write_env_assignment GITHUB_BACKUP_PROFILE "$PROFILE"
        write_env_assignment GITHUB_BACKUP_LOG_FILE "$LOG_FILE"
        if [[ -n "$NOTIFY_URL" ]]; then
            write_env_assignment GITHUB_BACKUP_NOTIFY_URL "$NOTIFY_URL"
        else
            printf '%s\n' '# GITHUB_BACKUP_NOTIFY_URL=https://formester.com/f/yourFormId'
        fi
        if [[ -n "$token_line" ]]; then
            printf '%s\n' "$token_line"
        else
            printf '%s\n' '# GITHUB_BACKUP_TOKEN=github_pat_...'
        fi
        if [[ -n "$SKIP_LIST_RAW" ]]; then
            write_env_assignment GITHUB_BACKUP_SKIP_LIST "$SKIP_LIST_RAW"
        else
            printf '%s\n' '# GITHUB_BACKUP_SKIP_LIST=repo-one,repo-two'
        fi
    } > "$temporary"; then
        rm -f "$temporary"
        die "Could not write staged configuration"
    fi
    chmod 0600 "$temporary" || { rm -f "$temporary"; die "Could not secure staged configuration"; }
    mv -f "$temporary" "$DEFAULTS_FILE" || { rm -f "$temporary"; die "Could not install $DEFAULTS_FILE"; }
    ok "Installed configuration: $DEFAULTS_FILE"
}

option_file_template() {
    cat <<'EOF'
# This is the github-backup system-wide configuration file. See the full
# README:
# https://github.com/peternickol/github-backup/blob/master/README.md
#
# The strategy matches sshd_config: each option is shown with a sample
# value, commented out. Remove the leading "# " to set it. Uncommented
# options override the default. This file is read first. A command-line
# flag replaces the same option. A setting neither one mentions comes
# from the environment, then /etc/default/github-backup, then the
# built-in default.
#
# The command stays on the command line:
#   github-backup sync
#   github-backup profile USER
#   github-backup setup
# https://github.com/peternickol/github-backup/blob/master/README.md#commands
#
# What a run does
#   Fast-forward clean GitHub checkouts. A token downloads every
#   repository that account owns. --profile selects another account.
#   Dirty, ahead, diverged, and detached checkouts are skipped.
#   --force-fast-forward is the only destructive override. Leave that
#   line commented.
# https://github.com/peternickol/github-backup/blob/master/README.md#safety
#
# Token
#   Uncomment --token and paste a GitHub token. sync then downloads every
#   repository that account owns into the base directory. Keep this file
#   mode 600. Do not commit the file after the token is filled in. setup
#   does not copy the token into /etc/default/github-backup. A token on
#   the command line replaces this one and is kept in shell history.
# https://github.com/peternickol/github-backup/blob/master/README.md#configuration
#
# Run report
#   The only notification is a form POST. Set the endpoint in
#   /etc/default/github-backup:
#     GITHUB_BACKUP_NOTIFY_URL=https://formester.com/f/yourFormId
#   A real sync or profile submits after every run. The log names every
#   repository and what happened to it. A fast-forward includes git's
#   diffstat. Uncomment --notify-on-error to
#   submit only when a repository fails or the run stops early. A dry run
#   does not submit. Turn off reCAPTCHA.
# https://github.com/peternickol/github-backup/blob/master/README.md#run-report
#
# Schedule
#   Uncomment --schedule, then run: github-backup setup --force
#   The timer default is *-*-* 02:00:00. The timer may wait up to 30 minutes.
# https://github.com/peternickol/github-backup/blob/master/README.md#schedule

# Repository options
# https://github.com/peternickol/github-backup/blob/master/README.md#options

# Directory to crawl, or where a profile is cloned.
# Default when commented: $HOME/github-backup
# --base-dir /mnt/nas/github

# On sync, clone and update this user or organization instead of the
# account that owns the token. On setup, save it.
# https://github.com/peternickol/github-backup/blob/master/README.md#profile
# --profile YOUR_GITHUB_USERNAME

# Skip one repository directory name. Repeat the line to skip more than one.
# Names are added to the list from the environment or the defaults file.
# A --skip or --skip-list on the command line replaces these names.
# --skip repo-one
# --skip repo-two

# Replace the skip list from the environment or the defaults file.
# On setup --force, this also replaces the saved list.
# --skip-list repo-one,repo-two

# Log path. Default when commented: /var/log/github-backup.log
# --log-file /var/log/github-backup.log

# GitHub token. With no --profile, sync downloads the account that owns it.
# --token github_pat_...

# Show what the recorded upstream would do. Does not fetch or merge.
# Leave this commented for a real backup. There is no --no-dry-run.
# https://github.com/peternickol/github-backup/blob/master/README.md#sync
# --dry-run

# Also print repositories that are already current.
# --verbose

# Print each fetch target on stderr, even with --quiet.
# --debug

# Hide info, ok, and warning lines. Errors still print.
# --quiet

# Submit the form report only when a repository fails or the run stops early.
# The default submits after every real sync or profile.
# https://github.com/peternickol/github-backup/blob/master/README.md#run-report
# --notify-on-error

# Reset eligible branches and delete untracked files. Leave this commented.
# https://github.com/peternickol/github-backup/blob/master/README.md#safety
# --force-fast-forward

# Setup options
# https://github.com/peternickol/github-backup/blob/master/README.md#setup

# systemd OnCalendar value. Default when commented: *-*-* 02:00:00
# Pass setup --force after changing this line.
# --schedule *-*-* 02:00:00

# Write configuration and skip the service and timer.
# --no-systemd

# Replace existing units and rewrite /etc/default/github-backup.
# An uncommented token in that defaults file is kept. This file's
# uncommented lines are kept too. Leave this commented.
# --force

# Uninstall options
# https://github.com/peternickol/github-backup/blob/master/README.md#uninstall

# Also remove /etc/default/github-backup and this option file.
# Repositories, the base directory, and the log stay.
# --purge-config
EOF
}

preserved_option_lines() {
    local line="" trimmed=""
    [[ -f "$CONFIG_PATH" && -r "$CONFIG_PATH" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        trimmed="$(trim "$line")"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        case "$trimmed" in
            --config|--config\ *|--config=*)
                warn "Ignoring nested --config in $CONFIG_PATH"
                continue
                ;;
        esac
        printf '%s\n' "$trimmed"
    done < "$CONFIG_PATH"
}

format_config_word() {
    local value="$1"
    if [[ "$value" =~ ^[A-Za-z0-9_@%+=:,./-]*$ ]]; then
        printf '%s' "$value"
        return 0
    fi
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

write_option_file() {
    local directory="" temporary="" kept=""
    directory="$(dirname "$CONFIG_PATH")"
    mkdir -p "$directory" || die "Could not create $directory"
    if [[ -d "$CONFIG_PATH" ]]; then
        die "$CONFIG_PATH is a directory, expected a file"
    fi
    if [[ -e "$CONFIG_PATH" && "$FORCE" -ne 1 ]]; then
        warn "Option file already exists at $CONFIG_PATH; preserving it"
        return 0
    fi
    if [[ -e "$CONFIG_PATH" && ! -r "$CONFIG_PATH" ]]; then
        die "Option file is not readable: $CONFIG_PATH"
    fi
    kept="$(preserved_option_lines || true)"
    temporary="$(mktemp "$directory/.github-backup.conf.XXXXXX")" || die "Could not stage option file in $directory"
    if ! {
        option_file_template
        if [[ -n "$kept" ]]; then
            printf '\n%s\n' '# Settings kept from the previous file.'
            printf '%s\n' "$kept"
        fi
    } > "$temporary"; then
        rm -f "$temporary"
        die "Could not write staged option file"
    fi
    chmod 0600 "$temporary" || { rm -f "$temporary"; die "Could not secure staged option file"; }
    mv -f "$temporary" "$CONFIG_PATH" || { rm -f "$temporary"; die "Could not install $CONFIG_PATH"; }
    ok "Installed option file: $CONFIG_PATH"
}

systemd_control_available() {
    if [[ -n "${GITHUB_BACKUP_SYSTEMCTL:-}" ]]; then
        [[ -x "$SYSTEMCTL_BIN" ]]
        return
    fi
    [[ "$SYSTEMD_DIR" == /etc/systemd/system ]] && has_systemd
}

has_systemd() {
    if [[ -n "${GITHUB_BACKUP_SYSTEMCTL:-}" ]]; then
        [[ -x "$SYSTEMCTL_BIN" ]]
        return
    fi
    have_cmd systemctl && systemctl --version >/dev/null 2>&1
}

run_systemctl() {
    if [[ -n "${GITHUB_BACKUP_SYSTEMCTL:-}" ]]; then
        "$SYSTEMCTL_BIN" "$@"
        return
    fi
    if [[ "$QUIET" -eq 1 ]]; then
        env PATH="/usr/sbin:/usr/bin:/sbin:/bin" systemctl "$@" >/dev/null 2>&1
    else
        env PATH="/usr/sbin:/usr/bin:/sbin:/bin" systemctl "$@"
    fi
}

require_units() {
    [[ -f "$SYSTEMD_DIR/$SERVICE_NAME" && -f "$SYSTEMD_DIR/$TIMER_NAME" ]] \
        || die "systemd units are not installed. Run: $PROGRAM setup"
}

write_systemd_units() {
    local service="$SYSTEMD_DIR/$SERVICE_NAME"
    local timer="$SYSTEMD_DIR/$TIMER_NAME"
    local service_tmp="" timer_tmp=""
    mkdir -p "$SYSTEMD_DIR" || die "Could not create $SYSTEMD_DIR"
    if [[ "$FORCE" -ne 1 && ( -e "$service" || -e "$timer" ) ]]; then
        warn "systemd units already exist; preserving them (use --force to replace)"
        return 0
    fi

    local exec_start="$INSTALL_PATH sync" config_word="" service_config="$CONFIG_PATH"
    if [[ "$CONFIG_FROM_CLI" -eq 1 ]]; then
        service_config="$CONFIG_FILE"
    fi
    config_word="$(format_config_word "$service_config")"
    exec_start+=" --config $config_word"

    service_tmp="$(mktemp "$SYSTEMD_DIR/.github-backup.service.XXXXXX")" || die "Could not stage service unit"
    timer_tmp="$(mktemp "$SYSTEMD_DIR/.github-backup.timer.XXXXXX")" || { rm -f "$service_tmp"; die "Could not stage timer unit"; }

    if ! printf '%s\n' \
        '[Unit]' \
        'Description=Fast-forward local GitHub checkouts' \
        'After=network-online.target' \
        'Wants=network-online.target' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        "EnvironmentFile=-$DEFAULTS_FILE" \
        "ExecStart=$exec_start" \
        'NoNewPrivileges=true' \
        'PrivateTmp=true' > "$service_tmp"; then
        rm -f "$service_tmp" "$timer_tmp"
        die "Could not write staged service unit"
    fi

    if ! printf '%s\n' \
        '[Unit]' \
        'Description=Nightly GitHub repository backup' \
        '' \
        '[Timer]' \
        "Unit=$SERVICE_NAME" \
        "OnCalendar=$SCHEDULE" \
        'Persistent=true' \
        'RandomizedDelaySec=30m' \
        '' \
        '[Install]' \
        'WantedBy=timers.target' > "$timer_tmp"; then
        rm -f "$service_tmp" "$timer_tmp"
        die "Could not write staged timer unit"
    fi

    chmod 0644 "$service_tmp" "$timer_tmp" || { rm -f "$service_tmp" "$timer_tmp"; die "Could not set unit permissions"; }
    mv -f "$service_tmp" "$service" || { rm -f "$service_tmp" "$timer_tmp"; die "Could not install service unit"; }
    mv -f "$timer_tmp" "$timer" || { rm -f "$timer_tmp"; die "Could not install timer unit"; }
    ok "Installed systemd units in $SYSTEMD_DIR"
}

prepare_base_dir() {
    if [[ -d "$BASE_DIR" ]]; then
        ok "Base directory ready: $BASE_DIR"
        return 0
    fi
    if [[ -e "$BASE_DIR" || -L "$BASE_DIR" ]]; then
        die "Base directory path exists and is not a directory: $BASE_DIR"
    fi
    mkdir -p "$BASE_DIR" || die "Could not create base directory: $BASE_DIR"
    ok "Prepared base directory: $BASE_DIR"
}

prepare_log_file() {
    local directory
    directory="$(dirname "$LOG_FILE")"
    if [[ -d "$LOG_FILE" ]]; then
        die "Log path is a directory: $LOG_FILE"
    fi
    if ! mkdir -p "$directory" 2>/dev/null; then
        warn "Could not create log directory: $directory"
        return 0
    fi
    if [[ ! -e "$LOG_FILE" ]]; then
        if ! touch "$LOG_FILE" 2>/dev/null; then
            warn "Could not create log file: $LOG_FILE"
            return 0
        fi
        if [[ "$(id -u)" -eq 0 ]]; then
            chmod 0640 "$LOG_FILE" || true
        fi
    fi
}

cmd_setup() {
    require_root "$DEFAULTS_FILE" "$SYSTEMD_DIR" "$(dirname "$LOG_FILE")" "$CONFIG_PATH"
    prepare_base_dir
    prepare_log_file
    write_defaults_file
    write_option_file
    if [[ "$INSTALL_SYSTEMD" -eq 0 ]]; then
        info "Skipping systemd service and timer (--no-systemd)."
        return 0
    fi
    write_systemd_units
    if systemd_control_available; then
        run_systemctl daemon-reload || die "systemctl daemon-reload failed"
    fi
    info "Setup complete. Arm the schedule with: $PROGRAM enable"
}

cmd_enable() {
    require_root "$SYSTEMD_DIR"
    has_systemd || die "systemd not detected; enable is not available."
    require_units
    run_systemctl daemon-reload || die "systemctl daemon-reload failed"
    run_systemctl enable --now "$TIMER_NAME" || die "Could not enable $TIMER_NAME"
    ok "Enabled $TIMER_NAME"
}

cmd_disable() {
    require_root "$SYSTEMD_DIR"
    has_systemd || die "systemd not detected; disable is not available."
    require_units
    run_systemctl disable --now "$TIMER_NAME" || die "Could not disable $TIMER_NAME"
    ok "Disabled $TIMER_NAME"
}

cmd_start() {
    require_root "$SYSTEMD_DIR"
    has_systemd || die "systemd not detected; start is not available."
    require_units
    run_systemctl start "$SERVICE_NAME" || die "Could not start $SERVICE_NAME"
    ok "Started $SERVICE_NAME"
}

cmd_stop() {
    require_root "$SYSTEMD_DIR"
    has_systemd || die "systemd not detected; stop is not available."
    require_units
    run_systemctl stop "$SERVICE_NAME" || die "Could not stop $SERVICE_NAME"
    ok "Stopped $SERVICE_NAME"
}

cmd_restart() {
    require_root "$SYSTEMD_DIR"
    has_systemd || die "systemd not detected; restart is not available."
    require_units
    run_systemctl restart "$SERVICE_NAME" || die "Could not restart $SERVICE_NAME"
    ok "Restarted $SERVICE_NAME"
}

cmd_is_enabled() {
    require_root "$SYSTEMD_DIR"
    has_systemd || die "systemd not detected; is-enabled is not available."
    require_units
    if "$SYSTEMCTL_BIN" is-enabled "$TIMER_NAME" >/dev/null 2>&1; then
        [[ "$QUIET" -eq 1 ]] || printf '%s\n' enabled
        exit 0
    fi
    [[ "$QUIET" -eq 1 ]] || printf '%s\n' disabled
    exit 1
}

cmd_is_active() {
    require_root "$SYSTEMD_DIR"
    has_systemd || die "systemd not detected; is-active is not available."
    require_units
    if "$SYSTEMCTL_BIN" is-active "$TIMER_NAME" >/dev/null 2>&1; then
        [[ "$QUIET" -eq 1 ]] || printf '%s\n' active
        exit 0
    fi
    [[ "$QUIET" -eq 1 ]] || printf '%s\n' inactive
    exit 1
}

cmd_status() {
    local rc=0
    require_root "$SYSTEMD_DIR"
    has_systemd || die "systemd not detected; status is not available."
    require_units
    run_systemctl --no-pager status "$TIMER_NAME" || rc=$?
    run_systemctl --no-pager status "$SERVICE_NAME" || true
    return "$rc"
}

cmd_journal() {
    require_root "$SYSTEMD_DIR"
    has_systemd || die "systemd not detected; journal is not available."
    require_units
    have_cmd journalctl || die "journalctl is not installed."
    exec journalctl -u "$SERVICE_NAME" -f
}

cmd_install() {
    local src="" dest=""
    if [[ "$UNINSTALL_COMPLETION" -eq 1 ]]; then
        uninstall_completion
        return 0
    fi
    if [[ "$COMPLETION_ONLY" -eq 1 ]]; then
        install_completion
        return 0
    fi

    src="$(self_path)"
    dest="$INSTALL_PATH"
    require_root "$dest"
    [[ -f "$src" ]] || die "Cannot locate script file to install (source: $src)."
    if [[ -e "$dest" && "$FORCE" -ne 1 ]]; then
        die "$dest already exists. Re-run with --force to overwrite."
    fi
    mkdir -p "$(dirname "$dest")" || die "Could not create install directory"
    info "Installing $src → $dest"
    install_binary "$src" "$dest" || die "Failed to install $dest"
    ok "Installed binary: $dest"

    if [[ "$NO_COMPLETION" -eq 0 ]]; then
        install_completion
    else
        info "Skipping completion installation (--no-completion)."
    fi
    info "Installation complete. Try: $PROGRAM --version"
    info "Prepare backups with: $PROGRAM setup --base-dir DIR"
}

download_update_source() {
    local dest="$1"
    if have_cmd curl; then
        curl -fsSL "$UPDATE_URL" -o "$dest" || return 1
        return 0
    fi
    if have_cmd wget; then
        wget -qO "$dest" "$UPDATE_URL" || return 1
        return 0
    fi
    die "Neither curl nor wget is installed. Install one of them to use update."
}

cmd_update() {
    require_root "$INSTALL_PATH"
    local temporary=""
    temporary="$(mktemp "${TMPDIR:-/tmp}/github-backup.update.XXXXXX")" || die "Could not create temporary file"
    # shellcheck disable=SC2064
    trap "rm -f '$temporary'" RETURN
    info "Downloading latest github-backup from $UPDATE_URL"
    download_update_source "$temporary" || { rm -f "$temporary"; die "Download failed"; }
    [[ -s "$temporary" ]] || { rm -f "$temporary"; die "Downloaded update is empty."; }
    bash -n "$temporary" || { rm -f "$temporary"; die "Downloaded script failed syntax validation"; }
    info "Installing update → $INSTALL_PATH"
    install_binary "$temporary" "$INSTALL_PATH" || { rm -f "$temporary"; die "Update install failed"; }
    rm -f "$temporary"
    ok "Updated binary: $INSTALL_PATH"
    trap - RETURN
    if [[ "$NO_COMPLETION" -eq 0 ]]; then
        FORCE=1
        install_completion
    else
        info "Skipping completion installation (--no-completion)."
    fi
    info "Update complete. Try: $PROGRAM --version"
}

cmd_uninstall() {
    local completion_dir=""
    require_root "$INSTALL_PATH" "$SYSTEMD_DIR" "$DEFAULTS_FILE" "$CONFIG_PATH"
    if systemd_control_available; then
        "$SYSTEMCTL_BIN" disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "$SYSTEMD_DIR/$SERVICE_NAME" "$SYSTEMD_DIR/$TIMER_NAME"
    if systemd_control_available; then
        run_systemctl daemon-reload || die "systemctl daemon-reload failed after uninstall"
    fi
    if [[ -e "$INSTALL_PATH" ]]; then
        rm -f "$INSTALL_PATH"
        ok "Removed: $INSTALL_PATH"
    else
        warn "Not installed: $INSTALL_PATH does not exist."
    fi
    completion_dir="$(detect_completion_dir 2>/dev/null || true)"
    if [[ -n "$completion_dir" && -e "$completion_dir/github-backup" ]]; then
        rm -f "$completion_dir/github-backup"
        ok "Bash completion removed."
    fi
    if [[ "$PURGE_CONFIG" -eq 1 ]]; then
        rm -f "$DEFAULTS_FILE" "$CONFIG_PATH"
        ok "Removed configuration: $DEFAULTS_FILE"
        ok "Removed option file: $CONFIG_PATH"
    fi
    ok "Uninstalled github-backup"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
    fi
    apply_config
    parse_args "$@"
    case "$COMMAND" in
        sync)
            begin_run_report
            if [[ -n "$TOKEN" ]]; then
                local login=""
                login="$(authenticated_login 1)"
                if [[ -z "$login" ]]; then
                    die "Could not read the GitHub account for this token, so the profile was not downloaded."
                fi
                if ! validate_owner "$login"; then
                    die "Invalid GitHub profile name: $login"
                fi
                sync_profile "$login"
            else
                sync_tree
            fi
            finish_backup
            ;;
        profile)
            begin_run_report
            [[ -n "$PROFILE_USERNAME" ]] || die "profile requires a GitHub user or organization."
            sync_profile "$PROFILE_USERNAME"
            finish_backup
            ;;
        list-repos)
            [[ -n "$LIST_USERNAME" ]] || die "list-repos requires a GitHub user or organization."
            list_profile_repositories "$LIST_USERNAME"
            ;;
        setup) cmd_setup ;;
        install) cmd_install ;;
        update) cmd_update ;;
        uninstall) cmd_uninstall ;;
        enable) cmd_enable ;;
        disable) cmd_disable ;;
        start) cmd_start ;;
        stop) cmd_stop ;;
        restart) cmd_restart ;;
        is-enabled) cmd_is_enabled ;;
        is-active) cmd_is_active ;;
        status) cmd_status ;;
        journal) cmd_journal ;;
        *) die "Unknown command: $COMMAND" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
