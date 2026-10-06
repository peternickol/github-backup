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
- Profile download and list commands
- GitHub API token support for private repos and higher rate limits

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

## Quick Start

```bash
# Download all repos from a GitHub user
github-backup --profile USERNAME

# List repos from a GitHub user
github-backup --list-repos USERNAME

# Regular local directory crawl
github-backup --base-dir /path/to/repos
```

## Getting a GitHub API Token

To download private repos or increase your rate limits, you can generate a GitHub Personal Access Token:

1. Go to [GitHub Settings](https://github.com/settings/tokens)
2. Click **"Generate new token"** (or "Fine-grained personal access token")
3. Select the following scopes:
   - `repo` - Full control of private repos
   - `read:repo` - Read-only access to private repos
   - `read:user` - Read user details
4. Click **"Generate token"
5. Copy the generated token

### Using the token

Set the `GITHUB_BACKUP_TOKEN` environment variable:

```bash
export GITHUB_BACKUP_TOKEN=ghp_xxxxxxxxxxxxxxxxxx

# Or run with the token directly:
GITHUB_BACKUP_TOKEN=ghp_xxxxxxxxxxxxxxx github-backup --profile USERNAME
```

### Rate limits

- **Unauthenticated**: 60 requests/hour
- **Authenticated**: 5,000 requests/hour

With a token, you can download both public and private repos, and the script will work much faster with higher rate limits.

## Quick Start Example

```bash
# Full setup:
# 1. Install the script
github-backup --install

# 2. Download all repos from a user
github-backup --profile USERNAME

# 3. Set up daily automatic updates
sudo systemctl enable --now github-backup.timer
```

## License

This project is released under the MIT License. See `LICENSE`.

## Related

- Old FreeNAS script: `script.freenas/github-down.sh` (deprecated — required pre-built CSV, hardcoded NAS path)
- This script replaces the manual CSV-based approach with automatic directory crawling
- Inspired by: `wg-manager.sh` pattern for self-install/update/uninstall

## Reporting Issues

Found a bug or have a feature request? Open an issue on the GitHub repository:

https://github.com/peternickol/github-backup