import contextlib
import http.server
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import threading
import unittest
import urllib.parse


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "github-backup.sh"


def run(*args, cwd=None, env=None, check=True):
    merged_env = os.environ.copy()
    merged_env.pop("GITHUB_BACKUP_NOTIFY_URL", None)
    merged_env.pop("GITHUB_BACKUP_TOKEN", None)
    merged_env.pop("GH_TOKEN", None)
    merged_env["GITHUB_BACKUP_CONFIG"] = "/tmp/github-backup-test-no-option-file.conf"
    merged_env.update(
        {
            "GIT_AUTHOR_NAME": "github-backup tests",
            "GIT_AUTHOR_EMAIL": "tests@example.invalid",
            "GIT_COMMITTER_NAME": "github-backup tests",
            "GIT_COMMITTER_EMAIL": "tests@example.invalid",
        }
    )
    if env:
        merged_env.update(env)
    return subprocess.run(
        [str(arg) for arg in args],
        cwd=cwd,
        env=merged_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=check,
    )


class GitFixture:
    def __init__(self, root: pathlib.Path):
        self.root = root
        self.remote = root / "remote.git"
        self.publisher = root / "publisher"
        self.client = root / "repos" / "sample"
        self.github_url = "https://github.com/example/sample.git"

        run("git", "init", "--bare", self.remote)
        run("git", "clone", self.remote, self.publisher)
        (self.publisher / "tracked.txt").write_text("initial\n")
        run("git", "add", "tracked.txt", cwd=self.publisher)
        run("git", "commit", "-m", "initial", cwd=self.publisher)
        run("git", "push", "-u", "origin", "HEAD", cwd=self.publisher)

        self.client.parent.mkdir(parents=True)
        run("git", "clone", self.remote, self.client)
        run("git", "remote", "set-url", "origin", self.github_url, cwd=self.client)
        run(
            "git",
            "config",
            f"url.file://{self.remote}.insteadOf",
            self.github_url,
            cwd=self.client,
        )

    def publish(self, text: str):
        (self.publisher / "tracked.txt").write_text(text)
        run("git", "add", "tracked.txt", cwd=self.publisher)
        run("git", "commit", "-m", text.strip(), cwd=self.publisher)
        run("git", "push", cwd=self.publisher)

    def remote_head(self):
        return run("git", "rev-parse", "HEAD", cwd=self.publisher).stdout.strip()

    def client_head(self):
        return run("git", "rev-parse", "HEAD", cwd=self.client).stdout.strip()


def use_profile_checkout(fixture):
    dest = fixture.client.parent / "private-one"
    fixture.client.rename(dest)
    fixture.client = dest
    url = "https://github.com/alice/private-one.git"
    run("git", "remote", "set-url", "origin", url, cwd=dest)
    run(
        "git",
        "config",
        f"url.file://{fixture.remote}.insteadOf",
        url,
        cwd=dest,
    )
    return dest


class GitHubBackupSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.fixture = GitFixture(self.root)
        self.log = self.root / "backup.log"

    def tearDown(self):
        self.temp.cleanup()

    def backup(self, *extra, check=True, env=None):
        return run(
            SCRIPT,
            "sync",
            "--base-dir",
            self.fixture.client.parent,
            "--log-file",
            self.log,
            *extra,
            check=check,
            env=env,
        )

    def test_dirty_repository_is_skipped_without_modifying_work(self):
        original_head = self.fixture.client_head()
        (self.fixture.client / "tracked.txt").write_text("local work\n")
        (self.fixture.client / "untracked.txt").write_text("untracked work\n")
        self.fixture.publish("remote update\n")

        result = self.backup("--verbose")

        self.assertIn("working tree contains staged, unstaged, or untracked work", result.stdout)
        self.assertEqual(original_head, self.fixture.client_head())
        self.assertEqual("local work\n", (self.fixture.client / "tracked.txt").read_text())
        self.assertTrue((self.fixture.client / "untracked.txt").exists())

    def test_staged_only_repository_is_skipped(self):
        original_head = self.fixture.client_head()
        (self.fixture.client / "tracked.txt").write_text("staged work\n")
        run("git", "add", "tracked.txt", cwd=self.fixture.client)
        original_status = run("git", "status", "--porcelain", cwd=self.fixture.client).stdout
        self.fixture.publish("remote update\n")

        result = self.backup()

        self.assertIn("working tree contains staged, unstaged, or untracked work", result.stdout)
        self.assertEqual(original_head, self.fixture.client_head())
        self.assertEqual(original_status, run("git", "status", "--porcelain", cwd=self.fixture.client).stdout)

    def test_untracked_only_repository_is_skipped(self):
        original_head = self.fixture.client_head()
        untracked = self.fixture.client / "untracked.txt"
        untracked.write_text("untracked work\n")
        self.fixture.publish("remote update\n")

        result = self.backup()

        self.assertIn("working tree contains staged, unstaged, or untracked work", result.stdout)
        self.assertEqual(original_head, self.fixture.client_head())
        self.assertEqual("untracked work\n", untracked.read_text())

    def test_active_git_operation_is_skipped_even_with_force(self):
        original_head = self.fixture.client_head()
        git_dir = pathlib.Path(
            run("git", "rev-parse", "--absolute-git-dir", cwd=self.fixture.client).stdout.strip()
        )
        (git_dir / "MERGE_HEAD").write_text(self.fixture.remote_head() + "\n")
        (self.fixture.client / "tracked.txt").write_text("merge resolution work\n")

        result = self.backup("--force-fast-forward")

        self.assertIn("a merge, rebase, cherry-pick, revert, or bisect is in progress", result.stdout)
        self.assertEqual(original_head, self.fixture.client_head())
        self.assertEqual("merge resolution work\n", (self.fixture.client / "tracked.txt").read_text())
        self.assertTrue((git_dir / "MERGE_HEAD").exists())

    def test_sequencer_state_is_skipped_even_with_force(self):
        original_head = self.fixture.client_head()
        git_dir = pathlib.Path(
            run("git", "rev-parse", "--absolute-git-dir", cwd=self.fixture.client).stdout.strip()
        )
        (git_dir / "sequencer").mkdir()
        (self.fixture.client / "tracked.txt").write_text("sequencer work\n")

        result = self.backup("--force-fast-forward")

        self.assertIn("a merge, rebase, cherry-pick, revert, or bisect is in progress", result.stdout)
        self.assertEqual(original_head, self.fixture.client_head())
        self.assertEqual("sequencer work\n", (self.fixture.client / "tracked.txt").read_text())
        self.assertTrue((git_dir / "sequencer").exists())

    def test_clean_behind_repository_fast_forwards(self):
        self.fixture.publish("remote update\n")

        result = self.backup("--verbose")

        self.assertIn("fast-forwarded", result.stdout)
        self.assertRegex(result.stdout, r"tracked\.txt\s+\|")
        self.assertIn("1 file changed, 1 insertion(+), 1 deletion(-)", result.stdout)
        self.assertEqual(self.fixture.remote_head(), self.fixture.client_head())
        self.assertEqual("remote update\n", (self.fixture.client / "tracked.txt").read_text())

    def test_local_ahead_repository_is_skipped(self):
        (self.fixture.client / "local.txt").write_text("local commit\n")
        run("git", "add", "local.txt", cwd=self.fixture.client)
        run("git", "commit", "-m", "local only", cwd=self.fixture.client)
        local_head = self.fixture.client_head()

        result = self.backup("--verbose")

        self.assertIn("1 commit ahead of origin/", result.stdout)
        self.assertEqual(local_head, self.fixture.client_head())

    def test_force_fast_forward_aligns_to_remote_and_discards_local_work(self):
        (self.fixture.client / "local.txt").write_text("local commit\n")
        run("git", "add", "local.txt", cwd=self.fixture.client)
        run("git", "commit", "-m", "local only", cwd=self.fixture.client)
        (self.fixture.client / "tracked.txt").write_text("dirty local change\n")
        (self.fixture.client / "untracked.txt").write_text("untracked work\n")
        self.fixture.publish("remote update\n")

        result = self.backup("--force-fast-forward", "--verbose")

        self.assertIn("local changes and local-only commits will be discarded", result.stdout)
        self.assertEqual(self.fixture.remote_head(), self.fixture.client_head())
        self.assertEqual("remote update\n", (self.fixture.client / "tracked.txt").read_text())
        self.assertFalse((self.fixture.client / "local.txt").exists())
        self.assertFalse((self.fixture.client / "untracked.txt").exists())

    def test_dry_run_does_not_fetch_or_change_head(self):
        original_head = self.fixture.client_head()
        original_remote_tracking = run(
            "git", "rev-parse", "origin/master", cwd=self.fixture.client
        ).stdout.strip()
        self.fixture.publish("remote update\n")

        result = self.backup("--dry-run", "--verbose")

        self.assertIn("up to date", result.stdout)
        self.assertNotIn("would fast-forward", result.stdout)
        self.assertNotIn("only if clean and behind", result.stdout)
        self.assertEqual(original_head, self.fixture.client_head())
        current_remote_tracking = run(
            "git", "rev-parse", "origin/master", cwd=self.fixture.client
        ).stdout.strip()
        self.assertEqual(original_remote_tracking, current_remote_tracking)


    def test_dry_run_reports_a_recorded_fast_forward(self):
        original_head = self.fixture.client_head()
        self.fixture.publish("remote update\n")
        run("git", "fetch", cwd=self.fixture.client)
        tracking = run("git", "rev-parse", "origin/master", cwd=self.fixture.client).stdout.strip()

        result = self.backup("--dry-run")

        self.assertIn("would fast-forward 1 commit to origin/master", result.stdout)
        self.assertRegex(result.stdout, r"tracked\.txt\s+\|")
        self.assertIn("1 file changed, 1 insertion(+), 1 deletion(-)", result.stdout)
        self.assertNotIn("only if clean and behind", result.stdout)
        self.assertEqual(original_head, self.fixture.client_head())
        self.assertEqual(
            tracking,
            run("git", "rev-parse", "origin/master", cwd=self.fixture.client).stdout.strip(),
        )

    def test_force_fast_forward_dry_run_preserves_everything(self):
        original_head = self.fixture.client_head()
        tracked = self.fixture.client / "tracked.txt"
        untracked = self.fixture.client / "untracked.txt"
        tracked.write_text("local work\n")
        untracked.write_text("untracked work\n")
        original_status = run("git", "status", "--porcelain", cwd=self.fixture.client).stdout
        self.fixture.publish("remote update\n")

        result = self.backup("--force-fast-forward", "--dry-run")

        self.assertIn("would reset to", result.stdout)
        self.assertIn("delete untracked files", result.stdout)
        self.assertEqual(original_head, self.fixture.client_head())
        self.assertEqual("local work\n", tracked.read_text())
        self.assertEqual("untracked work\n", untracked.read_text())
        self.assertEqual(original_status, run("git", "status", "--porcelain", cwd=self.fixture.client).stdout)

    def test_skip_list_trims_spaces_and_leaves_the_repository(self):
        original_head = self.fixture.client_head()
        self.fixture.publish("remote update\n")

        result = self.backup("--skip-list", " sample , other ")

        self.assertIn("listed in skip configuration", result.stdout)
        self.assertEqual(original_head, self.fixture.client_head())

    def test_nested_repository_is_not_updated(self):
        nested_remote = self.root / "nested.git"
        nested = self.fixture.client / "nested"
        run("git", "init", "--bare", nested_remote)
        publisher = self.root / "nested-publisher"
        run("git", "clone", nested_remote, publisher)
        (publisher / "nested.txt").write_text("one\n")
        run("git", "add", "nested.txt", cwd=publisher)
        run("git", "commit", "-m", "one", cwd=publisher)
        run("git", "push", "-u", "origin", "HEAD", cwd=publisher)
        run("git", "clone", nested_remote, nested)
        run("git", "remote", "set-url", "origin", "https://github.com/example/nested.git", cwd=nested)
        run(
            "git", "config", f"url.file://{nested_remote}.insteadOf",
            "https://github.com/example/nested.git", cwd=nested,
        )
        (publisher / "nested.txt").write_text("two\n")
        run("git", "add", "nested.txt", cwd=publisher)
        run("git", "commit", "-m", "two", cwd=publisher)
        run("git", "push", cwd=publisher)
        nested_head = run("git", "rev-parse", "HEAD", cwd=nested).stdout.strip()

        result = self.backup("--verbose")

        self.assertIn("inside another repository", result.stdout)
        self.assertEqual(nested_head, run("git", "rev-parse", "HEAD", cwd=nested).stdout.strip())
        self.assertEqual("one\n", (nested / "nested.txt").read_text())

    def test_fetch_uses_bearer_token_for_existing_private_repo(self):
        self.fixture.publish("remote update\n")
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fetch_log = self.root / "fetch-env.log"
        real_git = shutil.which("git")
        wrapper = fake_bin / "git"
        wrapper.write_text(
            "#!/bin/sh\n"
            "for arg in \"$@\"; do\n"
            "  if [ \"$arg\" = fetch ]; then\n"
            "    env | grep '^GIT_CONFIG_' | sort > \"$FETCH_LOG\"\n"
            "  fi\n"
            "done\n"
            f'exec "{real_git}" "$@"\n'
        )
        wrapper.chmod(0o755)

        use_profile_checkout(self.fixture)
        with fake_github_server() as api_url:
            self.backup(
                env={
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "GITHUB_BACKUP_TOKEN": "test-token",
                    "GITHUB_BACKUP_API_URL": api_url,
                    "FETCH_LOG": str(fetch_log),
                }
            )

        logged = fetch_log.read_text()
        self.assertIn("GIT_CONFIG_KEY_0=http.extraHeader", logged)
        self.assertIn("GIT_CONFIG_VALUE_0=Authorization: Bearer test-token", logged)
        self.assertIn("GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf", logged)
        self.assertIn("GIT_CONFIG_VALUE_1=git@github.com:", logged)
        self.assertIn("GIT_CONFIG_VALUE_2=ssh://git@github.com/", logged)
        self.assertEqual(self.fixture.remote_head(), self.fixture.client_head())

    def test_missing_base_directory_fails(self):
        missing = self.root / "does-not-exist"
        result = run(
            SCRIPT,
            "sync",
            "--base-dir",
            missing,
            "--log-file",
            self.log,
            check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Base directory does not exist", result.stdout)

    def test_run_report_posts_summary_without_the_token(self):
        use_profile_checkout(self.fixture)
        with form_server() as url, fake_github_server() as api_url:
            result = self.backup(
                env={
                    "GITHUB_BACKUP_NOTIFY_URL": url,
                    "GITHUB_BACKUP_TOKEN": "super-secret-token-value",
                    "GITHUB_BACKUP_API_URL": api_url,
                }
            )

        self.assertIn("Submitted the run report.", result.stdout)
        self.assertEqual(1, len(FormHandler.posts))
        post = FormHandler.posts[0]
        self.assertEqual("application/json", post["accept"])
        self.assertTrue(post["content_type"].startswith("application/x-www-form-urlencoded"))
        self.assertEqual("github-backup/1.4.9", post["user_agent"])
        self.assertEqual("github-backup", form_field("program"))
        self.assertEqual("ok", form_field("status"))
        self.assertIn("0 failed", form_field("summary"))
        self.assertIn("private-one: up to date", form_field("log"))
        self.assertIn("github-backup ", form_field("_subject"))
        self.assertNotIn("super-secret-token-value", post["raw"])
        self.assertNotIn("Bearer", post["raw"])
        self.assertNotIn(url, post["raw"])

    def test_run_report_names_a_fast_forwarded_repository(self):
        self.fixture.publish("remote update\n")

        with form_server() as url:
            result = self.backup(env={"GITHUB_BACKUP_NOTIFY_URL": url})

        self.assertEqual(0, result.returncode)
        self.assertIn("sample: fast-forwarded 1 commit to origin/master", form_field("log"))
        self.assertRegex(form_field("log"), r"tracked\.txt\s+\|")
        self.assertIn("1 file changed, 1 insertion(+), 1 deletion(-)", form_field("log"))
        self.assertNotIn("sample: up to date", form_field("log"))
        self.assertEqual(self.fixture.remote_head(), self.fixture.client_head())

    def test_fast_forward_lists_every_changed_file(self):
        (self.fixture.publisher / "added.txt").write_text("new file\n")
        (self.fixture.publisher / "tracked.txt").write_text("changed\n")
        run("git", "add", "added.txt", "tracked.txt", cwd=self.fixture.publisher)
        run("git", "commit", "-m", "two files", cwd=self.fixture.publisher)
        run("git", "push", cwd=self.fixture.publisher)

        with form_server() as url:
            result = self.backup("--quiet", env={"GITHUB_BACKUP_NOTIFY_URL": url})

        self.assertEqual(0, result.returncode)
        self.assertNotRegex(result.stdout, r"tracked\.txt\s+\|")
        self.assertNotRegex(result.stdout, r"added\.txt\s+\|")
        self.assertNotIn("files changed", result.stdout)
        log = form_field("log")
        self.assertIn("sample: fast-forwarded 1 commit to origin/master", log)
        self.assertRegex(log, r"tracked\.txt\s+\|")
        self.assertRegex(log, r"added\.txt\s+\|")
        self.assertIn("2 files changed, 2 insertions(+), 1 deletion(-)", log)
        self.assertLess(log.index("fast-forwarded"), log.index("tracked.txt"))
        self.assertEqual("changed\n", (self.fixture.client / "tracked.txt").read_text())
        self.assertEqual("new file\n", (self.fixture.client / "added.txt").read_text())

    def test_dry_run_does_not_submit_a_run_report(self):
        with form_server() as url:
            result = self.backup("--dry-run", env={"GITHUB_BACKUP_NOTIFY_URL": url})

        self.assertEqual(0, result.returncode)
        self.assertEqual([], FormHandler.posts)
        self.assertNotIn("Submitted the run report.", result.stdout)

    def test_run_report_includes_skip_lines_and_stays_ok(self):
        (self.fixture.client / "local.txt").write_text("local commit\n")
        run("git", "add", "local.txt", cwd=self.fixture.client)
        run("git", "commit", "-m", "local only", cwd=self.fixture.client)

        with form_server() as url:
            result = self.backup(env={"GITHUB_BACKUP_NOTIFY_URL": url})

        self.assertEqual(0, result.returncode)
        self.assertEqual("ok", form_field("status"))
        self.assertIn("1 skipped", form_field("summary"))
        self.assertIn("Skipping sample: 1 commit ahead of origin/", form_field("log"))
        self.assertNotIn("sample: up to date", form_field("log"))

    def test_stopped_run_posts_a_failure_and_keeps_the_exit_status(self):
        missing = self.root / "does-not-exist"
        with form_server() as url:
            result = run(
                SCRIPT,
                "sync",
                "--base-dir",
                missing,
                "--log-file",
                self.log,
                env={"GITHUB_BACKUP_NOTIFY_URL": url},
                check=False,
            )

        self.assertEqual(1, result.returncode)
        self.assertEqual("failed", form_field("status"))
        self.assertIn("stopped before finishing", form_field("_subject"))
        self.assertIn("Base directory does not exist", form_field("log"))

    def test_run_report_failure_does_not_fail_the_backup(self):
        with form_server(status=500) as url:
            result = self.backup(env={"GITHUB_BACKUP_NOTIFY_URL": url})

        self.assertEqual(0, result.returncode)
        self.assertIn("Could not submit the run report.", result.stdout)
        self.assertNotIn("Submitted the run report.", result.stdout)
        self.assertEqual(1, len(FormHandler.posts))

    def test_quiet_run_still_submits_the_report(self):
        with form_server() as url:
            result = self.backup("--quiet", env={"GITHUB_BACKUP_NOTIFY_URL": url})

        self.assertEqual(0, result.returncode)
        self.assertNotIn("Submitted the run report.", result.stdout)
        self.assertEqual("ok", form_field("status"))

    def test_malformed_notify_url_is_ignored(self):
        result = self.backup(env={"GITHUB_BACKUP_NOTIFY_URL": "http://127.0.0.1/form\nbad"})

        self.assertEqual(0, result.returncode)
        self.assertIn("Ignoring the run-report URL", result.stdout)
        self.assertNotIn("Submitted the run report.", result.stdout)

    def test_notify_on_error_skips_a_successful_report(self):
        with form_server() as url:
            result = self.backup("--notify-on-error", env={"GITHUB_BACKUP_NOTIFY_URL": url})

        self.assertEqual(0, result.returncode)
        self.assertEqual([], FormHandler.posts)
        self.assertNotIn("Submitted the run report.", result.stdout)

    def test_notify_on_error_still_posts_a_failure(self):
        missing = self.root / "does-not-exist"
        with form_server() as url:
            result = run(
                SCRIPT,
                "sync",
                "--notify-on-error",
                "--base-dir",
                missing,
                "--log-file",
                self.log,
                env={"GITHUB_BACKUP_NOTIFY_URL": url},
                check=False,
            )

        self.assertEqual(1, result.returncode)
        self.assertEqual("failed", form_field("status"))
        self.assertIn("stopped before finishing", form_field("_subject"))

    def test_notify_on_error_treats_skips_as_success(self):
        (self.fixture.client / "local.txt").write_text("local commit\n")
        run("git", "add", "local.txt", cwd=self.fixture.client)
        run("git", "commit", "-m", "local only", cwd=self.fixture.client)

        with form_server() as url:
            result = self.backup("--notify-on-error", env={"GITHUB_BACKUP_NOTIFY_URL": url})

        self.assertEqual(0, result.returncode)
        self.assertEqual([], FormHandler.posts)

    def test_email_setting_does_not_invoke_mail(self):
        fake_bin = self.root / "fake-mail-bin"
        fake_bin.mkdir()
        marker = self.root / "mail-was-called"
        for name in ("mail", "sendmail"):
            tool = fake_bin / name
            tool.write_text(f"#!/bin/sh\ntouch {marker}\nexit 0\n")
            tool.chmod(0o755)
        path = str(fake_bin) + os.pathsep + os.environ.get("PATH", "")

        with form_server() as url:
            result = self.backup(
                env={
                    "PATH": path,
                    "GITHUB_BACKUP_EMAIL": "you@example.com",
                    "GITHUB_BACKUP_NOTIFY_URL": url,
                }
            )

        self.assertEqual(0, result.returncode)
        self.assertFalse(marker.exists())
        self.assertEqual(1, len(FormHandler.posts))
        self.assertNotIn("mail nor sendmail", result.stdout)


class FakeGitHubHandler(http.server.BaseHTTPRequestHandler):
    requests = []
    repeat_full_page = False
    fail_login = False

    def do_GET(self):
        type(self).requests.append((self.path, self.headers.get("Authorization")))
        if self.path == "/user":
            if type(self).fail_login:
                self.send_response(401)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"login": "alice"}).encode())
            return
        if self.path.startswith("/user/repos"):
            payload = [] if "page=2" in self.path else [
                {
                    "name": "private-one",
                    "clone_url": "https://github.com/alice/private-one.git",
                    "ssh_url": "git@github.com:alice/private-one.git",
                    "private": True,
                    "owner": {"login": "alice"},
                }
            ]
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())
            return
        if self.path.rstrip("/") == "/users/alice":
            self._json({"login": "alice", "type": "User"})
            return
        if self.path.startswith("/users/alice/repos"):
            if type(self).repeat_full_page:
                payload = [
                    {
                        "name": f"repo-{index:03d}",
                        "clone_url": f"https://github.com/alice/repo-{index:03d}.git",
                        "ssh_url": f"git@github.com:alice/repo-{index:03d}.git",
                        "private": False,
                        "owner": {"login": "alice"},
                    }
                    for index in range(100)
                ]
            else:
                payload = [] if "page=2" in self.path else [
                    {
                        "name": "one",
                        "clone_url": "https://github.com/alice/one.git",
                        "ssh_url": "git@github.com:alice/one.git",
                        "private": False,
                        "owner": {"login": "alice"},
                    }
                ]
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())
            return
        if self.path.rstrip("/") == "/users/acme":
            self._json({"login": "acme", "type": "Organization"})
            return
        if self.path.startswith("/orgs/acme/repos"):
            payload = [] if "page=2" in self.path else [
                {
                    "name": "org-one",
                    "clone_url": "https://github.com/acme/org-one.git",
                    "ssh_url": "git@github.com:acme/org-one.git",
                    "private": True,
                    "owner": {"login": "acme"},
                }
            ]
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())
            return
        self.send_response(404)
        self.end_headers()

    def _json(self, payload):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def log_message(self, format, *args):
        del format, args


