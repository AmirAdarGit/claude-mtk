# Spec: mtk memory (Track B item 4)

Status: built in 0.3.0. All three open questions answered "yes" (commit `.mtk/`, both files, block once).
Added on request: renamed to `/mtk:handoff`; `.mtk/log.md` episode log; a stop at 70% context;
the command always asks the user to confirm what it wrote.

## The problem, from real evidence

On 2026-11-22 a new session got "continue" and did not know the plan. The ctk
ledger was from 1 September. The automatic `handoff-latest.json` had empty
`next_steps`. The plan was found only by reading the raw transcript of the old
session.

Research (claude-forge/plugins/continuity-toolkit) shows both are by design:
- Goals and next steps are written only by `/save-state` and `/create-handoff`.
  Both are manual. No hook ever writes them.
- The PreCompact hook writes `next_steps: []` always
  (`shared/hooks-infra/src/lib/handoff-schema.ts:182`).
- SessionStart prints 3 lines from the ledger and never checks its age, so a
  3-month-old ledger looks current.

Lesson: memory that depends on someone remembering to save it is a request.
The part that can be enforced is not *writing* the memory but *noticing that
it is stale*, and *always showing it*.

## Design

### Files (in the project, under `.mtk/`)

| File | Format | Holds | Who may change what |
|---|---|---|---|
| `.mtk/now.md` | Markdown, ~40 lines max | Goal, Next (one line), Decisions (short, appended) | the model, freely |
| `.mtk/plan.json` | JSON | ordered steps: `{"id", "step", "done": false}` | the model may only flip `done` |

Why JSON for the plan: Anthropic's long-running harness article found "the model
is less likely to inappropriately change or overwrite JSON files compared to
Markdown files" (anthropic.com/engineering/effective-harnesses-for-long-running-agents).

### Hooks (all in `hooks/hooks.json`, all do nothing if `.mtk/now.md` does not exist)

| Hook | Does | Enforced? |
|---|---|---|
| SessionStart (startup, resume, clear, **compact**) | prints `now.md` in full + the open steps of `plan.json` + their age. If `now.md` is older than the last commit, prints **STALE** at the top. | yes |
| PreCompact | prints "keep Goal, the open plan steps, and Next in the summary" — its stdout becomes compaction instructions | yes (the instruction is always sent) |
| Stop | if there are commits newer than the last change to `now.md`, block once: "update .mtk/now.md: what changed, what is next". Capped, like verify-gate. | yes |
| Stop (plan) | if `plan.json` lost or renamed a step compared to `git HEAD`, block: "steps may only be marked done, not removed" | yes, via git |
| — | *what* the model writes into `now.md` is good and true | no — requested |

SessionStart output is capped by Claude Code at 10,000 characters; `now.md` stays
far below that.

### Command

`/mtk:handoff` (first named `/mtk:now`) — creates `.mtk/now.md` and `.mtk/plan.json` from a template if
missing, or updates them from the current session. This is the only manual part,
and the Stop hook asks for it when it matters.

### Not taken from ctk, on purpose

YAML handoffs, archives, heartbeat files nobody reads, PHI scrubbing, context
monitor, edit counters. Each is either never shown to the model or solves a
problem mtk does not have.

## Open questions (decide before building)

1. **Commit `.mtk/` to the repo, or keep it out of git?**
   Recommended: commit. It is versioned, it survives a new machine, and a
   teammate sees the same plan. Cost: personal notes become public in a
   public repo.
2. **Is `plan.json` worth it in v1, or only `now.md`?**
   Recommended: both. The plan is exactly what was lost today.
3. **Stop hook when commits are newer than `now.md`: block, or only remind?**
   Recommended: block once, then allow. Same pattern as verify-gate.
