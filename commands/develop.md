---
description: Run a task through the six-phase pipeline — explore, design, hypothesize, plan, build, review — with a gate between each
argument-hint: "[greenfield|brownfield|bugfix|refactor] <task or specs/file.md>"
---

# develop

Invoking skill: mtk:development-pipeline

Follow the instructions in the development-pipeline skill exactly.
Start at Phase 1. Do not skip a gate.

If the first word of the arguments is `greenfield`, `brownfield`, `bugfix` or
`refactor`, that is the mode. Otherwise pick the mode from the task and state it
at gate 1.

$ARGUMENTS
