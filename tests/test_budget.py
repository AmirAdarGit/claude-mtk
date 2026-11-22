"""Budget tests: every hook must stay fast and small.

THE RULE (see README "The optimize rule"): every tool in mtk has a budget.
Hooks run on every prompt, every tool call, or every stop, so a slow hook slows
every step, and a hook's output is paid for in tokens on every turn it is added.

Each hook runs here in its WORST realistic case: a long session transcript
(MTK_TEST_TRANSCRIPT_MB, default 20 MB), a chore in that session, big memory
files. It must finish within its time budget and print no more than its output
budget.

test_every_wired_hook_has_a_budget makes the rule hold for new hooks too: a
script wired in hooks/hooks.json or agents/*.md without a row in BUDGETS fails.
"""

import glob
import json
import os
import re
import time
import unittest

from test_hooks import HookCase, ROOT

# (script, mode) -> (max seconds, max output characters)
BUDGETS = {
    ("memory.sh", "start"):      (1.0, 12_000),   # once per session; ~3k tokens at most
    ("memory.sh", "stop"):       (1.0, 2_000),
    ("memory.sh", "precompact"): (1.0, 1_000),
    ("verify-gate.sh", "base"):  (1.0, 0),        # runs before EVERY tool call
    ("verify-gate.sh", "stop"):  (1.0, 1_000),
    ("strikes.sh", "check"):     (0.5, 1_000),    # before every Bash call of an agent
    ("strikes.sh", "record"):    (0.5, 0),
    ("no-writes.sh", None):      (0.5, 1_000),
    ("style.sh", None):          (0.5, 600),      # added to EVERY prompt
    ("send.sh", "*"):            (0.5, 0),
}

MB = int(os.environ.get("MTK_TEST_TRANSCRIPT_MB", "20"))


class BudgetTest(HookCase):
    def setUp(self):
        super().setUp()
        self.path = self.repo()
        # Big memory files: the start hook must cut them, not pass them all on.
        self.write(self.path, ".mtk/now.md",
                   "# Now\n\nGoal: g\n\nNext: n\n\n## Decisions\n" + "- 2026-11-22: decision line\n" * 2000)
        self.write(self.path, ".mtk/plan.json", json.dumps(
            {"steps": [{"id": i, "step": f"step {i} " + "x" * 80, "done": i < 50} for i in range(200)]}))
        self.write(self.path, ".mtk/log.md",
                   "# Log\n" + "".join(f"\n## 2026-11-{i % 28 + 1:02d} — e{i}\n- Done: " + "y" * 300 + "\n"
                                        for i in range(300)))
        self.commit(self.path, "memory")
        # A long session that ran a chore near the start (worst case for verify-gate).
        self.transcript = os.path.join(self.tmp, "t.jsonl")
        line = json.dumps({"type": "assistant", "message": {"model": "claude-sonnet",
                           "content": [{"type": "text", "text": "z" * 2000}],
                           "usage": {"input_tokens": 1000}}}) + "\n"
        with open(self.transcript, "w") as f:
            f.write(json.dumps({"message": {"content": "<command-name>/mtk:chore</command-name>"}}) + "\n")
            f.write(line * (MB * 1_000_000 // len(line)))
        os.makedirs(os.path.join(self.home, ".mtk"))
        with open(os.path.join(self.home, ".mtk", "style"), "w") as f:
            f.write("short")

    def payload(self):
        return {"cwd": self.path, "session_id": "budget", "transcript_path": self.transcript,
                "tool_input": {"command": "npm test"},
                "tool_response": {"exit_code": 1, "stdout": "FAIL"}}

    def measure(self, script, mode):
        args = [] if mode in (None, "*") else [mode]
        if script == "send.sh":
            args = ["Stop"]
        best, out = None, ""
        for _ in range(3):                          # best of 3: ignore one slow start
            t = time.perf_counter()
            out, _ = self.hook(script, *args, payload=self.payload())
            took = time.perf_counter() - t
            best = took if best is None else min(best, took)
        return best, out

    def test_each_hook_within_budget(self):
        for (script, mode), (max_s, max_chars) in BUDGETS.items():
            with self.subTest(hook=f"{script} {mode or ''}".strip()):
                took, out = self.measure(script, mode)
                self.assertLessEqual(took, max_s, f"took {took:.2f}s, budget {max_s}s")
                self.assertLessEqual(len(out), max_chars, f"printed {len(out)} chars, budget {max_chars}")

    def test_every_wired_hook_has_a_budget(self):
        wired = set()
        with open(os.path.join(ROOT, "hooks", "hooks.json")) as f:
            for m in re.finditer(r"hooks/([\w-]+\.sh)(?: (\w+))?", f.read()):
                wired.add((m.group(1), m.group(2)))
        for agent in glob.glob(os.path.join(ROOT, "agents", "*.md")):
            with open(agent) as f:
                for m in re.finditer(r"hooks/([\w-]+\.sh)(?: (\w+))?", f.read()):
                    wired.add((m.group(1), m.group(2)))
        self.assertTrue(wired)
        for script, mode in sorted(wired, key=str):
            with self.subTest(hook=f"{script} {mode or ''}".strip()):
                self.assertTrue((script, mode) in BUDGETS or (script, "*") in BUDGETS,
                                f"{script} {mode or ''} is wired but has no budget in tests/test_budget.py")


if __name__ == "__main__":
    unittest.main()
