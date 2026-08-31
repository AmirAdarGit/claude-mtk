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
| 5 | agents: tdd-implementer, quality-reviewer, adversarial-verifier | todo |
| 6 | remaining commands | todo |
| 7 | use it on real work, fix what annoys | todo |

## Install locally

```bash
/plugin marketplace add /Users/asdf/Documents/SHIT/arie-toolkit/mtk
/plugin install mtk@mtk-local
```

## Dependencies

None.
