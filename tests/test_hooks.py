"""Tests for mtk's hooks.

Each test runs a hook script the way Claude Code does: a JSON payload on stdin,
and the script's stdout read back. HOME points at a temp folder, so the hooks'
state (~/.mtk/...) never touches the real one. Hooks that need a git repo get a
fresh one in a temp folder.

Run: python3 -m unittest discover tests     (or: pytest)
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOKS = os.path.join(ROOT, "hooks")


class HookCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mtk-test-")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.env = {**os.environ, "HOME": self.home}
        for k in ("MTK_CONTEXT_WINDOW", "MTK_HANDOFF_AT", "MTK_STRIKE_LIMIT", "MTK_VERIFY_GATE_LIMIT"):
            self.env.pop(k, None)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def hook(self, script, *args, payload=None, env=None):
        """Run hooks/<script> and return (stdout, parsed JSON or None)."""
        r = subprocess.run(
            ["sh", os.path.join(HOOKS, script), *args],
            input=json.dumps(payload or {}).encode(),
            capture_output=True,
            env={**self.env, **(env or {})},
            timeout=30,
        )
        self.assertEqual(r.returncode, 0, r.stderr.decode())
        out = r.stdout.decode().strip()
        try:
            return out, json.loads(out)
        except ValueError:
            return out, None

    # -- git helpers --------------------------------------------------------
    def repo(self):
        path = os.path.join(self.tmp, "repo")
        os.makedirs(path)
        self.git(path, "init", "-q")
        self.git(path, "config", "user.email", "test@example.com")
        self.git(path, "config", "user.name", "test")
        self.write(path, "README.md", "hello\n")
        self.commit(path, "first")
        return path

    def git(self, path, *args):
        subprocess.run(["git", "-C", path, *args], check=True, capture_output=True)

    def write(self, path, name, text):
        full = os.path.join(path, name)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(text)

    def commit(self, path, msg):
        self.git(path, "add", "-A")
        self.git(path, "commit", "-q", "-m", msg)


# ── memory.sh ───────────────────────────────────────────────────────────────
NOW = "# Now\n\nGoal: test the hooks\n\nNext: write one test\n\n## Decisions\n"
PLAN = {"steps": [
    {"id": 1, "step": "first step", "done": True},
    {"id": 2, "step": "second step", "done": False},
]}


class MemoryTest(HookCase):
    def memory_repo(self):
        path = self.repo()
        self.write(path, ".mtk/now.md", NOW)
        self.write(path, ".mtk/plan.json", json.dumps(PLAN))
        self.write(path, ".mtk/log.md", "# Log\n\n## 2026-11-22 — first\n- Done: x\n")
        self.commit(path, "memory")
        return path

    def test_start_without_memory_prints_nothing(self):
        out, _ = self.hook("memory.sh", "start", payload={"cwd": self.repo()})
        self.assertEqual(out, "")

    def test_start_shows_banner_to_user_and_memory_to_claude(self):
        _, d = self.hook("memory.sh", "start", payload={"cwd": self.memory_repo()})
        banner = d["systemMessage"]
        self.assertIn("Goal: test the hooks", banner)
        self.assertIn("Next: write one test", banner)
        self.assertIn("Plan: 1 of 2 steps done", banner)
        self.assertNotIn("STALE", banner)
        ctx = d["hookSpecificOutput"]["additionalContext"]
        self.assertEqual(d["hookSpecificOutput"]["hookEventName"], "SessionStart")
        self.assertIn("## Decisions", ctx)
        self.assertIn("- [2] second step", ctx)
        self.assertNotIn("- [1] first step", ctx)       # done steps are not listed
        self.assertIn("## 2026-11-22 — first", ctx)

    def test_start_says_stale_after_a_newer_commit(self):
        path = self.memory_repo()
        self.write(path, "code.py", "x = 1\n")
        self.commit(path, "code")
        _, d = self.hook("memory.sh", "start", payload={"cwd": path})
        self.assertIn("STALE", d["systemMessage"])
        self.assertIn("1 commit(s)", d["hookSpecificOutput"]["additionalContext"])

    def test_start_reports_broken_plan_json(self):
        path = self.memory_repo()
        self.write(path, ".mtk/plan.json", "{not json")
        _, d = self.hook("memory.sh", "start", payload={"cwd": path})
        self.assertIn("not valid JSON", d["hookSpecificOutput"]["additionalContext"])

    def test_stop_allows_when_memory_is_fresh(self):
        out, _ = self.hook("memory.sh", "stop", payload={"cwd": self.memory_repo(), "session_id": "s1"})
        self.assertEqual(out, "")

    def test_stop_blocks_once_per_new_commit(self):
        path = self.memory_repo()
        self.write(path, "code.py", "x = 1\n")
        self.commit(path, "code")
        p = {"cwd": path, "session_id": "s1"}
        _, d = self.hook("memory.sh", "stop", payload=p)
        self.assertEqual(d["decision"], "block")
        self.assertIn("/mtk:handoff", d["reason"])
        out, _ = self.hook("memory.sh", "stop", payload=p)
        self.assertEqual(out, "", "second stop on the same commit must not block")
        self.write(path, "code.py", "x = 2\n")
        self.commit(path, "more code")
        _, d = self.hook("memory.sh", "stop", payload=p)
        self.assertEqual(d["decision"], "block", "a new commit blocks again")

    def test_stop_blocks_a_renamed_plan_step(self):
        path = self.memory_repo()
        plan = json.loads(json.dumps(PLAN))
        plan["steps"][1]["step"] = "renamed"
        self.write(path, ".mtk/plan.json", json.dumps(plan))
        _, d = self.hook("memory.sh", "stop", payload={"cwd": path, "session_id": "s1"})
        self.assertEqual(d["decision"], "block")
        self.assertIn("step(s) 2", d["reason"])

    def test_stop_allows_marking_a_step_done(self):
        path = self.memory_repo()
        plan = json.loads(json.dumps(PLAN))
        plan["steps"][1]["done"] = True
        self.write(path, ".mtk/plan.json", json.dumps(plan))
        out, _ = self.hook("memory.sh", "stop", payload={"cwd": path, "session_id": "s1"})
        self.assertEqual(out, "")

    def test_stop_blocks_once_at_70_percent_context(self):
        path = self.memory_repo()
        transcript = os.path.join(self.tmp, "t.jsonl")
        with open(transcript, "w") as f:
            f.write(json.dumps({"type": "assistant", "message": {
                "model": "claude-sonnet", "usage": {"input_tokens": 150_000}}}) + "\n")
        p = {"cwd": path, "session_id": "s1", "transcript_path": transcript}
        _, d = self.hook("memory.sh", "stop", payload=p)       # 150k of 200k = 75%
        self.assertEqual(d["decision"], "block")
        self.assertIn("75% full", d["reason"])
        out, _ = self.hook("memory.sh", "stop", payload=p)
        self.assertEqual(out, "", "the context stop happens once per session")

    def test_precompact_asks_to_keep_the_plan(self):
        out, _ = self.hook("memory.sh", "precompact", payload={"cwd": self.memory_repo()})
        self.assertIn(".mtk/now.md", out)


# ── verify-gate.sh ──────────────────────────────────────────────────────────
class VerifyGateTest(HookCase):
    def chore_session(self, path):
        transcript = os.path.join(self.tmp, "t.jsonl")
        with open(transcript, "w") as f:
            f.write(json.dumps({"message": {"content": "<command-name>/mtk:chore</command-name>"}}) + "\n")
        return {"cwd": path, "session_id": "s1", "transcript_path": transcript}

    def test_no_chore_in_session_never_blocks(self):
        path = self.repo()
        transcript = os.path.join(self.tmp, "t.jsonl")
        open(transcript, "w").close()
        p = {"cwd": path, "session_id": "s1", "transcript_path": transcript}
        self.hook("verify-gate.sh", "base", payload=p)
        self.write(path, "README.md", "changed\n")
        out, _ = self.hook("verify-gate.sh", "stop", payload=p)
        self.assertEqual(out, "")

    def test_chore_with_no_changes_can_stop(self):
        p = self.chore_session(self.repo())
        self.hook("verify-gate.sh", "base", payload=p)
        out, _ = self.hook("verify-gate.sh", "stop", payload=p)
        self.assertEqual(out, "")

    def test_changed_files_block_until_verify_marks_them(self):
        path = self.repo()
        p = self.chore_session(path)
        self.hook("verify-gate.sh", "base", payload=p)
        self.write(path, "README.md", "changed\n")
        _, d = self.hook("verify-gate.sh", "stop", payload=p)
        self.assertEqual(d["decision"], "block")
        self.assertIn("verify.sh", d["reason"])
        self.hook("verify-gate.sh", "mark", path)              # what verify.sh calls
        out, _ = self.hook("verify-gate.sh", "stop", payload=p)
        self.assertEqual(out, "")

    def test_a_change_after_verify_blocks_again(self):
        path = self.repo()
        p = self.chore_session(path)
        self.hook("verify-gate.sh", "base", payload=p)
        self.write(path, "README.md", "changed\n")
        self.hook("verify-gate.sh", "mark", path)
        self.write(path, "new.txt", "untracked file\n")      # new untracked file = new state
        _, d = self.hook("verify-gate.sh", "stop", payload=p)
        self.assertEqual(d["decision"], "block")

    def test_gives_up_after_the_limit(self):
        path = self.repo()
        p = self.chore_session(path)
        self.hook("verify-gate.sh", "base", payload=p)
        self.write(path, "README.md", "changed\n")
        for i in range(3):
            _, d = self.hook("verify-gate.sh", "stop", payload=p)
            self.assertIn(f"block {i + 1} of 3", d["reason"])
        out, _ = self.hook("verify-gate.sh", "stop", payload=p)
        self.assertEqual(out, "", "after 3 blocks on one state the stop goes through")


# ── strikes.sh ──────────────────────────────────────────────────────────────
class StrikesTest(HookCase):
    def payload(self, cmd, exit_code=None, out=""):
        p = {"session_id": "s1", "tool_input": {"command": cmd}}
        if exit_code is not None:
            p["tool_response"] = {"exit_code": exit_code, "stdout": out}
        return p

    def check(self, cmd):
        _, d = self.hook("strikes.sh", "check", payload=self.payload(cmd))
        return d and d["hookSpecificOutput"]["permissionDecision"]

    def fail(self, cmd, out):
        self.hook("strikes.sh", "record", payload=self.payload(cmd, 1, out))

    def test_three_identical_failures_deny_the_fourth(self):
        for t in ("0.31s", "0.29s", "1.2s"):                   # timings differ, failure is the same
            self.assertIsNone(self.check("npm test"))
            self.fail("npm test", f"FAIL foo.test.js in {t}")
        self.assertEqual(self.check("npm test"), "deny")

    def test_tdd_red_green_never_denies(self):
        for i in range(3):
            self.fail("npm test", f"FAIL: expected {i} tests")
            self.hook("strikes.sh", "record", payload=self.payload("npm test", 0, "ok"))
            self.assertIsNone(self.check("npm test"))

    def test_changed_output_starts_a_new_count(self):
        self.fail("npm test", "error A")
        self.fail("npm test", "error A")
        self.fail("npm test", "error B")
        self.assertIsNone(self.check("npm test"))

    def test_a_success_clears_the_strikes(self):
        self.fail("npm test", "error A")
        self.fail("npm test", "error A")
        self.hook("strikes.sh", "record", payload=self.payload("npm test", 0, "ok"))
        self.fail("npm test", "error A")
        self.assertIsNone(self.check("npm test"))

    def test_limit_can_be_changed(self):
        self.fail("make", "boom")
        _, d = self.hook("strikes.sh", "check", payload=self.payload("make"), env={"MTK_STRIKE_LIMIT": "1"})
        self.assertEqual(d["hookSpecificOutput"]["permissionDecision"], "deny")


# ── no-writes.sh ────────────────────────────────────────────────────────────
class NoWritesTest(HookCase):
    def decision(self, cmd):
        _, d = self.hook("no-writes.sh", payload={"tool_input": {"command": cmd}})
        return d and d["hookSpecificOutput"]["permissionDecision"]

    def test_read_only_commands_pass(self):
        for cmd in ("git diff", "git log --oneline -5", "npm test", "grep -rn foo src",
                    'grep "a > b" file.txt', "npm test 2>&1 | tail", "ls >/dev/null",
                    "cat README.md", "git status --short"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.decision(cmd))

    def test_writing_commands_are_denied(self):
        for cmd in ("echo x > file", "echo x >> file", "rm -rf dist", "npm test && rm -rf dist",
                    "mv a b", "cp a b", "sed -i '' s/a/b/ f", "tee out.txt", "chmod +x f",
                    "npm install lodash", "pip install x", "git commit -m x", "git push",
                    "git reset --hard", "git checkout main", "git clean -fd", "git stash"):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.decision(cmd), "deny")

    @unittest.expectedFailure
    def test_python_write_is_denied(self):
        # Known hole, plan step 13: a deny-list cannot see a write inside python.
        self.assertEqual(self.decision("python3 -c \"open('f','w').write('x')\""), "deny")


if __name__ == "__main__":
    unittest.main()
