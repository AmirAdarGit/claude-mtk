# Now

Goal: make mtk a small Claude Code harness that enforces its rules in code, built from problems found on real work (Track B of the plan).

Next: discuss and build the new agent ideas (plan steps 15-18), memory-checker first. Evidence from 2026-11-23: 3 Dev Brain handoffs each had wrong lines; two gate-4 plans had risky actions (Atlas creation via MCP, Alta data to Voyage). Step 8 (Dev Brain test) continues in the Dev Brain session.

## Decisions
- 2026-11-22: agents pinned to models (implementer/reviewer `sonnet`, verifier `opus`) — save limits; a different model checks the code.
- 2026-11-22: `/mtk:go` always asks before it starts a route — a wrong lane costs more than one click.
- 2026-11-22: caveman's auto-start is off (`~/.config/caveman/config.json`) — `/mtk:style short` replaces it.
- 2026-11-22: verify-gate and memory hooks live in `hooks/hooks.json`, not in skill frontmatter — the frontmatter hook never ran in a real session.
- 2026-11-22: detect changes by git state, not tool names — agents also edit through Bash/python.
- 2026-11-22: memory = `.mtk/` files committed to git; the hook decides when (commit, 70% context), Claude decides what, the user confirms.
- 2026-11-22: the start hook prints JSON: `systemMessage` (short banner) for the user, `additionalContext` (full memory) for Claude — plain stdout reaches only Claude, so users could not see the memory.
- 2026-11-22: step 8 — no verify-gate for /mtk:develop yet; test it on real work first. The current gate checks only the main folder, but develop builds in a worktree, and gate 5 already shows verify output to a human.
- 2026-11-22: plan steps 11-13 added (hook tests, /mtk:doctor, no-writes by git state) — from problems seen today: verify.sh cannot check mtk itself, a cached plugin copy can run old hooks, `python3 -c open()` passes no-writes.sh.
- 2026-11-22: hook tests use stdlib unittest, not pytest — nothing to install; verify.sh runs `tests/test_*.py` with unittest when there is no pytest config.
- 2026-11-22: optimize rule — every hook has a budget test (time, output size) in tests/test_budget.py, and a wired hook without a budget fails; measure before optimizing (a verify-gate transcript cache saved 0.02 s, so it was not kept).
- 2026-11-22: /mtk:doctor trusts heartbeats, not the plugin registry — every hook writes ~/.mtk/beat/<script>-<mode> with its folder; the registry said 0.2.2 while hooks ran 0.3.3 from the source folder (directory marketplace).
- 2026-11-22: no-writes.sh and strikes.sh moved from agents/*.md frontmatter to hooks.json, filtered by the hook input's agent_type — heartbeats showed Claude Code never ran plugin-agent frontmatter hooks, so neither rule was ever enforced.
- 2026-11-22: /mtk:style short and full ask for plain, simple English — the user reads English as a second language; technical words stay exact.
- 2026-11-22: step 8 runs on a new practice project, not Alta — the user wants to practice AI agents and RAG.
- 2026-11-22: /mtk:develop dispatches the agents (BUILD → tdd-implementer, REVIEW → quality-reviewer then adversarial-verifier) — before 0.3.7 the main session wrote and graded its own code, so the model split and no-writes.sh never applied in develop.
- 2026-11-23: /mtk:develop needs no verify-gate (step 8 closed) — in 3 Dev Brain runs (spike, slice 1, slice 2) gate 5 ran verify.sh in the worktree every time and showed the output; the verify-gate stays for /mtk:chore only.
