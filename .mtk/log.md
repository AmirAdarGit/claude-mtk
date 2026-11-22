# Log

## 2026-11-22 — Track B items 1-4, first real use on Alta
- Done: 0.2.1 agent models, 0.2.2 /mtk:style, 0.2.3 /mtk:go, 0.2.4 verify-gate (commit 734e40a); Alta PR #100 (email_click tracking) and PR #101 (eslint ignores .claude/**, 3213 → 34 errors), both merged.
- Found on real work: chore skipped verify.sh (61 of 891 tests); the first verify-gate missed Bash/python edits; a skill-frontmatter hook never ran.
- Decided: rules move into hooks.json + git-state checks; memory in .mtk/ with /mtk:handoff (spec: specs/memory.md).
- Open: memory built and unit-tested, not yet tested in a restarted session, not committed.

## 2026-11-22 — memory tested in a restarted session, 0.3.0 shipped
- Done: a new session given only "continue" loaded .mtk/now.md and found the next step; committed and pushed 0.3.0.
- Open: step 8 (verify-gate for /mtk:develop).

## 2026-11-22 — 0.3.1: memory banner for the user
- Done: hooks/memory.sh start shows a banner (Goal, Next, plan progress, STALE) via systemMessage; full memory still goes to Claude as additionalContext (commit 00d87f3).
- Decided: copy ctk's systemMessage pattern — plain SessionStart stdout is not shown to the user.
- Open: banner tested only by running the hook by hand, not yet in a restarted session.

## 2026-11-22 — 0.3.2: hook tests (step 11)
- Done: tests/test_hooks.py, 23 tests for memory.sh, verify-gate.sh, strikes.sh, no-writes.sh; verify.sh runs unittest projects; mtk's own verify.sh: all clear.
- Checked: broke 3 hooks on purpose (banner Next line, strikes limit, tee rule) → 4 tests failed; restored.
- Open: expected failure for `python3 -c open()` in no-writes.sh (step 13); send.sh, style.sh, worktree.sh, verify.sh untested.
