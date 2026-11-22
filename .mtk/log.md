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
- Fixed: baa0df8 committed tests/__pycache__/*.pyc by mistake; 77008a8 removes it and ignores __pycache__/
- Open: expected failure for `python3 -c open()` in no-writes.sh (step 13); send.sh, style.sh, worktree.sh, verify.sh untested.

## 2026-11-22 — 0.3.3: optimize rule (step 14)
- Done: tests/test_budget.py — every hook within a time and output budget on a 20 MB transcript; a wired hook without a budget fails. README "The optimize rule".
- Fixed: memory STALE looked only at now.md; now any .mtk/ file counts (test failed first).
- Decided: no transcript cache in verify-gate.sh — measured 0.02 s saved per tool call, not worth the code.
- Open: memory.sh still guesses the context window size from the model name.

## 2026-11-22 — 0.3.4: /mtk:doctor (step 12)
- Done: heartbeat line in all 6 hooks (~/.mtk/beat/); scripts/doctor.sh + commands/doctor.md; tests/test_doctor.py (8 tests, 3 failed when the code was broken on purpose). 35 tests, verify.sh: all clear.
- Found: hooks run straight from the source folder (directory marketplace); the registry's 0.2.2 is a stale number.
- Open: run /mtk:doctor in a new session — memory.sh start, style.sh and the Stop hooks show OK only after they run once.

## 2026-11-22 — 0.3.5: no-writes and strikes really run (step 13, not yet tested live)
- Found: heartbeats showed no-writes.sh and strikes.sh never ran — Claude Code ignores `hooks:` in plugin agents' frontmatter; a probe showed hook input inside an agent has agent_type.
- Done: both hooks in hooks.json, filtered by agent_type; no-writes.sh also checks git files after each reviewer command (catches python3 -c writes); dead frontmatter hooks removed; 40 tests, verify.sh all clear.
- Open: live test needs a new session (hooks.json loads at session start); step 13 stays open until it passes.
## 2026-11-22 — step 13 live test passed
- Checked: in a new session, the mtk:quality-reviewer ran `python3 -c open()`; no-writes.sh after blocked it and named nw-probe.txt. `rm nw-probe2.txt` was denied before it ran; the file stayed.
- Checked: /mtk:doctor all OK; no-writes.sh and strikes.sh ran in both modes.
- Note: after a write block, the agent stops and does not run later commands, so test each rule in its own run.
## 2026-11-22 — 0.3.6: plain-English style
- Done: hooks/style.sh short and full now ask for plain, simple English (short sentences, common words, no idioms); README updated; 369 chars, under the 600 budget; verify.sh all clear (commit 4d6a19e).
- Decided: step 8 tests /mtk:develop on a new AI practice project, not Alta. Proposed "Dev Brain" (Arie's "Company Brain" idea).
- Open: project and language not chosen yet.
## 2026-11-22 — 0.3.7: develop uses the agents
- Found: skills/development-pipeline/SKILL.md never dispatched tdd-implementer, quality-reviewer or adversarial-verifier; only /mtk:review and /mtk:refute did.
- Done: BUILD dispatches tdd-implementer per plan step (absolute $WT, commit each green step); REVIEW dispatches quality-reviewer, then adversarial-verifier with Done-means claims; blocking finding → back to BUILD; fallback when agents are missing; README + tdd-implementer boundary. verify.sh all clear.
- Open: not yet run for real — the step 8 test on Dev Brain is the first run. Risk: no-writes.sh checks git state in the session cwd, not in $WT, so a reviewer write inside the worktree is not caught by the "after" check.