@contextlib.contextmanager
def fake_github_server():
    FakeGitHubHandler.requests = []
    FakeGitHubHandler.fail_login = False
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHubHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


class FormHandler(http.server.BaseHTTPRequestHandler):
    posts = []
    status_code = 200

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode()
        FormHandler.posts.append(
            {
                "accept": self.headers.get("Accept", ""),
                "user_agent": self.headers.get("User-Agent", ""),
                "content_type": self.headers.get("Content-Type", ""),
                "fields": urllib.parse.parse_qs(raw, keep_blank_values=True),
                "raw": raw,
            }
        )
        body = b'{"ok":true}'
        self.send_response(FormHandler.status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        del format, args


@contextlib.contextmanager
def form_server(status=200):
    FormHandler.posts = []
    FormHandler.status_code = status
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FormHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/f/testform"
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


def form_field(name):
    return FormHandler.posts[0]["fields"][name][0]


class GitHubBackupProfileAndInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.log = self.root / "backup.log"

    def tearDown(self):
        self.temp.cleanup()

    def test_invalid_profile_name_fails_once(self):
        result = run(SCRIPT, "list-repos", "bad_name", "--log-file", self.log, check=False)
        self.assertEqual(1, result.returncode)
        self.assertEqual(result.stdout.count("Invalid GitHub profile name"), 1)
        self.assertNotIn("GitHub API request failed", result.stdout)

    def test_repeated_repository_page_stops(self):
        FakeGitHubHandler.repeat_full_page = True
        try:
            with fake_github_server() as api_url:
                env = os.environ.copy()
                env.pop("GITHUB_BACKUP_TOKEN", None)
                env.pop("GH_TOKEN", None)
                env.pop("GITHUB_BACKUP_NOTIFY_URL", None)
                env["GITHUB_BACKUP_CONFIG"] = "/tmp/github-backup-test-no-option-file.conf"
                env["GITHUB_BACKUP_API_URL"] = api_url
                result = subprocess.run(
                    [str(SCRIPT), "list-repos", "alice", "--log-file", str(self.log)],
                    env=env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=10,
                    check=False,
                )
        finally:
            FakeGitHubHandler.repeat_full_page = False
        self.assertEqual(0, result.returncode, result.stdout)
        self.assertEqual(100, len(result.stdout.splitlines()))
        paths = [path for path, _header in FakeGitHubHandler.requests]
        self.assertTrue(any("page=1" in path for path in paths))
        self.assertTrue(any("page=2" in path for path in paths))
        self.assertFalse(any("page=3" in path for path in paths))

    def test_list_repos_uses_profile_api(self):
        with fake_github_server() as api_url:
            result = run(
                SCRIPT,
                "list-repos",
                "alice",
                "--log-file",
                self.log,
                env={"GITHUB_BACKUP_API_URL": api_url},
            )
        self.assertEqual("one", result.stdout.strip())

    def test_authenticated_profile_uses_private_endpoint_and_bearer_header(self):
        with fake_github_server() as api_url:
            result = run(
                SCRIPT,
                "list-repos",
                "alice",
                "--verbose",
                "--log-file",
                self.log,
                env={
                    "GITHUB_BACKUP_API_URL": api_url,
                    "GITHUB_BACKUP_TOKEN": "test-token",
                },
            )
        self.assertIn("private-one", result.stdout)
        self.assertIn("private", result.stdout)
        paths = [path for path, _header in FakeGitHubHandler.requests]
        self.assertIn("/user", paths)
        self.assertTrue(any(path.startswith("/user/repos") for path in paths))
        self.assertTrue(
            all(header == "Bearer test-token" for _path, header in FakeGitHubHandler.requests)
        )

    def test_organization_profile_uses_org_repositories(self):
        with fake_github_server() as api_url:
            result = run(
                SCRIPT,
                "list-repos",
                "acme",
                "--verbose",
                "--log-file",
                self.log,
                env={
                    "GITHUB_BACKUP_API_URL": api_url,
                    "GITHUB_BACKUP_TOKEN": "test-token",
                },
            )
        self.assertIn("org-one", result.stdout)
        paths = [path for path, _header in FakeGitHubHandler.requests]
        self.assertTrue(any(path.startswith("/orgs/acme/repos") for path in paths))
        self.assertFalse(any(path.startswith("/users/acme/repos") for path in paths))

    def test_profile_dry_run_plans_new_clone_without_creating_destination(self):
        destination = self.root / "repos"
        with fake_github_server() as api_url:
            result = run(
                SCRIPT,
                "profile",
                "alice",
                "--base-dir",
                destination,
                "--dry-run",
                "--log-file",
                self.log,
                env={"GITHUB_BACKUP_API_URL": api_url},
            )
        self.assertIn("alice/one: would clone into", result.stdout)
        self.assertFalse(destination.exists())

    def test_sync_with_a_token_downloads_the_authenticated_profile(self):
        destination = self.root / "repos"
        with fake_github_server() as api_url:
            result = run(
                SCRIPT,
                "sync",
                "--base-dir",
                destination,
                "--dry-run",
                "--log-file",
                self.log,
                env={
                    "GITHUB_BACKUP_API_URL": api_url,
                    "GITHUB_BACKUP_TOKEN": "test-token",
                },
            )
        self.assertEqual(0, result.returncode)
        self.assertIn(
            f"alice/private-one: would clone into {destination / 'private-one'}",
            result.stdout,
        )
        self.assertFalse(destination.exists())
        paths = [path for path, _header in FakeGitHubHandler.requests]
        self.assertIn("/user", paths)
        self.assertTrue(any(path.startswith("/user/repos") for path in paths))

    def test_explicit_profile_overrides_the_token_account(self):
        destination = self.root / "repos"
        with fake_github_server() as api_url:
            result = run(
                SCRIPT,
                "sync",
                "--profile",
                "acme",
                "--base-dir",
                destination,
                "--dry-run",
                "--log-file",
                self.log,
                env={
                    "GITHUB_BACKUP_API_URL": api_url,
                    "GITHUB_BACKUP_TOKEN": "test-token",
                },
            )
        self.assertEqual(0, result.returncode)
        self.assertIn(
            f"acme/org-one: would clone into {destination / 'org-one'}",
            result.stdout,
        )
        self.assertNotIn("private-one", result.stdout)

    def test_unreadable_token_does_not_update_local_repositories(self):
        destination = self.root / "repos"
        destination.mkdir()
        try:
            with fake_github_server() as api_url:
                FakeGitHubHandler.fail_login = True
                result = run(
                    SCRIPT,
                    "sync",
                    "--base-dir",
                    destination,
                    "--log-file",
                    self.log,
                    env={
                        "GITHUB_BACKUP_API_URL": api_url,
                        "GITHUB_BACKUP_TOKEN": "test-token",
                    },
                    check=False,
                )
        finally:
            FakeGitHubHandler.fail_login = False
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(result.stdout.count("profile was not downloaded"), 1)
        self.assertNotIn("Summary:", result.stdout)

    def test_profile_refuses_nested_directory_inside_another_repository(self):
        fixture = GitFixture(self.root / "fixture")
        base = fixture.client / "backup-destination"
        nested_destination = base / "one"
        nested_destination.mkdir(parents=True)
        tracked = fixture.client / "tracked.txt"
        tracked.write_text("important parent work\n")
        original_head = fixture.client_head()

        with fake_github_server() as api_url:
            result = run(
                SCRIPT,
                "profile",
                "alice",
                "--base-dir",
                base,
                "--force-fast-forward",
                "--log-file",
                self.log,
                env={"GITHUB_BACKUP_API_URL": api_url},
                check=False,
            )

        self.assertIn("destination is not a repository root", result.stdout)
        self.assertEqual(original_head, fixture.client_head())
        self.assertEqual("important parent work\n", tracked.read_text())

    def test_profile_refuses_symlink_destination_to_parent_repository(self):
        fixture = GitFixture(self.root / "symlink-fixture")
        base = fixture.client / "backup-destination"
        base.mkdir()
        (base / "one").symlink_to(fixture.client, target_is_directory=True)
        tracked = fixture.client / "tracked.txt"
        tracked.write_text("important symlink-parent work\n")
        original_head = fixture.client_head()

        with fake_github_server() as api_url:
            result = run(
                SCRIPT,
                "profile",
                "alice",
                "--base-dir",
                base,
                "--force-fast-forward",
                "--log-file",
                self.log,
                env={"GITHUB_BACKUP_API_URL": api_url},
                check=False,
            )

        self.assertIn("destination is a symbolic link", result.stdout)
        self.assertEqual(original_head, fixture.client_head())
        self.assertEqual("important symlink-parent work\n", tracked.read_text())

    def paths(self, name):
        root = self.root / name
        return {
            "GITHUB_BACKUP_INSTALL_PATH": str(root / "bin" / "github-backup"),
            "GITHUB_BACKUP_COMPLETION_DIR": str(root / "completion"),
            "GITHUB_BACKUP_SYSTEMD_DIR": str(root / "systemd"),
            "GITHUB_BACKUP_DEFAULTS_FILE": str(root / "etc" / "github-backup"),
            "GITHUB_BACKUP_CONFIG": str(root / "etc" / "github-backup.conf"),
        }

    def test_install_copies_binary_and_completion_without_units(self):
        env = self.paths("install")
        run(SCRIPT, "install", env=env)

        install_path = pathlib.Path(env["GITHUB_BACKUP_INSTALL_PATH"])
        self.assertTrue(os.access(install_path, os.X_OK))
        completion = pathlib.Path(env["GITHUB_BACKUP_COMPLETION_DIR"], "github-backup").read_text()
        self.assertIn("--force-fast-forward", completion)
        self.assertIn("--config", completion)
        self.assertIn("--token", completion)
        self.assertIn("--notify-url", completion)
        self.assertIn("--notify-on-error", completion)
        self.assertIn("setup", completion)
        self.assertFalse(pathlib.Path(env["GITHUB_BACKUP_DEFAULTS_FILE"]).exists())
        self.assertFalse(pathlib.Path(env["GITHUB_BACKUP_SYSTEMD_DIR"], "github-backup.service").exists())

    def test_setup_writes_config_units_and_schedule(self):
        env = self.paths("setup")
        destination = self.root / "setup" / "my dir"
        run(
            SCRIPT,
            "setup",
            "--base-dir",
            destination,
            "--profile",
            "alice",
            "--schedule",
            "daily",
            "--log-file",
            self.root / "setup" / "backup.log",
            env=env,
        )

        self.assertTrue(destination.is_dir())
        service = pathlib.Path(env["GITHUB_BACKUP_SYSTEMD_DIR"], "github-backup.service").read_text()
        self.assertIn(env["GITHUB_BACKUP_INSTALL_PATH"], service)
        timer = pathlib.Path(env["GITHUB_BACKUP_SYSTEMD_DIR"], "github-backup.timer").read_text()
        self.assertIn("OnCalendar=daily", timer)
        self.assertIn("Unit=github-backup.service", timer)
        defaults_file = pathlib.Path(env["GITHUB_BACKUP_DEFAULTS_FILE"])
        self.assertEqual(0o600, defaults_file.stat().st_mode & 0o777)
        defaults = defaults_file.read_text()
        self.assertIn("GITHUB_BACKUP_PROFILE=alice", defaults)
        self.assertIn(f'GITHUB_BACKUP_BASE_DIR="{destination}"', defaults)
        self.assertNotIn("GITHUB_BACKUP_EMAIL", defaults)
        self.assertIn("# GITHUB_BACKUP_NOTIFY_URL=https://formester.com/f/yourFormId", defaults)
        self.assertIn(
            f'ExecStart={env["GITHUB_BACKUP_INSTALL_PATH"]} sync --config {env["GITHUB_BACKUP_CONFIG"]}',
            service,
        )

    def test_service_omits_the_standard_option_file(self):
        standard = run(
            "bash",
            "-c",
            f'source "{SCRIPT}"; service_exec_start /usr/local/bin/github-backup /etc/github-backup/github-backup.conf',
        )
        custom = run(
            "bash",
            "-c",
            f'source "{SCRIPT}"; service_exec_start /usr/local/bin/github-backup "/tmp/my backup.conf"',
        )
        self.assertEqual("/usr/local/bin/github-backup sync", standard.stdout.strip())
        self.assertEqual(
            '/usr/local/bin/github-backup sync --config "/tmp/my backup.conf"',
            custom.stdout.strip(),
        )

    def test_setup_installs_commented_option_file(self):
        env = self.paths("option-file")
        destination = self.root / "option-file" / "repos"
        run(
            SCRIPT,
            "setup",
            "--base-dir",
            destination,
            "--log-file",
            self.root / "option-file" / "backup.log",
            env=env,
        )

        installed = pathlib.Path(env["GITHUB_BACKUP_CONFIG"])
        text = installed.read_text()
        self.assertEqual(0o600, installed.stat().st_mode & 0o777)
        self.assertEqual((ROOT / "github-backup.conf.example").read_text(), text)
        for option in (
            "--base-dir",
            "--profile",
            "# --skip repo-one",
            "--skip-list",
            "--log-file",
            "--token",
            "--dry-run",
            "--verbose",
            "--debug",
            "--quiet",
            "--notify-url",
            "--notify-on-error",
            "--force-fast-forward",
            "--schedule",
            "--no-systemd",
            "--purge-config",
            "--notify-url https://formester.com/f/yourFormId",
            "https://github.com/peternickol/github-backup/blob/master/README.md#safety",
            "https://github.com/peternickol/github-backup/blob/master/README.md#commands",
            "https://github.com/peternickol/github-backup/blob/master/README.md#options",
            "https://github.com/peternickol/github-backup/blob/master/README.md#run-report",
            "https://github.com/peternickol/github-backup/blob/master/README.md#schedule",
            "https://github.com/peternickol/github-backup/blob/master/README.md#configuration",
            "https://github.com/peternickol/github-backup/blob/master/README.md#profile",
            "https://github.com/peternickol/github-backup/blob/master/README.md#setup",
            "https://github.com/peternickol/github-backup/blob/master/README.md#uninstall",
            "https://github.com/peternickol/github-backup/blob/master/README.md#sync",
        ):
            self.assertIn(option, text)
        for option in (
            "--no-completion",
            "--completion-only",
            "--uninstall-completion",
            "--install",
            "--update",
            "--uninstall",
            "--list-repos",
            "--config",
            "--version",
            "--help",
            "\n# -q\n",
            "\n# -f\n",
            "\n# -V\n",
            "\n# -h\n",
            "GITHUB_BACKUP_EMAIL",
        ):
            self.assertNotIn(option, text)
        self.assertEqual([], [line for line in text.splitlines() if line.startswith("-")])

    def test_setup_preserves_an_edited_option_file(self):
        env = self.paths("keep-option")
        destination = self.root / "keep-option" / "repos"
        log_file = self.root / "keep-option" / "backup.log"
        run(
            SCRIPT,
            "setup",
            "--no-systemd",
            "--base-dir",
            destination,
            "--log-file",
            log_file,
            env=env,
        )
        option = pathlib.Path(env["GITHUB_BACKUP_CONFIG"])
        option.write_text(option.read_text() + "--token super-secret-token-value\n")

        run(
            SCRIPT,
            "setup",
            "--no-systemd",
            "--base-dir",
            destination,
            "--log-file",
            log_file,
            env=env,
        )

        self.assertEqual(1, option.read_text().count("--token super-secret-token-value"))

    def test_setup_force_keeps_uncommented_option_lines(self):
        env = self.paths("refresh-option")
        destination = self.root / "refresh-option" / "repos"
        log_file = self.root / "refresh-option" / "backup.log"
        run(
            SCRIPT,
            "setup",
            "--no-systemd",
            "--base-dir",
            destination,
            "--log-file",
            log_file,
            env=env,
        )
        option = pathlib.Path(env["GITHUB_BACKUP_CONFIG"])
        option.write_text(
            "# old comment that should be refreshed\n"
            "--token super-secret-token-value\n"
            "--base-dir /kept\n"
        )

        run(
            SCRIPT,
            "setup",
            "--force",
            "--no-systemd",
            "--base-dir",
            destination,
            "--log-file",
            log_file,
            env=env,
        )

        text = option.read_text()
        self.assertIn("sshd_config", text)
        self.assertIn("# Settings kept from the previous file.", text)
        self.assertIn("--token super-secret-token-value", text)
        self.assertIn("--base-dir /kept", text)
        self.assertNotIn("old comment that should be refreshed", text)
        defaults = pathlib.Path(env["GITHUB_BACKUP_DEFAULTS_FILE"]).read_text()
        self.assertNotIn("super-secret-token-value", defaults)

    def test_setup_saves_notify_url_from_the_environment(self):
        env = self.paths("notify-setup")
        env["GITHUB_BACKUP_NOTIFY_URL"] = "https://formester.com/f/abcxyz"
        destination = self.root / "notify-setup" / "repos"
        run(
            SCRIPT,
            "setup",
            "--no-systemd",
            "--base-dir",
            destination,
            "--log-file",
            self.root / "notify-setup" / "backup.log",
            env=env,
        )

        defaults_file = pathlib.Path(env["GITHUB_BACKUP_DEFAULTS_FILE"])
        self.assertEqual(0o600, defaults_file.stat().st_mode & 0o777)
        self.assertIn(
            "GITHUB_BACKUP_NOTIFY_URL=https://formester.com/f/abcxyz",
            defaults_file.read_text(),
        )

    def test_setup_without_systemd_still_writes_configuration(self):
        env = self.paths("cron")
        destination = self.root / "cron" / "repos"
        run(
            SCRIPT,
            "setup",
            "--no-systemd",
            "--base-dir",
            destination,
            "--profile",
            "alice",
            "--log-file",
            self.root / "cron" / "backup.log",
            env=env,
        )

        defaults = pathlib.Path(env["GITHUB_BACKUP_DEFAULTS_FILE"]).read_text()
        self.assertIn("GITHUB_BACKUP_PROFILE=alice", defaults)
        self.assertFalse(pathlib.Path(env["GITHUB_BACKUP_SYSTEMD_DIR"], "github-backup.timer").exists())
        self.assertTrue(destination.is_dir())

    def test_sync_reads_quoted_base_dir_from_configuration(self):
        env = self.paths("quoted")
        destination = self.root / "quoted" / "my dir"
        log_file = self.root / "quoted" / "backup.log"
        run(
            SCRIPT,
            "setup",
            "--no-systemd",
            "--base-dir",
            destination,
            "--log-file",
            log_file,
            env=env,
        )
        result = run(
            SCRIPT,
            "sync",
            "--dry-run",
            env={"GITHUB_BACKUP_DEFAULTS_FILE": env["GITHUB_BACKUP_DEFAULTS_FILE"]},
        )
        self.assertEqual(0, result.returncode)
        self.assertIn("Summary:", result.stdout)
        self.assertNotIn("Base directory does not exist", result.stdout)
        self.assertTrue(destination.is_dir())

    def test_enable_arms_timer_and_start_runs_service(self):
        env = self.paths("systemd-commands")
        record = self.root / "systemd-commands" / "systemctl.args"
        fake = self.root / "systemd-commands" / "systemctl"
        fake.parent.mkdir(parents=True)
        fake.write_text(
            "#!/bin/sh\n"
            f'printf "%s\\n" "$*" >> "{record}"\n'
        )
        fake.chmod(0o755)
        env["GITHUB_BACKUP_SYSTEMCTL"] = str(fake)
        run(
            SCRIPT,
            "setup",
            "--base-dir",
            self.root / "systemd-commands" / "repos",
            "--log-file",
            self.root / "systemd-commands" / "backup.log",
            env=env,
        )
        run(SCRIPT, "enable", env=env)
        run(SCRIPT, "start", env=env)
        recorded = record.read_text().splitlines()
        self.assertIn("daemon-reload", recorded)
        self.assertIn("enable --now github-backup.timer", recorded)
        self.assertIn("start github-backup.service", recorded)

    def test_setup_fails_when_configuration_cannot_be_replaced(self):
        env = self.paths("config-failure")
        defaults_file = pathlib.Path(env["GITHUB_BACKUP_DEFAULTS_FILE"])
        defaults_file.parent.mkdir(parents=True)
        defaults_file.unlink(missing_ok=True)
        defaults_file.mkdir()
        result = run(
            SCRIPT,
            "setup",
            "--base-dir",
            self.root / "config-failure" / "repos",
            "--log-file",
            self.root / "config-failure" / "backup.log",
            "--force",
            env=env,
            check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("is a directory, expected a file", result.stdout)

    def test_setup_fails_when_systemctl_reload_fails(self):
        env = self.paths("reload-failure")
        fake_systemctl = self.root / "reload-failure" / "systemctl"
        fake_systemctl.parent.mkdir(parents=True)
        fake_systemctl.write_text("#!/bin/sh\nexit 1\n")
        fake_systemctl.chmod(0o755)
        env["GITHUB_BACKUP_SYSTEMCTL"] = str(fake_systemctl)
        result = run(
            SCRIPT,
            "setup",
            "--base-dir",
            self.root / "reload-failure" / "repos",
            "--log-file",
            self.root / "reload-failure" / "backup.log",
            env=env,
            check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("systemctl daemon-reload failed", result.stdout)


class GitHubBackupHelpTests(unittest.TestCase):
    def test_no_arguments_prints_help(self):
        result = run(SCRIPT)
        self.assertEqual(0, result.returncode)
        self.assertIn("Usage:", result.stdout)
        self.assertIn("profile USER", result.stdout)
        self.assertIn("GITHUB_BACKUP_NOTIFY_URL", result.stdout)
        self.assertIn("--config FILE", result.stdout)
        self.assertIn("--token TOKEN", result.stdout)
        self.assertIn("--notify-url URL", result.stdout)
        self.assertIn("--notify-on-error", result.stdout)
        self.assertIn("The backup command is: github-backup sync", result.stdout)
        self.assertNotIn("[ERROR]", result.stdout)

    def test_unknown_argument_prints_help_and_fails(self):
        result = run(SCRIPT, "--not-a-real-option", check=False)
        self.assertEqual(1, result.returncode)
        self.assertIn("Unknown argument: --not-a-real-option", result.stdout)
        self.assertIn("Usage:", result.stdout)

    def test_missing_option_value_prints_help(self):
        result = run(SCRIPT, "profile", check=False)
        self.assertEqual(1, result.returncode)
        self.assertIn("profile requires a value.", result.stdout)
        self.assertIn("Usage:", result.stdout)

    def test_config_requires_a_value(self):
        result = run(SCRIPT, "sync", "--config", check=False)
        self.assertEqual(1, result.returncode)
        self.assertIn("--config requires a value.", result.stdout)
        self.assertIn("Usage:", result.stdout)


class GitHubBackupConfigFileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.fixture = GitFixture(self.root)
        self.log = self.root / "backup.log"
        self.config = self.root / "backup.conf"

    def tearDown(self):
        self.temp.cleanup()

    def write_config(self, text):
        self.config.write_text(text)
        return self.config

    def test_config_file_supplies_base_dir_and_dry_run(self):
        self.fixture.publish("remote update\n")
        original = self.fixture.client_head()
        recorded = run("git", "rev-parse", "origin/master", cwd=self.fixture.client).stdout.strip()
        self.write_config(
            "\n".join(
                [
                    "# preview only",
                    "",
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--dry-run",
                    "--verbose",
                ]
            )
            + "\n"
        )

        result = run(SCRIPT, "sync", "--config", self.config)

        self.assertEqual(0, result.returncode)
        self.assertIn("up to date", result.stdout)
        self.assertNotIn("would fast-forward", result.stdout)
        self.assertEqual(original, self.fixture.client_head())
        self.assertEqual(recorded, run("git", "rev-parse", "origin/master", cwd=self.fixture.client).stdout.strip())

    def test_command_line_overrides_config_file_and_environment(self):
        missing = self.root / "missing"
        self.write_config(
            "\n".join(
                [
                    f"--base-dir {missing}",
                    "--verbose",
                ]
            )
            + "\n"
        )

        result = run(
            SCRIPT,
            "sync",
            "--config",
            self.config,
            "--base-dir",
            self.fixture.client.parent,
            "--log-file",
            self.log,
            "--dry-run",
            env={"GITHUB_BACKUP_BASE_DIR": str(self.root / "from-env")},
        )

        self.assertEqual(0, result.returncode)
        self.assertIn("up to date", result.stdout)
        self.assertNotIn("Base directory does not exist", result.stdout)

    def test_config_file_wins_over_the_environment(self):
        self.write_config(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--dry-run",
                    "--verbose",
                ]
            )
            + "\n"
        )

        result = run(
            SCRIPT,
            "sync",
            "--config",
            self.config,
            env={"GITHUB_BACKUP_BASE_DIR": str(self.root / "from-env")},
        )

        self.assertEqual(0, result.returncode)
        self.assertIn("up to date", result.stdout)
        self.assertNotIn("from-env", result.stdout)

    def test_command_line_skip_replaces_the_config_file_skip(self):
        self.write_config(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--dry-run",
                    "--verbose",
                    "--skip sample",
                ]
            )
            + "\n"
        )

        result = run(SCRIPT, "sync", "--config", self.config, "--skip", "other")

        self.assertEqual(0, result.returncode)
        self.assertNotIn("Skipping sample", result.stdout)
        self.assertIn("sample: up to date", result.stdout)

    def test_command_line_skip_list_replaces_the_config_file_skip_list(self):
        self.write_config(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--dry-run",
                    "--verbose",
                    "--skip-list sample",
                ]
            )
            + "\n"
        )

        result = run(SCRIPT, "sync", "--config", self.config, "--skip-list", "other")

        self.assertEqual(0, result.returncode)
        self.assertNotIn("Skipping sample", result.stdout)
        self.assertIn("sample: up to date", result.stdout)

    def test_config_skip_list_replaces_the_environment_skip_list(self):
        self.write_config(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--dry-run",
                    "--verbose",
                    "--skip-list other",
                ]
            )
            + "\n"
        )

        result = run(
            SCRIPT,
            "sync",
            "--config",
            self.config,
            env={"GITHUB_BACKUP_SKIP_LIST": "sample"},
        )

        self.assertEqual(0, result.returncode)
        self.assertNotIn("Skipping sample", result.stdout)
        self.assertIn("sample: up to date", result.stdout)

    def test_command_line_skip_keeps_the_environment_list(self):
        self.write_config(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--dry-run",
                    "--verbose",
                    "--skip-list other",
                ]
            )
            + "\n"
        )

        result = run(
            SCRIPT,
            "sync",
            "--config",
            self.config,
            "--skip",
            "third",
            env={"GITHUB_BACKUP_SKIP_LIST": "sample"},
        )

        self.assertEqual(0, result.returncode)
        self.assertIn("Skipping sample: listed in skip configuration", result.stdout)
        self.assertNotIn("sample: up to date", result.stdout)

    def test_config_file_skip_is_applied(self):
        self.fixture.publish("remote update\n")
        self.write_config(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--dry-run",
                    "--skip sample",
                ]
            )
            + "\n"
        )

        result = run(SCRIPT, "sync", "--config", self.config)

        self.assertEqual(0, result.returncode)
        self.assertIn("Skipping sample: listed in skip configuration", result.stdout)
        self.assertNotIn("would fast-forward", result.stdout)

    def test_quoted_base_dir_in_config_file(self):
        destination = self.root / "my dir"
        destination.mkdir()
        self.write_config(f'--base-dir "{destination}"\n--dry-run\n--log-file "{self.log}"\n')

        result = run(SCRIPT, "sync", "--config", self.config)

        self.assertEqual(0, result.returncode)
        self.assertIn("Summary:", result.stdout)
        self.assertNotIn("does not exist", result.stdout)

    def test_missing_config_file_fails(self):
        missing = self.root / "absent.conf"
        result = run(SCRIPT, "sync", "--config", missing, check=False)
        self.assertEqual(1, result.returncode)
        self.assertIn("Configuration file is not a readable file", result.stdout)

    def test_unknown_option_in_config_file_fails(self):
        self.write_config("--not-an-option\n")
        result = run(SCRIPT, "sync", "--config", self.config, check=False)
        self.assertEqual(1, result.returncode)
        self.assertIn(f"{self.config}:1: Unknown argument: --not-an-option", result.stdout)

    def test_flag_value_in_config_file_fails(self):
        self.write_config("--dry-run true\n")
        result = run(SCRIPT, "sync", "--config", self.config, check=False)
        self.assertEqual(1, result.returncode)
        self.assertIn("does not take a value", result.stdout)

    def test_nested_config_is_rejected(self):
        other = self.root / "other.conf"
        other.write_text("--dry-run\n")
        self.write_config(f"--config {other}\n")
        result = run(SCRIPT, "sync", "--config", self.config, check=False)
        self.assertEqual(1, result.returncode)
        self.assertIn("--config cannot be nested", result.stdout)

    def bearer_from_config(self, config_text, *extra, env=None):
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fetch_log = self.root / "fetch-env.log"
        real_git = shutil.which("git")
        wrapper = fake_bin / "git"
        wrapper.write_text(
            "#!/bin/sh\n"
            "for arg in \"$@\"; do\n"
            "  if [ \"$arg\" = fetch ]; then\n"
            "    env | grep '^GIT_CONFIG_' | sort > \"$FETCH_LOG\"\n"
            "  fi\n"
            "done\n"
            f'exec "{real_git}" "$@"\n'
        )
        wrapper.chmod(0o755)
        use_profile_checkout(self.fixture)
        self.write_config(config_text)
        merged = {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "FETCH_LOG": str(fetch_log),
        }
        if env:
            merged.update(env)
        with fake_github_server() as api_url:
            merged["GITHUB_BACKUP_API_URL"] = api_url
            result = run(
                SCRIPT,
                "sync",
                "--config",
                self.config,
                *extra,
                env=merged,
            )
        return result, fetch_log.read_text()

    def test_config_file_token_is_used_and_beats_the_environment(self):
        _result, logged = self.bearer_from_config(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--token file-token",
                ]
            )
            + "\n",
            env={"GITHUB_BACKUP_TOKEN": "env-token"},
        )

        self.assertIn("GIT_CONFIG_VALUE_0=Authorization: Bearer file-token", logged)
        self.assertNotIn("env-token", logged)
        self.assertEqual(self.fixture.remote_head(), self.fixture.client_head())

    def test_command_line_token_overrides_the_config_file(self):
        _result, logged = self.bearer_from_config(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--token file-token",
                ]
            )
            + "\n",
            "--token",
            "cli-token",
        )

        self.assertIn("GIT_CONFIG_VALUE_0=Authorization: Bearer cli-token", logged)
        self.assertNotIn("file-token", logged)

    def test_config_file_token_is_not_in_the_run_report(self):
        use_profile_checkout(self.fixture)
        with form_server() as url, fake_github_server() as api_url:
            self.write_config(
                "\n".join(
                    [
                        f"--base-dir {self.fixture.client.parent}",
                        f"--log-file {self.log}",
                        "--token super-secret-token-value",
                    ]
                )
                + "\n"
            )
            result = run(
                SCRIPT,
                "sync",
                "--config",
                self.config,
                env={
                    "GITHUB_BACKUP_NOTIFY_URL": url,
                    "GITHUB_BACKUP_API_URL": api_url,
                },
            )

        self.assertIn("Submitted the run report.", result.stdout)
        self.assertNotIn("super-secret-token-value", FormHandler.posts[0]["raw"])
        self.assertNotIn("Bearer", FormHandler.posts[0]["raw"])

    def test_config_file_notify_on_error_skips_a_successful_report(self):
        self.write_config(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--notify-on-error",
                ]
            )
            + "\n"
        )
        with form_server() as url:
            result = run(
                SCRIPT,
                "sync",
                "--config",
                self.config,
                env={"GITHUB_BACKUP_NOTIFY_URL": url},
            )

        self.assertEqual(0, result.returncode)
        self.assertEqual([], FormHandler.posts)

    def test_notify_url_in_the_option_file_submits_the_report(self):
        with form_server() as url:
            self.write_config(
                "\n".join(
                    [
                        f"--base-dir {self.fixture.client.parent}",
                        f"--log-file {self.log}",
                        f"--notify-url {url}",
                    ]
                )
                + "\n"
            )
            result = run(
                SCRIPT,
                "sync",
                "--config",
                self.config,
                env={"GITHUB_BACKUP_NOTIFY_URL": "http://127.0.0.1:9/from-the-environment"},
            )

        self.assertEqual(0, result.returncode, result.stdout)
        self.assertIn("Submitted the run report.", result.stdout)
        self.assertEqual(1, len(FormHandler.posts))
        self.assertIn("sample: up to date", form_field("log"))

    def test_command_line_notify_url_replaces_the_option_file(self):
        with form_server() as url:
            self.write_config(
                "\n".join(
                    [
                        f"--base-dir {self.fixture.client.parent}",
                        f"--log-file {self.log}",
                        "--notify-url http://127.0.0.1:9/from-the-file",
                    ]
                )
                + "\n"
            )
            result = run(
                SCRIPT,
                "sync",
                "--config",
                self.config,
                "--notify-url",
                url,
            )

        self.assertEqual(0, result.returncode, result.stdout)
        self.assertEqual(1, len(FormHandler.posts))
        self.assertIn("sample: up to date", form_field("log"))

    def test_setup_uses_the_config_file_without_copying_the_token(self):
        env = {
            "GITHUB_BACKUP_INSTALL_PATH": str(self.root / "bin" / "github-backup"),
            "GITHUB_BACKUP_COMPLETION_DIR": str(self.root / "completion"),
            "GITHUB_BACKUP_SYSTEMD_DIR": str(self.root / "systemd"),
            "GITHUB_BACKUP_DEFAULTS_FILE": str(self.root / "etc" / "github-backup"),
            "GITHUB_BACKUP_CONFIG": str(self.root / "etc" / "github-backup.conf"),
        }
        conf = self.root / "my backup.conf"
        conf.write_text(
            "\n".join(
                [
                    f"--base-dir {self.root / 'repos'}",
                    "--token super-secret-token-value",
                ]
            )
            + "\n"
        )
        run(
            SCRIPT,
            "setup",
            "--config",
            conf,
            "--log-file",
            self.log,
            "--no-systemd",
            env=env,
        )
        defaults = pathlib.Path(env["GITHUB_BACKUP_DEFAULTS_FILE"]).read_text()
        self.assertNotIn("super-secret-token-value", defaults)
        self.assertIn("# GITHUB_BACKUP_TOKEN=github_pat_...", defaults)

        run(
            SCRIPT,
            "setup",
            "--force",
            "--config",
            conf,
            "--log-file",
            self.log,
            env=env,
        )
        service = pathlib.Path(env["GITHUB_BACKUP_SYSTEMD_DIR"], "github-backup.service").read_text()
        self.assertIn(f'ExecStart={env["GITHUB_BACKUP_INSTALL_PATH"]} sync --config "{conf}"', service)
        self.assertNotIn("super-secret-token-value", service)

    def test_installed_option_file_is_read_without_a_config_flag(self):
        path = self.root / "github-backup.conf"
        path.write_text(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--dry-run",
                    "--verbose",
                ]
            )
            + "\n"
        )

        result = run(SCRIPT, "sync", env={"GITHUB_BACKUP_CONFIG": str(path)})

        self.assertEqual(0, result.returncode)
        self.assertIn("sample: up to date", result.stdout)

    def test_explicit_config_replaces_the_installed_option_file(self):
        installed = self.root / "github-backup.conf"
        installed.write_text(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--dry-run",
                    "--verbose",
                    "--skip sample",
                ]
            )
            + "\n"
        )
        self.write_config(
            "\n".join(
                [
                    f"--base-dir {self.fixture.client.parent}",
                    f"--log-file {self.log}",
                    "--dry-run",
                    "--verbose",
                ]
            )
            + "\n"
        )

        result = run(
            SCRIPT,
            "sync",
            "--config",
            self.config,
            env={"GITHUB_BACKUP_CONFIG": str(installed)},
        )

        self.assertEqual(0, result.returncode)
        self.assertNotIn("Skipping sample", result.stdout)
        self.assertIn("sample: up to date", result.stdout)

    def test_command_line_overrides_the_installed_option_file(self):
        path = self.root / "github-backup.conf"
        path.write_text(f"--base-dir {self.root / 'missing'}\n--verbose\n")

        result = run(
            SCRIPT,
            "sync",
            "--base-dir",
            self.fixture.client.parent,
            "--log-file",
            self.log,
            "--dry-run",
            env={"GITHUB_BACKUP_CONFIG": str(path)},
        )

        self.assertEqual(0, result.returncode)
        self.assertIn("up to date", result.stdout)
        self.assertNotIn("Base directory does not exist", result.stdout)

    def test_config_option_once(self):
        self.write_config("--dry-run\n")
        result = run(
            SCRIPT,
            "sync",
            "--config",
            self.config,
            "--config",
            self.config,
            check=False,
        )
        self.assertEqual(1, result.returncode)
        self.assertIn("--config was given more than once.", result.stdout)


if __name__ == "__main__":
    unittest.main()
