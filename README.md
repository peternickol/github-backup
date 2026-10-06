# github-backup

`github-backup` is a convenience wrapper that crawls directory trees for GitHub repositories and then git pulls them periodically every night. It is designed to be run as a periodic cron job or systemd timer to keep local mirrors of GitHub repositories in sync.

Can operate in two modes:
1. Local directory crawl - finds `.git` directories under a base directory
2. GitHub profile download - downloads all repos from a GitHub user profile

The installed launcher path is:
- `/usr/local/bin/github-backup`

## Overview

`github-backup` is designed as one small command with:
- Automatic repo discovery via `.git` directory crawl
- Support for both SSH (`git@github.com:user/repo.git`) and HTTPS (`https://github.com/user/repo.git`) remotes
- Smart skip list for excluding repos
- `--dry-run`, `--verbose`, and `--debug` modes for safety
- Logging with configurable log file
- Email notification on completion
- systemd timer support for daily automated runs
- Self-install, update, and uninstall commands (modeled after `wg-manager.sh`)
- **Profile download and list commands**

## Quick Install

```bash
# Install the script
github-backup --install

# Or manually:
# sudo cp /path/to/github-backup.sh /usr/local/bin/github-backup
# sudo chmod +x /usr/local/bin/github-backup

# Set up the systemd timer for daily runs
sudo cp /root/temp/github-backup/github-backup.service /etc/systemd/system/
sudo cp /root/temp/github-backup/github-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now github-backup.timer
```

## Quick Update

```bash
github-backup update
```

Downloads the latest version from GitHub and reinstalls it.

## Command Summary

```text
github-backup [--base-dir DIR] [--dry-run] [--verbose] [--debug]
               [--profile USER] [--list-repos USER] [--skip REPO] [--skip-list LIST] [--install] [--update] [--uninstall]
               [--help/-h]
```

### Full Option List

| Option | Description |
|---|---|
| `--base-dir DIR` | Base directory to search for Git repos (default: `/root`) |
| `--dry-run` | Report repos without pulling (safe preview mode) |
| `--verbose` | Print each repo as it's processed with OK/FAILED status |
| `--debug` | Print debug information (repo paths, remote URLs, skip decisions) |
| `--skip REPO` | Skip a specific repo name/dir |
| `--skip-list LIST` | Comma-separated list of repos to skip (e.g., `admin-themes,bobs-septics`) |
| `--profile USER` | Download all repos from GitHub user USER |
| `--list-repos USER` | List repos from GitHub user USER |
| `--install` | Install script to `/usr/local/bin/github-backup` |
| `--update` | Download latest and reinstall |
| `--uninstall` | Remove installed script from `/usr/local/bin/github-backup` |
| `--help` / `-h` | Show this help message |

### Management Commands

| Command | Description |
|---|---|
| `--install` | Install script to `/usr/local/bin/github-backup` |
| `--update` | Download latest and reinstall |
| `--uninstall` | Remove installed script from `/usr/local/bin/github-backup` |

### Profile Commands

| Command | Description |
|---|---|
| `--profile USER` | Download all repos from GitHub user USER |
| `--list-repos USER` | List repos from GitHub user USER |

### Full Options (also shown with `--help`)

| Option | Description |
|---|---|
| `--base-dir DIR` | Base directory to search (default: `/root`) |
| `--dry-run` | Report repos without pulling |
| `--verbose` | Print each repo as it's processed |
| `--debug` | Print debug information (repo paths, git urls) |
| `--skip REPO` | Skip a specific repo name/dir |
| `--skip-list LIST` | Comma-separated list of repos to skip |
| `--profile USER` | Download all repos from GitHub user USER |
| `--list-repos USER` | List repos from GitHub user USER |
| `--help` / `-h` | Show this help message |

## How It Works

1. **Discovery** — Finds all `.git` directories under the base directory using `find`
2. **Remote check** — For each repo, reads the `origin` URL from `.git/config`
3. **GitHub filter** — Only processes repos with GitHub remotes (SSH or HTTPS)
4. **Pull** — Changes to the repo directory and runs `git pull`
5. **Logging** — Writes timestamped entries to the log file
6. **Notification** — If `GITHUB_BACKUP_EMAIL` is set and repos were pulled, sends a completion email
7. **Profile mode** — If `--profile USER` is given, downloads all repos from that GitHub user

## Profile Examples

### Download all repos from a GitHub user

```bash
# Download all repos from the octocat user
github-backup --profile octocat

# Download with verbose output to see each repo being processed
github-backup --profile octocat --verbose

# Download with debug output to see repo paths and remote URLs
github-backup --profile octocat --debug
```

### List repos from a GitHub user

```bash
# List all repos from the octocat user
github-backup --list-repos octocat

# List with verbose output
github-backup --list-repos octocat --verbose
```

### Combine profile download with skip list

```bash
# Download all repos except the ones you don't want
github-backup --profile octocat --skip-list octocat/Hello-World,octocat/Goodies

# Download all repos except private ones (if you have a token)
GITHUB_BACKUP_TOKEN=ghp_xxxxx github-backup --profile octocat
```

### Quick Start Example

```bash
# Full setup:
# 1. Install the script
github-backup --install

# 2. Download all repos from a user
github-backup --profile octocat

# 3. Set up daily automatic updates
sudo systemctl enable --now github-backup.timer
```

## Requirements

- Bash (tested with Bash 5.0+)
- `git` command-line tool
- `find` command
- `mail` or `sendmail` command (for email notifications — optional)
- `systemd` (for timer support — optional, can be run as a cron job instead)

## Development

Run the setup regression tests:

```bash
python3 -m unittest discover -s tests -v
```

The tests mock package installation, service queries, and privileged directory creation; they do not require root or change the host's network configuration.

## License

This project is released under the MIT License. See `LICENSE`.

## Related

- Old FreeNAS script: `script.freenas/github-down.sh` (deprecated — required pre-built CSV, hardcoded NAS path)
- This script replaces the manual CSV-based approach with automatic directory crawling
- Inspired by: `wg-manager.sh` pattern for self-install/update/uninstall

## Reporting Issues

Found a bug or have a feature request? Open an issue on the GitHub repository:

https://github.com/peternickol/github-backup