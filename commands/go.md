---
description: One entry point — reads the task, picks spec, chore, or a develop mode, and asks you to confirm before starting
argument-hint: "<task, or specs/file.md>"
---

# go

The task is:

$ARGUMENTS

If the task is empty, ask what the task is, in one line, and stop.

## 1. Pick a route

Use the first row that matches. Read the task only. Do not explore the code yet;
the chosen command does that.

| The task is... | Route |
|---|---|
| a path to `specs/*.md` | `/mtk:develop <that path>` |
| an idea, and it is not clear what to build | `/mtk:spec` |
| small (1–2 files), and the way to do it is already clear | `/mtk:chore` |
| something broken: a bug, an error, a failing test | `/mtk:develop bugfix` |
| the same behaviour with cleaner code | `/mtk:develop refactor` |
| a new feature or change in code that already exists | `/mtk:develop brownfield` |
| a new project, or an empty repo | `/mtk:develop greenfield` |
| none of these, or you are unsure | `/mtk:develop` |

If two rows match, prefer the bigger lane: develop over chore, spec over develop
when the goal itself is unclear. A wrong small lane costs more than a few extra
questions.

## 2. Ask. Always.

Show one line: the route and the reason, e.g.
`Route: /mtk:develop bugfix — the task says the export "fails on empty input".`

Then call `AskUserQuestion`. The first option is your pick, marked
"(Recommended)". Add the one or two next-best routes from the table, each with a
one-line reason. The user can always type something else.

Do not start any command before the answer arrives. Do not treat silence, or a
reply that is not an answer, as a yes. This gate runs in the main session, so it
can ask; if `AskUserQuestion` is not available, stop and print the question
instead of choosing.

## 3. Hand off

Run the chosen command with the original task text as its argument, and follow
that command exactly. `/mtk:go` adds nothing after this point.
