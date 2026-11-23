---
description: Save the project memory — goal, next step, plan steps, and a short log of this episode — so the next session starts with it
argument-hint: "[optional: what changed]"
---

# handoff

The project memory is three files at the repo root. Every new session, and every
compaction, shows them automatically (hooks/memory.sh). They must be true.

**The repo root is the MAIN folder, even when this session runs in a worktree.**
Find it first, and read and write `.mtk/` only there, then commit there:

```bash
ROOT=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
```

A worktree has its own copy of `.mtk/` on a side branch. The next session opens
on the main folder and would never see a handoff written into that copy.

| File | Holds |
|---|---|
| `.mtk/now.md` | Goal, the one Next step, short Decisions |
| `.mtk/plan.json` | the steps, each `{"id", "step", "done"}` |
| `.mtk/log.md` | one short entry per episode: what was done, what was decided |

$ARGUMENTS

## 1. Read before you write

Run `git log --oneline -15` and read the three files if they exist. Use this
session's conversation as the main source: features finished, bugs fixed, PRs,
decisions and their reasons, things that failed, what is half done.

## 2. Write

**If the files do not exist, create them:**

`.mtk/now.md`

```markdown
# Now

Goal: <one sentence: what this project is doing now, and why>

Next: <one step, concrete enough to start without asking>

## Decisions
- YYYY-MM-DD: <what was chosen> — <why, in one line>
```

`.mtk/plan.json`

```json
{
  "steps": [
    { "id": 1, "step": "<one step>", "done": false }
  ]
}
```

`.mtk/log.md` starts with `# Log` and then the first entry.

**If they exist, update them:**

1. `now.md` — rewrite **Goal** only if it changed. Always rewrite **Next**. Add
   to **Decisions** what was decided and is not written yet. Keep the file under
   40 lines; drop old decisions that no longer matter (they stay in `log.md` and git).
2. `plan.json` — set `"done": true` only for steps that are finished and checked.
   Add new steps at the end with the next free `id`. **Never remove or rename a
   step** — a Stop hook compares the file with git HEAD and blocks. A step that is
   no longer needed: mark it done and say why in Decisions.
3. `log.md` — append ONE entry for this episode, at the bottom:

   ```markdown
   ## YYYY-MM-DD — <short title>
   - Done: <features, fixes, PRs — with numbers and file names>
   - Decided: <decision — why>
   - Open: <what is half done or broken>
   ```

   At most 6 lines. Facts a later session can act on, not a diary.

## 3. Check — memory-checker

Claude often writes wrong facts. Check the draft against git before the user sees it.

1. Dispatch the `mtk:memory-checker` agent. It is read-only. It labels every added line
   `OK`, `WRONG`, `OLD` or `CANNOT CHECK`, with proof. The agent cannot know the plugin
   folder, so the brief must hold two things: `ROOT`, and the script path written
   literally as `${CLAUDE_PLUGIN_ROOT}/scripts/memcheck.sh` (Claude Code fills in the real
   path). Example brief:

   ```text
   Check the draft .mtk/ lines.
   ROOT: <the main folder path>
   Script: ${CLAUDE_PLUGIN_ROOT}/scripts/memcheck.sh
   ```
2. Show its `WRONG` and `OLD` lines.
3. Fix each `WRONG` and `OLD` line in the files, or remove it. Then dispatch the agent again once,
   and show the new labels.
4. Show the `CANNOT CHECK` lines to the user as "only you can check these".

If the agent cannot be dispatched, say so in one line and go on to the next section.

## 4. Ask the user — always

Show the new **Goal**, **Next**, the plan steps you marked done, and the new log
entry, together with the labels from the check. Then call `AskUserQuestion`:

- "Correct — keep it" (Recommended)
- "Something is missing or wrong" — then ask what, fix it, and ask again

You wrote this from your own view of the session. The user is the only check that
it is complete. Do not skip this question.

## 5. Then

Show `git diff --stat -- .mtk/`. Do not commit: these files are committed with
the user's next commit, like any other file.

If this handoff was asked for because the context is full, end with one line:
"Memory saved. Run `/clear` — the next session will show it automatically."

## Rules

- Write facts, not hopes. "Tests pass" only if a check you ran in this session says so.
- No secrets, no personal data. `.mtk/` is committed to the repo.
