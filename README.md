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
/plugin marketplace add AmirAdarGit/claude-mtk
/plugin install mtk@mtk
```

Or from a local clone:

```bash
/plugin marketplace add /path/to/claude-mtk
/plugin install mtk@mtk
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

## Read-only agents are actually read-only

`quality-reviewer` and `adversarial-verifier` both hold `Bash`, because they need it to run
tests, lint, and `git diff`. `disallowedTools: [Write, Edit]` blocks tools by NAME, and Bash
is not named Write -- so `echo x > file` wrote anyway. The label was documentation, not
enforcement.

`hooks/no-writes.sh` is the enforcement: a `PreToolUse` hook on those two agents that reads
`tool_input.command` and denies redirects, `rm`, `mv`, `cp`, `sed -i`, `tee`, `chmod`,
`git checkout/reset/clean/commit/push`, and package installs. Everything else runs.

It is a deny-list, which is a fence and not a vault: `python3 -c "open('f','w')..."` has no
`>` and gets through. An allow-list would be airtight and would break the agents the first
time they needed a command nobody listed. This side of the trade-off keeps them working.

`tdd-implementer` has no such hook -- writing is its job.

## The 3-strikes rule is enforced, not requested

`development-pipeline` says "three failed attempts at the same step = STOP". That lived in a
markdown file, with the agent counting its own failures -- a counter inside the thing it counts
is a suggestion, not a limit.

`hooks/strikes.sh` moves it into code. `PostToolUse` and `PostToolUseFailure` record every Bash
result; `PreToolUse` denies a command that has already failed three times **with the same
result**.

Command *and result*, deliberately. In TDD a failing test is the goal, so counting failures per
command would block `tdd-implementer` on its own first RED step. Stuck means no progress: the
same command, the same failure, again. Timings, dates, temp paths and hex ids are normalised out
first, so two identical failures are recognised as identical. A success clears every strike for
that command.

State lives in `~/.mtk/strikes/<session>.tsv` and is deleted after a day.
`MTK_STRIKE_LIMIT` changes the number.

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

## Observability (ships with mtk, OFF by default)

`scripts/event.sh` posts phase and gate events to a local server, so a run shows
up as a timeline next to the Claude Code hook events. `verify.sh` and
`worktree.sh` call it themselves.

```bash
./scripts/obs.sh on         # start recording  (nothing records until you do this)
./scripts/obs.sh status     # on/off, size, event count
./scripts/obs.sh stats      # runs, gates, verify history, tool use
./scripts/obs.sh prune 30   # delete anything older than 30 days
./scripts/obs.sh off        # stop
```

**One switch: `~/.mtk/obs-on`.** It does not exist until you run `obs.sh on`, so
installing mtk records nothing. `off` deletes it, and both `hooks/send.sh` and
`scripts/event.sh` check for it before doing anything.

`hooks/hooks.json` covers 9 lifecycle events -- session start/end, prompts,
every tool call, tool failures, and subagent start/stop. Only small fields are
sent: tool name, a short description, the project folder name. Never file
contents, never full command text.

Recording needs a local server listening on `http://localhost:4000/events`:
https://github.com/disler/claude-code-hooks-multi-agent-observability
With no server running, every send times out in 2s and is discarded.

Roughly 3.5 KB per event, measured. Nothing reads this log automatically -- not
Claude, not the agents. It is worth keeping only while `stats` is being read.

## Dependencies

None.
