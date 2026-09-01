# mtk — my toolkit

A development pipeline with gates that actually stop and ask.

Forked down from [claude-forge/etk](https://github.com/ArieGoldkin/claude-forge)
(27 skills / 5 agents / 21 commands) to something one person can read in a sitting.

## Two lanes

Pick by size. Small and you already know how -> chore. Anything else -> develop.

```
/mtk:chore     small job    do it -> verify -> show diff
/mtk:develop   real work    explore -> plan -> build -> review, with gates
```

If you are unsure which, use `develop`. Two minutes of questions beats an
afternoon of the wrong thing.

## The pipeline

```
  EXPLORE  →|  PLAN  →|  BUILD  →|  REVIEW
           gate      gate       gate
```

Each gate scores the task, states its assumptions, and **asks**. It does not
run in a forked context, because a gate that cannot ask a question is not a gate.

## Status

| Step | | |
|---|---|---|
| 1 | scaffold + manifest | done |
| 2 | `verify` skill | done |
| 3 | `quality-gates` skill | done |
| 4 | `development-pipeline` — 4 phases | done |
| 5 | agents: tdd-implementer, quality-reviewer, adversarial-verifier | done |
| 6 | remaining commands | done |
| 7 | use it on real work, fix what annoys | ongoing |

## Install locally

```bash
/plugin marketplace add /path/to/mtk
/plugin install mtk@mtk-local
```

## verify.sh

`scripts/verify.sh` runs the checks. The skill reads its exit code; it does not
re-run them by hand.

```bash
./scripts/verify.sh --dir ../some-project --json
```

`0` all clear · `1` warnings only · `2` failures · `3` blocked.

The script reports facts (which checks ran, exit codes, counts per lint rule).
It does not decide which findings matter -- that needs reading the code, and
belongs to the skill.

## worktree.sh

BUILD never edits your folder. It gets a disposable copy on its own branch.

```bash
./scripts/worktree.sh new  fix-lint    # -> ../<repo>-mtk-fix-lint on branch mtk/fix-lint
./scripts/worktree.sh diff fix-lint    # what changed, vs where it came from
./scripts/worktree.sh drop fix-lint    # folder gone, branch + commits kept
./scripts/worktree.sh drop fix-lint --purge   # both gone
```

Removing the folder is not removing the work -- the branch keeps the commits,
and `new` with the same slug brings the folder back. All local; no network.

## Observability (optional, off-able)

`scripts/event.sh` posts phase and gate events to a local server, so a run shows
up as a timeline next to the Claude Code hook events. `verify.sh` and
`worktree.sh` call it themselves.

```bash
./scripts/obs.sh status     # on/off, size, event count
./scripts/obs.sh stats      # runs, gates, verify history, tool use
./scripts/obs.sh prune 30   # delete anything older than 30 days
./scripts/obs.sh off        # stop recording
```

Roughly 3.5 KB per event, measured. Nothing reads this log automatically -- not
Claude, not the agents. It is worth keeping only while `stats` is being read.
`off` is the honest choice otherwise.

Server: https://github.com/disler/claude-code-hooks-multi-agent-observability

## Dependencies

None.
