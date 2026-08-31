# mtk — my toolkit

A development pipeline with gates that actually stop and ask.

Forked down from [claude-forge/etk](https://github.com/ArieGoldkin/claude-forge)
(27 skills / 5 agents / 21 commands) to something one person can read in a sitting.

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
/plugin marketplace add /Users/asdf/Documents/SHIT/arie-toolkit/mtk
/plugin install mtk@mtk-local
```

## verify.sh

`scripts/verify.sh` runs the checks. The skill reads its exit code; it does not
re-run them by hand.

```bash
./scripts/verify.sh --dir ../SomeProject --json
```

`0` all clear · `1` warnings only · `2` failures · `3` blocked.

The script reports facts (which checks ran, exit codes, counts per lint rule).
It does not decide which findings matter -- that needs reading the code, and
belongs to the skill.

## Dependencies

None.
