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

    def test_start_in_a_worktree_shows_the_main_folder_memory(self):
        # Seen live (step 8, Dev Brain): a session ran in a Claude Code worktree, so
        # the memory it read and the handoff it wrote were an old copy on a side branch.
        main = self.memory_repo()
        wt = os.path.join(self.tmp, "wt")
        self.git(main, "worktree", "add", "-q", "-b", "side", wt)
        self.write(main, ".mtk/now.md", NOW.replace("write one test", "the newer next step"))
        _, d = self.hook("memory.sh", "start", payload={"cwd": wt})
        self.assertIn("Next: the newer next step", d["systemMessage"])

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

    def test_a_handoff_that_changes_only_the_log_is_not_stale(self):
        path = self.memory_repo()
        self.write(path, "code.py", "x = 1\n")
        self.commit(path, "code")
        with open(os.path.join(path, ".mtk/log.md"), "a") as f:
            f.write("\n## 2026-11-23 — second\n- Done: y\n")
        self.commit(path, "handoff: log only")
        _, d = self.hook("memory.sh", "start", payload={"cwd": path})
        self.assertNotIn("STALE", d["systemMessage"])
        out, _ = self.hook("memory.sh", "stop", payload={"cwd": path, "session_id": "s1"})
        self.assertEqual(out, "")

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

    def test_a_chore_started_later_is_still_seen(self):
        # verify-gate reads only the new part of the transcript each time.
        # A chore that starts after earlier reads must still turn the gate on.
        path = self.repo()
        transcript = os.path.join(self.tmp, "t.jsonl")
        with open(transcript, "w") as f:
            f.write(json.dumps({"message": {"content": "hello"}}) + "\n")
        p = {"cwd": path, "session_id": "s1", "transcript_path": transcript}
        self.hook("verify-gate.sh", "base", payload=p)          # no chore yet
        with open(transcript, "a") as f:
            f.write(json.dumps({"message": {"content": "<command-name>/mtk:chore</command-name>"}}) + "\n")
        self.hook("verify-gate.sh", "base", payload=p)          # chore now: baseline
        self.write(path, "README.md", "changed\n")
        _, d = self.hook("verify-gate.sh", "stop", payload=p)
        self.assertEqual(d["decision"], "block")

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
    def payload(self, cmd, exit_code=None, out="", agent="mtk:tdd-implementer"):
        p = {"session_id": "s1", "tool_input": {"command": cmd}}
        if agent:
            p["agent_type"] = agent
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

    def test_memory_checker_failures_are_counted(self):
        for _ in range(3):
            self.hook("strikes.sh", "record", payload=self.payload("make", 1, "boom", agent="mtk:memory-checker"))
        _, d = self.hook("strikes.sh", "check", payload=self.payload("make", agent="mtk:memory-checker"))
        self.assertEqual(d["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_your_own_commands_are_never_counted(self):
        for _ in range(4):
            self.hook("strikes.sh", "record", payload=self.payload("npm test", 1, "FAIL", agent=None))
        _, d = self.hook("strikes.sh", "check", payload=self.payload("npm test", agent=None))
        self.assertIsNone(d)

    def test_limit_can_be_changed(self):
        self.fail("make", "boom")
        _, d = self.hook("strikes.sh", "check", payload=self.payload("make"), env={"MTK_STRIKE_LIMIT": "1"})
        self.assertEqual(d["hookSpecificOutput"]["permissionDecision"], "deny")


# ── no-writes.sh ────────────────────────────────────────────────────────────
class NoWritesTest(HookCase):
    def payload(self, cmd, agent="mtk:quality-reviewer", cwd=None):
        p = {"session_id": "s1", "agent_id": "a1", "tool_input": {"command": cmd}, "cwd": cwd or self.tmp}
        if agent:
            p["agent_type"] = agent
        return p

    def decision(self, cmd, agent="mtk:quality-reviewer"):
        _, d = self.hook("no-writes.sh", payload=self.payload(cmd, agent))
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

    def test_heredoc_body_is_data_not_shell(self):
        # Seen live (step 8, Dev Brain): a reviewer piped TypeScript with => and >= into
        # node through a heredoc and was denied as a "> redirect".
        cmd = ("cat <<'EOF' | node --input-type=module\n"
               "const fl=()=>{if(size>=700)flush()}\n"
               "EOF")
        self.assertIsNone(self.decision(cmd))
        unquoted = "cat <<EOF | node\nconst f=(a)=>a>=1\nEOF\n"
        self.assertIsNone(self.decision(unquoted))

    def test_a_write_after_a_heredoc_is_still_denied(self):
        cmd = "cat <<'EOF' > out.txt\nhello\nEOF"
        self.assertEqual(self.decision(cmd), "deny")
        cmd = "cat <<'EOF' | node\nx=>1\nEOF\necho done > out.txt"
        self.assertEqual(self.decision(cmd), "deny")

    def test_both_reviewer_agents_are_read_only(self):
        self.assertEqual(self.decision("rm x", agent="mtk:adversarial-verifier"), "deny")

    def test_memory_checker_is_read_only(self):
        self.assertEqual(self.decision("echo x > file", agent="mtk:memory-checker"), "deny")
        self.assertEqual(self.decision("rm x", agent="mtk:memory-checker"), "deny")
        self.assertIsNone(self.decision("git diff HEAD -- .mtk/", agent="mtk:memory-checker"))

    def test_other_agents_and_your_own_commands_are_not_touched(self):
        self.assertIsNone(self.decision("rm x", agent="mtk:tdd-implementer"))
        self.assertIsNone(self.decision("rm x", agent=None))

    def test_a_hidden_python_write_is_caught_after_the_command(self):
        # The old hole: no redirect, no rm -- the deny-list lets it through.
        path = self.repo()
        cmd = "python3 -c \"open('f','w').write('x')\""
        p = self.payload(cmd, cwd=path)
        out, _ = self.hook("no-writes.sh", payload=p)
        self.assertEqual(out, "", "the deny-list cannot see this write")
        self.write(path, "f", "x")                              # what the command did
        _, d = self.hook("no-writes.sh", "after", payload=p)
        self.assertEqual(d["decision"], "block")
        self.assertIn("changed files: f", d["reason"])
        out, _ = self.hook("no-writes.sh", "after", payload=p)
        self.assertEqual(out, "", "each change is reported once")

    def test_a_change_to_a_tracked_file_is_caught(self):
        path = self.repo()
        p = self.payload("node -e \"require('fs').writeFileSync('README.md','x')\"", cwd=path)
        self.hook("no-writes.sh", payload=p)
        self.write(path, "README.md", "changed by node\n")
        _, d = self.hook("no-writes.sh", "after", payload=p)
        self.assertIn("README.md", d["reason"])

    def test_a_read_only_command_changes_nothing(self):
        path = self.repo()
        self.write(path, "dirty.txt", "the user's own work in progress\n")   # already dirty: not the agent's
        p = self.payload("git diff", cwd=path)
        self.hook("no-writes.sh", payload=p)
        out, _ = self.hook("no-writes.sh", "after", payload=p)
        self.assertEqual(out, "")


# ── agents/memory-checker.md ────────────────────────────────────────────────
class MemoryCheckerAgentTest(unittest.TestCase):
    def frontmatter(self):
        with open(os.path.join(ROOT, "agents", "memory-checker.md")) as f:
            text = f.read()
        head = text.split("---")[1]
        return dict(l.split(":", 1) for l in head.strip().splitlines() if ":" in l and not l.startswith(" "))

    def test_model_and_tools(self):
        fm = self.frontmatter()
        self.assertEqual(fm["name"].strip(), "memory-checker")
        self.assertEqual(fm["model"].strip(), "sonnet")
        tools = [t.strip() for t in fm["tools"].split(",")]
        self.assertEqual(tools, ["Read", "Bash", "Grep", "Glob"])
        for banned in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
            self.assertNotIn(banned, tools)
            self.assertIn(banned, fm["disallowedTools"])


if __name__ == "__main__":
    unittest.main()


# ── secret-guard.sh ─────────────────────────────────────────────────────────
class SecretGuardTest(HookCase):
    def decision(self, cmd, agent=None):
        p = {"session_id": "s1", "tool_input": {"command": cmd}, "cwd": self.tmp}
        if agent:
            p["agent_type"] = agent
        _, d = self.hook("secret-guard.sh", payload=p)
        return d and d["hookSpecificOutput"]["permissionDecision"]

    def test_commands_that_print_a_secret_are_denied(self):
        for cmd in (
            "cat .env", "head -5 .env", "tail .env.local", "sed -n 1,5p .env",
            "cut -d= -f1 .env",                     # the 2026-11-23 leak: a line with no '='
            "grep MONGODB .env", "awk -F= '{print $1}' ../dev-brain/.env",
            "cd /x && cat .env | head", "echo $MONGODB_URI", 'echo "${VOYAGE_API_KEY}"',
            "printf '%s' $DB_PASSWORD", "printenv", "env", "printenv OPENAI_API_KEY",
            "while read l; do echo $l; done < .env",
            "python3 -c \"print(open('.env').read())\"",
            "node --env-file=.env -e 'console.log(process.env.MONGODB_URI)'",
        ):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.decision(cmd), "deny")

    def test_checks_that_print_no_value_pass(self):
        for cmd in (
            "grep -c '^MONGODB_URI=' .env", "grep -q VOYAGE .env && echo yes",
            "test -f .env", "ls -la .env", "cat .env.example", "cp .env.example .env",
            "ln -s ../dev-brain/.env .env", "node --env-file=.env dist/cli.js search x",
            "echo $HOME", "echo hello", "env FOO=1 npm test", "git status", "npm test",
            "source .env && npm run test:int",
        ):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.decision(cmd))

    def test_it_guards_agents_too(self):
        self.assertEqual(self.decision("cat .env", agent="mtk:tdd-implementer"), "deny")

    def test_it_can_be_turned_off(self):
        _, d = self.hook("secret-guard.sh", payload={"tool_input": {"command": "cat .env"}},
                         env={"MTK_SECRET_GUARD": "off"})
        self.assertIsNone(d)
