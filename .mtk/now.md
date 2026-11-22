# Now

Goal: make mtk a small Claude Code harness that enforces its rules in code, built from problems found on real work (Track B of the plan).

Next: run /mtk:develop on one real Alta task and check whether gate 5 shows the full verify.sh output (step 8). Build the gate only if it does not.

## Decisions
- 2026-11-22: agents pinned to models (implementer/reviewer `sonnet`, verifier `opus`) — save limits; a different model checks the code.
- 2026-11-22: `/mtk:go` always asks before it starts a route — a wrong lane costs more than one click.
- 2026-11-22: caveman's auto-start is off (`~/.config/caveman/config.json`) — `/mtk:style short` replaces it.
- 2026-11-22: verify-gate and memory hooks live in `hooks/hooks.json`, not in skill frontmatter — the frontmatter hook never ran in a real session.
- 2026-11-22: detect changes by git state, not tool names — agents also edit through Bash/python.
- 2026-11-22: memory = `.mtk/` files committed to git; the hook decides when (commit, 70% context), Claude decides what, the user confirms.
- 2026-11-22: the start hook prints JSON: `systemMessage` (short banner) for the user, `additionalContext` (full memory) for Claude — plain stdout reaches only Claude, so users could not see the memory.
- 2026-11-22: step 8 — no verify-gate for /mtk:develop yet; test it on real work first. The current gate checks only the main folder, but develop builds in a worktree, and gate 5 already shows verify output to a human.
