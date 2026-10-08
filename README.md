<p align="center">
  <img src="docs/github-backup-logo.png" alt="github-backup logo: the GitHub mark beside a database with a sync arrow" width="160" height="136">
</p>

<h1 align="center">github-backup</h1>

<p align="center"><strong>Keep local GitHub working trees current.</strong></p>

`github-backup` keeps local GitHub working trees current. Point it at a
directory and it fast-forwards clean branches that are behind GitHub. A token
in the option file makes `sync` download every repository that account owns.
`--profile` in that file selects a different user or organization.

Settings live in `/etc/github-backup/github-backup.conf`. `setup` installs
that file with every option commented out. Remove the leading `# ` from a
line to turn it on. The timer and a plain `github-backup sync` both read it.
A switch on the command line replaces the same setting for that one run.
Install, update, and uninstall switches stay on the command line. See
[Option file](#option-file).

The installed command is `/usr/local/bin/github-backup`. With no arguments it
prints help and exits. A backup is `github-backup sync`.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/peternickol/github-backup/master/github-backup.sh \
  -o github-backup.sh
sudo bash github-backup.sh install
rm github-backup.sh

sudo github-backup setup
```

`install` copies the command. `setup` prepares the machine and installs
`/etc/github-backup/github-backup.conf`. Uncomment the lines you want. A
token comes from [Generate a token](#generate-a-token).

```text
--base-dir /mnt/nas/github
--token github_pat_...
```

`sync` then downloads every repository owned by that account into the base
directory. To back up a different user or organization, also uncomment
`--profile`. The timer is already `*-*-* 02:00:00`. To change that calendar,
uncomment `--schedule` and run `sudo github-backup setup --force` so the
timer stores it.

```bash
sudo github-backup enable
sudo github-backup start
```

`enable` arms the nightly timer. `start` runs a backup immediately. Both use
the option file.

## Safety

A repository is skipped, and its working tree is left untouched, when any of
these are true:

- The name is skipped in the option file, or listed in `GITHUB_BACKUP_SKIP_LIST`.
- The directory is not a Git working tree.
- A merge, rebase, cherry-pick, revert, bisect, or sequencer is in progress.
- `index.lock` is present.
- `HEAD` is detached.
- The current branch has no upstream.
- The upstream remote is not `github.com`.
- The working tree has staged, unstaged, or untracked files.
- The local branch is ahead of GitHub, or the histories have diverged.
- The checkout is nested inside another repository under the base directory,
  including submodules.

A clean branch that is behind GitHub is updated with `git merge --ff-only`.
That applies upstream additions, edits, and deletions of tracked files. Default
mode does not create merge commits, rebase, stash, reset, or delete untracked
files.

`--force-fast-forward` is the destructive override. It still refuses a detached
`HEAD`, a missing upstream, a non-GitHub remote, and a Git operation already in
progress. When it runs, it fetches the upstream, `git reset --hard` to that
commit, and `git clean -fd`. Local commits and untracked files are discarded.
Ignored files and nested Git directories stay. Preview it with `--dry-run`.

Profile mode never follows a symlink and never treats a nested directory as a
clone destination. New clones use HTTPS. Git receives the token as HTTP Basic
authentication, with the username `x-access-token`, and the token is not
written into `origin` URLs. For that one Git command, a token also
reads `git@github.com:` and `ssh://git@github.com/` as HTTPS. The remote saved
in the checkout stays as it was. `GIT_TERMINAL_PROMPT=0` stops Git from
waiting for a password.

Repositories deleted or renamed on GitHub are left on disk. Wikis, gists,
issues, releases, and Git LFS objects are not downloaded.

## Requirements

- Bash 4 or newer, Git, curl, Python 3, `find`, and `flock` (util-linux)
- systemd, when you want the timer
- an `http` or `https` form endpoint, when you want a run report

## Commands

| Command | What it does |
|---|---|
| `sync` | Update GitHub working trees under the base directory. A token also clones every repository that account owns. |
| `profile USER` | Clone missing owned repositories and update the ones already checked out. |
| `list-repos USER` | Print repository names. Nothing is cloned. |
| `setup` | Write configuration, prepare the base directory, and install systemd units. |
| `install` | Copy the command and Bash completion. |
| `update` | Replace the installed command with the published script. |
| `uninstall` | Remove the command, units, and completion. Repository data stays. |
| `enable` | Arm `github-backup.timer` now. |
| `disable` | Disarm the timer. A backup already running keeps going. |
| `start` | Run one backup now. |
| `stop` | Stop a backup that is running now. |
| `restart` | Run one backup now. |
| `is-enabled` | Report whether the timer is enabled. |
| `is-active` | Report whether the timer is active. |
| `status` | Show the timer, then the service. |
| `journal` | Follow the service journal. |
| `--version`, `-V` | Print `github-backup 1.4.10`. |
| `--help`, `-h` | Print every command, every option, and the examples. |

### `sync`

Crawl a directory and update each top-level GitHub checkout. The base
directory, token, profile, skip list, log, and the other backup options come
from the option file. A token, with no `--profile`, selects the account that
owns the token and downloads every repository that account owns. Each
repository is one directory under the base directory. `--profile` in the
option file selects that user or organization instead, which is how an
organization is downloaded.

```text
--base-dir /mnt/nas/github
--token github_pat_...
--verbose
--skip repo-one
--skip repo-two
--log-file /var/log/github-backup.log
```

```bash
github-backup sync
```

The same option on the command line replaces the file for that run:

```bash
github-backup sync --dry-run
github-backup sync --base-dir ~/src
github-backup sync --force-fast-forward --dry-run
```

With no token and no profile, the base directory must already exist. A token
makes a real `sync` create the base directory when it is missing. The default
is `$HOME/github-backup`.
The crawl does not follow directory symlinks. `git fetch --prune` drops
remote-tracking branches that GitHub has deleted. Local branches are kept.
Ignored files do not count as local work, and a normal fast-forward leaves
them in place.

`--dry-run` reads the remote-tracking branch already stored in the checkout.
It does not fetch, merge, reset, or move `HEAD`. An up-to-date repository is
omitted unless `--verbose` is set. Anything else is one line:

```text
Skipping frostonix-portal: 5 commits ahead of origin/master
dish: would fast-forward 2 commits to origin/master
```

`sync` takes `$BASE_DIR/.github-backup.lock`, including `--dry-run`. A second
run for the same directory exits `1` with `Another github-backup is already
running`. The lock is released when the process exits.

The systemd service runs `github-backup sync` and reads the option file. A
token there makes that run download the account that owns the token.
`--profile` in the file, or `GITHUB_BACKUP_PROFILE` when the file leaves the
profile commented, selects a different user or organization. The service runs
as root.

`--skip NAME` in the option file adds that name to the skip list from the
environment or the defaults file. `--skip-list A,B` replaces that list, and
any `--skip` names are still added. Either option on the command line replaces
the skip names from the file for that run. Matching is the repository
directory name, exactly.

These options belong in the option file. On the command line, each one
overrides the file for that run: `--base-dir`, `--profile`, `--skip`,
`--skip-list`, `--dry-run`, `--verbose`, `--debug`, `--quiet`,
`--notify-on-error`, `--force-fast-forward`, `--log-file`.

### `profile`

List repositories owned by a user or organization, clone the ones that are
missing, and update the ones that are already checked out. The usual way to
choose the account is `--profile` in the option file, which makes `sync` do
this work. `profile USER` names the account for one run and replaces the
file's `--profile`.

```text
--base-dir /mnt/nas/github
--profile octocat
--token github_pat_...
```

```bash
github-backup sync
github-backup profile octocat
github-backup profile my-org --dry-run
```

`--dry-run` prints the clone plan and does not create the base directory.
A real run creates it. When the directory already exists, a profile run takes
the same lock as `sync`, including `--dry-run`. One directory per repository
name is used, for example `/mnt/nas/github/octocat/Hello-World`.

The owner name must match `[A-Za-z0-9][A-Za-z0-9-]*`. A token owner's private
repositories come from `GET /user/repos?affiliation=owner&visibility=all`. An
organization comes from `GET /orgs/{org}/repos?type=all`, including private
repositories the token can see. Everyone else comes from
`GET /users/{user}/repos?type=owner`, which is the public list. Pages are
100 repositories at a time. Owned forks and archived repositories are included.
Repositories where the account is only a collaborator are not.

The same backup options as `sync` apply, from the option file, with a
command-line flag overriding that run.

### `list-repos`

Print repository names for a user or organization. Nothing is cloned. This
command stays on the command line.

```bash
github-backup list-repos octocat
github-backup list-repos octocat --verbose
github-backup list-repos my-org --verbose
```

`--verbose` adds a `public` or `private` column. The same API rules as
`profile` apply. `list-repos` does not take the lock, does not write the log,
and does not print a summary. An unknown or empty profile name exits `1`.

### `setup`

Prepare this machine. The first run creates the base directory, creates the
log file when it can, writes `/etc/default/github-backup` and
`/etc/github-backup/github-backup.conf` mode `600`, and installs the systemd
units. It does not arm the timer. The option file lists each option
commented out, with a short note. The top of the file links to the
repository. Day to
day, uncomment lines there. Install options stay on the command line.

```text
--base-dir /mnt/nas/github
--profile YOUR_GITHUB_USERNAME
--log-file /var/log/github-backup.log
--schedule *-*-* 02:00:00
```

```bash
sudo github-backup setup
sudo github-backup setup --force
sudo github-backup setup --no-systemd
```

A flag on that command replaces the same line from the file for this setup.
`sudo github-backup setup --force --schedule 'Mon *-*-* 03:00:00'` stores that
calendar in the timer and leaves the option file's `--schedule` line as it was.

A second `setup` keeps an existing defaults file, an existing option file, and
existing unit files. It still creates a missing base directory or log file from
the paths in effect for this run, but it does not save them unless you pass
`--force`. Pass `--force` to replace the units and rewrite the defaults file.
Uncommented lines in the option file supply the values. A flag on this
command replaces the same value for this run. `--force` refreshes the
comments in the option file and keeps every uncommented line, including
`--token` and `--schedule`. The schedule is stored in the timer. When
`--schedule` is commented, this command does not pass `--schedule`, and
`GITHUB_BACKUP_SCHEDULE` is unset, the timer goes back to `*-*-* 02:00:00`. An uncommented `GITHUB_BACKUP_TOKEN=` line in
the defaults file is copied into the new defaults file. `setup` does not copy
a token out of the environment or out of the option file into the defaults
file. The notify URL, base directory, profile, log path, and skip list are
rewritten from the option file when those lines are uncommented, and otherwise
from the environment, then the current defaults file.

`--no-systemd` writes the configuration and base directory and skips the units,
including when `--force` is also set. An existing timer is left unchanged.
Use that with cron. The schedule must be a single line.

These options belong in the option file: `--base-dir`, `--profile`,
`--schedule`, `--log-file`, `--skip-list`. `--no-systemd` and `--force` stay
on the `setup` command. `--force` in the option file would rewrite the units
on every `setup`. Leave that line commented.

### `install`

Copy this script to `/usr/local/bin/github-backup` as `root:root` mode `755`,
then install Bash completion mode `644`. Configuration and systemd units are
not written. The default path needs root. `GITHUB_BACKUP_INSTALL_PATH` can
point at a user-writable path, and that install stays mode `755` without
changing the owner.

```bash
sudo bash github-backup.sh install
sudo github-backup install
sudo github-backup install --force
sudo github-backup install --no-completion
sudo github-backup install --completion-only
sudo github-backup install --uninstall-completion
sudo github-backup --install --force
```

`--force` overwrites the binary and the completion file. It does not delete
repositories, configuration, or units. Completion is installed under
`/usr/share/bash-completion/completions` when that directory exists, otherwise
`/etc/bash_completion.d`. If the completion file already exists, install stops
until you pass `--force`.

### `update`

Download the published script, reject an empty file, check it with `bash -n`,
and install it over `/usr/local/bin/github-backup`. Bash completion is
refreshed. Configuration, units, and repository data stay as they are.

```bash
sudo github-backup update
sudo github-backup update --no-completion
sudo github-backup --update
```

The download URL is
`https://raw.githubusercontent.com/peternickol/github-backup/master/github-backup.sh`.
`curl` is used when it is installed, otherwise `wget`. Completion is refreshed
even when that file already exists. Pass `--no-completion` to leave it alone.
An empty download or a script that fails `bash -n` is rejected and the
installed command stays as it was.

### `uninstall`

Disable the timer, remove both unit files, remove the command, and remove Bash
completion. Cloned repositories are never deleted. The configuration file stays
unless you pass `--purge-config`.

```bash
sudo github-backup uninstall
sudo github-backup uninstall --purge-config
sudo github-backup --uninstall
```

If the command is already absent, uninstall reports that and still removes
units and completion. The base directory, cloned repositories, and the log
file stay either way. `--purge-config` removes `/etc/default/github-backup`
and `/etc/github-backup/github-backup.conf`.

### `enable`

Reload systemd and run `systemctl enable --now github-backup.timer`. The
schedule is armed immediately. It does not wait for the next reboot.

```bash
sudo github-backup enable
```

Run `setup` first. Enable fails when the unit files are missing. Because the
timer is `Persistent=true`, enabling it can start a backup that the calendar
already missed. `RandomizedDelaySec=30m` can then delay that run by up to 30
minutes. `--quiet` hides the systemctl transcript. The `[OK]` line is hidden
too.

### `disable`

Run `systemctl disable --now github-backup.timer`. Later calendar runs stop.
A backup that is already executing is not stopped; use `stop` for that.

```bash
sudo github-backup disable
sudo github-backup disable --quiet
```

`--quiet` hides the systemctl transcript.

### `start`

Run `systemctl start github-backup.service`. That executes one backup now.

```bash
sudo github-backup start
sudo github-backup start --quiet
```

The service executes `/usr/local/bin/github-backup sync` as root and reads
the option file, then `/etc/default/github-backup` for anything that file
leaves commented. `--quiet` here hides systemctl's transcript. It is not
passed through to that backup.

### `stop`

Run `systemctl stop github-backup.service`.

```bash
sudo github-backup stop
sudo github-backup stop --quiet
```

### `restart`

Run `systemctl restart github-backup.service`. That starts a backup now.

```bash
sudo github-backup restart
sudo github-backup restart --quiet
```

### `is-enabled`

Print `enabled` or `disabled` for `github-backup.timer`. The exit status is
`0` when the timer is enabled and `1` when it is disabled. `--quiet` prints
nothing and keeps that exit status, which is the form to use from a script.

```bash
sudo github-backup is-enabled
sudo github-backup is-enabled --quiet
if sudo github-backup is-enabled --quiet; then
  echo "timer is enabled"
fi
```

### `is-active`

Print `active` or `inactive` for `github-backup.timer`. This is the schedule,
not the oneshot service. The service is active only while a backup is running.
The exit status is `0` when the timer is active and `1` when it is inactive.

```bash
sudo github-backup is-active
sudo github-backup is-active --quiet
if sudo github-backup is-active --quiet; then
  echo "timer is active"
fi
```

`--quiet` prints nothing and keeps the exit status.

### `status`

Show `systemctl status` for the timer and then the service. The command's exit
status is the timer status.

```bash
sudo github-backup status
sudo github-backup status --quiet
```

`--quiet` hides both status transcripts. The exit status is still the timer's
status.

### `journal`

Follow the service log with `journalctl -u github-backup.service -f`.

```bash
sudo github-backup journal
```

`--quiet` does not change `journal`. The follow runs until you interrupt it.

### Version and help

```bash
github-backup --version
github-backup -V
github-backup --help
github-backup -h
```

`--version` prints `github-backup 1.4.10`. Running `github-backup` with no
arguments prints the same text as `--help` and exits `0`. An unknown argument,
or an option with no value, prints the error and then the same help, and
exits `1`.

## Options

Backup and setup options normally live in
`/etc/github-backup/github-backup.conf`. See [Option file](#option-file).
The table is the full list. A command-line flag replaces the same option
from the file for that one run. Install, update, and uninstall options are
command-line only.

| Option | Use it with | What it does |
|---|---|---|
| `--base-dir DIR` | `sync`, `profile`, `setup` | Directory to crawl, or the directory that receives profile clones. Put it in the option file. Default: `$HOME/github-backup`. |
| `--profile USER` | `sync`, `setup` | On `sync`, clone and update `USER` instead of the account that owns the token. On `setup`, store that profile. Put it in the option file. |
| `--list-repos USER` | anywhere | Switch this run to `list-repos`. |
| `--skip REPO` | `sync`, `profile` | Skip one repository directory name. Repeat the line to skip more than one. Names are added to the list from the environment or the defaults file. Matching is exact. On the command line, this replaces the skip names from the option file for that run. |
| `--skip-list A,B,C` | `sync`, `profile`, `setup` | Skip a comma-separated list. Spaces around names are removed. This replaces the list from the environment or the defaults file. On the command line, it replaces the skip names from the option file for that run. On `setup --force`, it also replaces the saved list. |
| `--dry-run` | `sync`, `profile` | Print what would change using the remote-tracking branch already on disk. Do not fetch, merge, clone, reset, or move `HEAD`. Up-to-date repositories are omitted unless `--verbose` is set. A directory sync requires the base directory and takes the lock. A profile dry run does not create the base directory. Leave it commented in the option file. Pass it on the command line to preview one run. |
| `--verbose` | `sync`, `profile`, `list-repos` | Also print repositories that are already current. Updates, clones, skips, and failures print either way. For `list-repos`, add `public` or `private`. |
| `--debug` | `sync`, `profile` | Print `Fetching REMOTE for REPO` on stderr. This still prints when `--quiet` is set. |
| `--quiet`, `-q` | any command | Hide `[INFO]`, `[OK]`, and `[WARN]`, including skip lines and the summary. Errors still print. The log file is still written. One warning still prints if the log cannot be written. See [Messages](#messages). |
| `--notify-url URL` | `sync`, `profile` | Formester endpoint for the run report. Put it in the option file. A command-line value replaces it for that run. |
| `--notify-on-error` | `sync`, `profile` | Submit the form report only when a repository fails or the run stops early. The default submits after every real `sync` or `profile`. Skips alone stay a success. A dry run does not submit. Put it in the option file to keep that limit for the timer. |
| `--force-fast-forward` | `sync`, `profile` | Reset eligible checkouts to the upstream commit and delete untracked files. Leave it commented in the option file. |
| `--log-file FILE` | `sync`, `profile`, `setup` | Log path. Put it in the option file. On `setup --force`, also the path saved in the defaults file. Default: `/var/log/github-backup.log`. |
| `--token TOKEN` | any command | GitHub token. With no `--profile`, `sync` downloads every repository that account owns. Put it in the option file so later runs do not need it again. A command-line value replaces it for that run and stays in shell history. |
| `--config FILE` | any command | Use `FILE` instead of `/etc/github-backup/github-backup.conf`. One option per line, including `--token`. On `setup`, the service runs `sync --config FILE` only when `FILE` is not that standard path. |
| `--schedule CALENDAR` | `setup` | systemd `OnCalendar` value, stored in the timer when `setup` writes the units. Put it in the option file, then run `setup --force`. Default: `*-*-* 02:00:00`. |
| `--no-systemd` | `setup` | Write the configuration and skip unit installation. |
| `--force`, `-f` | `install`, `setup` | Overwrite an existing binary, completion file, or unit. On `setup`, also rewrite the configuration. |
| `--no-completion` | `install`, `update` | Do not install or refresh Bash completion. |
| `--completion-only` | `install` | Install Bash completion and exit. |
| `--uninstall-completion` | `install` | Remove Bash completion and exit. |
| `--purge-config` | `uninstall` | Also remove `/etc/default/github-backup` and `/etc/github-backup/github-backup.conf`. |
| `-V`, `--version` | anywhere | Print the version and exit. |
| `-h`, `--help` | anywhere | Print the command summary and exit. |

A flag may appear before or after the command name. It replaces the same
option from the file for that run:

```bash
github-backup sync
github-backup sync --dry-run
github-backup --dry-run sync
github-backup sync --config /root/github-backup.conf
```

`--profile` and `--list-repos` are also accepted as the old option form, without
a separate command word. `--install`, `--update`, and `--uninstall` are the old
forms of those three commands. `--config` inside the option file is rejected.

### Option file

`setup` installs `/etc/github-backup/github-backup.conf`. The command reads
that file on every run, including the timer. You do not pass `--config` for
the installed file. `--config FILE` uses a different file instead, the same
way `sshd -f` selects another `sshd_config`. The command (`sync`, `profile`,
`setup`, and the rest) stays on the command line. `--config` inside the file
is rejected.

The installed file lists each option commented out, with a short note. The
top of the file links to the repository. Commands stay
on the command line, including `list-repos`, `--version`, `--help`, and
`--config`. Install options (`--no-completion`, `--completion-only`,
`--uninstall-completion`, and `--install`) stay there too.
`github-backup.conf.example` is the same text. Remove the leading `# ` from a
line to set that option:

```text
# --token github_pat_...
--token github_pat_your_token_here

# --base-dir /mnt/nas/github
--base-dir /mnt/nas/github
```

One option per line. A blank line is ignored. A line that starts with `#` is a
comment. Wrap a value in quotes when it contains spaces:
`--base-dir "/mnt/nas/my mirrors"`. `--base-dir=/mnt/nas/github` is the same as
`--base-dir /mnt/nas/github`. A flag in the file, such as `--quiet` or
`--dry-run`, is on for every run that reads the file. Leave the line
commented to keep it off. There is no `--no-dry-run`. Leave
`--force-fast-forward` commented.

The file is read first. A command-line flag replaces the same setting from
the file. `--base-dir /tmp/src` on the command line replaces the file's
`--base-dir`. `--skip` or `--skip-list` on the command line replaces the
skip names from the file. A flag the command line does not mention stays as
the file set it. A setting neither one mentions comes from the environment,
then `/etc/default/github-backup`, then the built-in value. When the option
file is missing, the command still runs with those later sources.

`--token` in the file is the saved GitHub token. With no `--profile`, `sync`
downloads every repository that account owns. The run uses it without
asking again. Keep the file mode `600`, and do not commit it after the token
is filled in. `--token` on the command line replaces the file's token, and
the shell keeps that command in its history. `setup` does not copy `--token`
into the defaults file. `--notify-url` in the same file is the Formester
endpoint. See [Run report](#run-report). The token is not a field in the
run report.

The service runs `sync`. That reads `/etc/github-backup/github-backup.conf`
when the file is there, so the unit does not pass `--config`.
`setup --config FILE` points the service at a different file, and the unit
then runs `sync --config FILE`. Pass `--config FILE` again whenever
`setup --force` rewrites the units. Otherwise the service returns to the
standard option file. `setup --force` refreshes the comments in the installed
option file and keeps uncommented lines. `--schedule` does not need to be
repeated: an uncommented line in the option file is enough.

## Configuration

`setup` writes `/etc/default/github-backup`. The service loads it with
systemd `EnvironmentFile=`. The command also reads it directly, so a root cron
job and a manual root run see the same settings. This file is the fallback.
The option file replaces these variables, and a command-line flag replaces
both for that run.

A variable set in the environment wins over this defaults file, and an empty
value counts as set. `GITHUB_BACKUP_TOKEN` wins over `GH_TOKEN` when it is
set, including when it is set to an empty string. Prefer `--token` in the
option file. The shell example below is for one run that should leave the
token out of shell history.

```text
GITHUB_BACKUP_BASE_DIR=/mnt/nas/github/YOUR_GITHUB_USERNAME
GITHUB_BACKUP_PROFILE=YOUR_GITHUB_USERNAME
GITHUB_BACKUP_LOG_FILE=/var/log/github-backup.log
GITHUB_BACKUP_NOTIFY_URL=https://formester.com/f/yourFormId
GITHUB_BACKUP_TOKEN=github_pat_REPLACE_ME
GITHUB_BACKUP_SKIP_LIST=repo-one,repo-two
```

| Key | Meaning |
|---|---|
| `GITHUB_BACKUP_BASE_DIR` | Crawl root and profile clone destination. |
| `GITHUB_BACKUP_PROFILE` | User or organization to discover. When this is set, `sync` uses it instead of the account that owns the token. |
| `GITHUB_BACKUP_LOG_FILE` | Log file. Each line is `YYYY-MM-DD HH:MM:SS [LEVEL] message`. |
| `GITHUB_BACKUP_NOTIFY_URL` | Form endpoint used when `--notify-url` is not set. Prefer `--notify-url` in the option file. |
| `GITHUB_BACKUP_TOKEN` | GitHub token. Prefer `--token` in the option file. This line stays commented. |
| `GITHUB_BACKUP_SKIP_LIST` | Comma-separated repository names to skip. |

Quote a value that contains spaces. systemd and this command both accept that form:

```text
GITHUB_BACKUP_BASE_DIR="/mnt/nas/my mirrors"
```

Empty values are written as `KEY=`. Lines starting with `#` are comments.
`setup` creates the file mode `600`. Keep it owned by root.

`GH_TOKEN` is used when `GITHUB_BACKUP_TOKEN` is unset. Do not put either token
in shell history or in Git.

```bash
read -rsp 'GitHub token: ' GITHUB_BACKUP_TOKEN
printf '\n'
export GITHUB_BACKUP_TOKEN
github-backup sync
unset GITHUB_BACKUP_TOKEN
```

### Generate a token

Public repositories need no token. A token lets `sync` see private
repositories and download every repository that account owns. GitHub shows
the value once. Copy it, then store it in the option file:

```text
--token github_pat_...
```

Remove the leading `# ` from that line in
`/etc/github-backup/github-backup.conf`. The file is mode `600`. `setup` does
not copy the token into `/etc/default/github-backup`. When the token expires,
generate a new one and replace that line.

**Fine-grained token.** Use this one. Open
[Fine-grained tokens](https://github.com/settings/personal-access-tokens/new),
or go to your avatar, **Settings**, **Developer settings**, **Personal access
tokens**, **Fine-grained tokens**, **Generate new token**.

1. Token name: `github-backup`.
2. Resource owner: your user account. To back up an organization, choose that
   organization. The token can stay pending until an organization owner
   approves it.
3. Expiration: choose a date.
4. Repository access: **All repositories**. That is the set `sync` downloads.
   **Only select repositories** limits the backup to the repositories you pick.
5. Repository permissions: **Contents** set to **Read-only**. Leave the other
   repository permissions at **No access**. GitHub adds **Metadata: Read-only**
   on its own, and that permission is what lists the repositories.
6. Account permissions: leave them at **No access**.
7. Click **Generate token** and copy the value. It starts with `github_pat_`.

**Classic token.** Use this when a fine-grained token cannot see the
repositories. Open
[Tokens (classic)](https://github.com/settings/tokens/new),
or go to **Developer settings**, **Personal access tokens**, **Tokens
(classic)**, **Generate new token (classic)**.

1. Note: `github-backup`.
2. Expiration: choose a date.
3. Scope: **repo**. That reads the private and public repositories the account
   can access. A public-only backup can use **public_repo** instead.
4. Click **Generate token** and copy the value. It starts with `ghp_`.
5. If the organization uses SAML single sign-on, open the token and click
   **Configure SSO**, then authorize that organization. Until you do, the
   organization's repositories stay out of the list.

`sync` then downloads every repository that account owns. Unauthenticated API
use is about 60 requests per hour. Authenticated use is about 5,000 per hour.

### Run report

Uncomment `--notify-url` in the option file and paste a form you control.
That form POST is the only notification. After every real `sync` or
`profile`, including a run that stops early, the command submits one report.
`--notify-on-error` in the option file submits only when a repository fails
or the run stops early. A command-line `--notify-on-error` does the same for
that run. Skips alone stay a success and do not submit when that option is
set. `list-repos`, `setup`, `install`, and a dry run do not submit. The full
history stays in the log file. The `log` field names every repository from
the run and what happened to it:
up to date, fast-forwarded, cloned, skipped, or failed. Under a
fast-forward, the log includes the diffstat `git pull` prints: each changed
file and how many lines changed, such as `src/app.py | 12 ++--` and
`1 file changed, 4 insertions(+), 8 deletions(-)`. The same stat is printed
on the console. `--quiet` hides it there and still sends it in the report.

The URL is the secret. The option file is mode `600`.
`GITHUB_BACKUP_NOTIFY_URL` is used when `--notify-url` is left commented.
The GitHub token is not a form field. A POST that fails, or a URL
that is not a single `http` or `https` address, prints a warning and leaves
the backup's exit status unchanged. `--quiet` hides that warning on the
console. The log file still records it, and the POST is still attempted.

The body is `application/x-www-form-urlencoded`. The request sends
`Accept: application/json`. Paste the endpoint Formester gives you, such as
`https://formester.com/f/yourFormId`. Create the form fields with these names
so each value shows up in the submission. Turn off reCAPTCHA and any other
challenge on that form. A server cannot solve one.

| Field | Value |
|---|---|
| `_subject` | One-line subject, stored as a field of that name. |
| `host` | Short hostname. |
| `program` | `github-backup`. |
| `status` | `ok` or `failed`. Skips alone stay `ok`. |
| `summary` | `Summary: N updated, N cloned, N unchanged, N skipped, N failed`. |
| `log` | One line per repository and what happened to it. A fast-forward is followed by git's diffstat: the files and how many lines changed. Also lines from a run that stops early. At most 2000 lines and 256 KB. |

```text
--notify-url https://formester.com/f/yourFormId
```

`setup --force` writes `GITHUB_BACKUP_NOTIFY_URL` into
`/etc/default/github-backup` when a notify URL is in effect for that run.
At backup time the option file still replaces the defaults file.

This is the report shape for the other commands on these machines. Copy the
same field names. Change `program`, and name the variable for that command,
such as `WG_MANAGER_NOTIFY_URL`. Point them at one form or at one form each.

Formester stores the submission and sends whatever notification you configure
on that form. A night with no submission can also mean the timer did not run.
The form only hears from a run that started.

### Schedule

The timer's `OnCalendar` is the interval. The default is every day at 02:00.
To change it, uncomment `--schedule` in the option file and run
`setup --force`. The timer stores that calendar. It also waits a random time
up to 30 minutes after the mark (`RandomizedDelaySec=30m`) and catches up
after downtime (`Persistent=true`).

```text
--schedule *-*-* 02:00:00
--schedule daily
--schedule *-*-* 03:30:00
```

```bash
sudo github-backup setup --force
sudo github-backup enable
```

`--schedule` on the `setup` command replaces the option-file line for that
run. `GITHUB_BACKUP_SCHEDULE` supplies the calendar when the option file
leaves `--schedule` commented and the command does not pass it. It is not
stored in `/etc/default/github-backup`. A schedule that contains a newline
is rejected.

Cron, after `setup --no-systemd`:

```cron
0 2 * * * /usr/local/bin/github-backup sync
```

Run that as root so it can read the mode `600` configuration file.

### Other environment variables

| Variable | Default | What it changes |
|---|---|---|
| `GITHUB_BACKUP_BASE_DIR` | `$HOME/github-backup` | Base directory. |
| `GITHUB_BACKUP_PROFILE` | empty | User or organization `sync` uses instead of the account that owns the token. |
| `GITHUB_BACKUP_LOG_FILE` | `/var/log/github-backup.log` | Log path. |
| `GITHUB_BACKUP_NOTIFY_URL` | empty | Form endpoint used when `--notify-url` is not set. |
| `GITHUB_BACKUP_TOKEN` | empty | GitHub token. When no profile is set, `sync` downloads the account that owns it. |
| `GH_TOKEN` | empty | Token used when `GITHUB_BACKUP_TOKEN` is unset. |
| `GITHUB_BACKUP_SKIP_LIST` | empty | Comma-separated names to skip. |
| `GITHUB_BACKUP_SCHEDULE` | `*-*-* 02:00:00` | Calendar used by `setup`. |
| `GITHUB_BACKUP_INSTALL_PATH` | `/usr/local/bin/github-backup` | Where `install` and `update` write the command. |
| `GITHUB_BACKUP_UPDATE_URL` | the `master` script URL above | Where `update` downloads the script. |
| `GITHUB_BACKUP_DEFAULTS_FILE` | `/etc/default/github-backup` | Defaults file path. |
| `GITHUB_BACKUP_CONFIG` | `/etc/github-backup/github-backup.conf` | Option file `setup` installs and the command reads when `--config` is omitted. |
| `GITHUB_BACKUP_SYSTEMD_DIR` | `/etc/systemd/system` | Where `setup` writes the units. |
| `GITHUB_BACKUP_COMPLETION_DIR` | the detected completion directory | Where completion is installed. |
| `GITHUB_BACKUP_API_URL` | `https://api.github.com` | GitHub API root. |
| `GITHUB_BACKUP_SYSTEMCTL` | `systemctl` | systemctl binary. |
| `NO_COLOR` | unset | Any non-empty value turns message color off. Color is also off when stdout is not a terminal. |

Commands that write under `/etc`, `/usr/local`, `/var/log`, or `/run` exit `2`
when they are not run as root. `sync`, `profile`, and `list-repos` do not need
root when their directories are writable by you.

## Files

| Path | Purpose |
|---|---|
| `/usr/local/bin/github-backup` | The command. |
| `/etc/default/github-backup` | Base directory, profile, log, notify URL, and skip list. Mode `600`. |
| `/etc/github-backup/github-backup.conf` | Each option commented out, with a short note. The top of the file links to the repository. Uncomment a line to set it. `--token` and `--notify-url` live here. Install options are not in this file. Mode `600`. |
| `/etc/systemd/system/github-backup.service` | Oneshot service. `ExecStart` is `github-backup sync`. It reads `/etc/github-backup/github-backup.conf` when that file exists. `setup --config FILE` uses `github-backup sync --config FILE` when `FILE` is a different path. It runs as root. |
| `/etc/systemd/system/github-backup.timer` | Calendar timer for that service. |
| `/var/log/github-backup.log` | Default log. `setup` creates it mode `640` when run as root. |
| `$BASE_DIR/.github-backup.lock` | Lock for that base directory. A second run exits `1`. |
| Bash completion file | Command and option completion for `github-backup`. Mode `644`. |

`setup` writes these units. `ExecStart` uses the install path from the moment
of setup, which is `/usr/local/bin/github-backup` unless
`GITHUB_BACKUP_INSTALL_PATH` says otherwise. The line is
`github-backup sync`. The command reads
`/etc/github-backup/github-backup.conf` when that file exists. The line is
`github-backup sync --config FILE` when setup was given a different file.

```ini
[Unit]
Description=Fast-forward local GitHub checkouts
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/github-backup
ExecStart=/usr/local/bin/github-backup sync
NoNewPrivileges=true
PrivateTmp=true
```

```ini
[Unit]
Description=Nightly GitHub repository backup

[Timer]
Unit=github-backup.service
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
```

The leading `-` on `EnvironmentFile` means a missing configuration file does
not stop the service. There is no `User=` line, so scheduled clones are owned
by root. Put the base directory where root can write.

## Messages

| Prefix | Stream | Hidden by `--quiet` |
|---|---|---|
| `[INFO]` | stdout | yes |
| `[OK]` | stdout | yes |
| `[WARN]` | stderr | yes, except one warning when the log file cannot be written |
| `[ERROR]` | stderr | no |
| `[DEBUG]` | stderr | no |

Color is cyan, green, yellow, and red for those four prefixes when stdout is
a terminal and `NO_COLOR` is unset. `[DEBUG]` is plain text. Each log line is
`YYYY-MM-DD HH:MM:SS [LEVEL] message`. Skip lines are warnings, so `--quiet`
hides them on the terminal and still appends them to the log.

## Exit status

`sync` and `profile` print:

```text
Summary: N updated, N cloned, N unchanged, N skipped, N failed
```

| Status | Meaning |
|---|---|
| `0` | The run finished. Skips are allowed. `is-enabled` means the timer is enabled. `is-active` means the timer is active. `--help` and `--version` also exit `0`. |
| `1` | A fetch, clone, fast-forward, or API request failed; the base directory is missing; the lock is already held; `flock` is missing; a profile name or other argument is not valid; a download or unit command failed; or `is-enabled` / `is-active` got the negative answer. |
| `2` | A command needed to write under `/etc`, `/usr/local`, `/var/log`, or `/run` and was not root. |

One failed repository does not stop the rest of the run. The summary is printed,
and the process then exits `1`.

## Development

```bash
python3 -m unittest discover -s tests -v
bash -n github-backup.sh
shellcheck github-backup.sh
```

The tests build temporary repositories and a fake GitHub API. They do not
modify a real checkout and they do not contact GitHub.

## License

Released under the MIT License. See `LICENSE`.
