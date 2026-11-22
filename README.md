# mtk — my toolkit

A development pipeline with gates that actually stop and ask.

Forked down from [claude-forge/etk](https://github.com/ArieGoldkin/claude-forge)
(27 skills / 5 agents / 21 commands) to something one person can read in a sitting.

## Three entry points

Not sure which one? `/mtk:go "<task>"` picks it for you, shows the reason, and asks
you to confirm before anything starts. The pick is the model's judgment; your click
is the check.

```
/mtk:go        not sure which         pick a route -> ask you -> run it
/mtk:handoff   save the memory        goal, next step, plan, episode log -> .mtk/
/mtk:spec      an idea, no task yet   ask -> write specs/<name>.md
/mtk:chore     small, you know how    do it -> verify -> show diff
/mtk:develop   real work              explore -> design -> hypothesize -> plan -> build -> review, with gates
```

`/mtk:spec` leaves a **file**, not a conversation. It is versioned, it survives the
session, it can be argued with in a PR, and `/mtk:develop specs/x.md` takes it as
input. A design that lives only in chat has to be re-explained to the next agent.

## Two lanes

Pick by size. Small and you already know how -> chore. Anything else -> develop.

```
/mtk:chore     small job    do it -> verify -> show diff
/mtk:develop   real work    six phases, with a gate after each
```

If you are unsure which, use `develop`. Two minutes of questions beats an
afternoon of the wrong thing.

## The pipeline

```
  EXPLORE →| DESIGN →| HYPOTHESIZE →| PLAN →| BUILD →| REVIEW →| decide
          g1        g2             g3      g4       g5        merge · keep · leave · discard
```

Each gate scores the task, states its assumptions, and **asks**. It does not
run in a forked context, because a gate that cannot ask a question is not a gate.

DESIGN chooses between two approaches. HYPOTHESIZE names the one assumption the
chosen approach depends on, what would prove it false, and what done means. Both
come from `etk:development-pipeline`; here each has a gate that can ask.

### Modes

The first word of the arguments picks how much of the pipeline runs. With no
word, the pipeline picks one and states it at gate 1, where you can change it.

```
/mtk:develop greenfield "..."   new code               all six phases
/mtk:develop brownfield "..."   change existing code   all six, shorter design
/mtk:develop bugfix "..."       something is broken    skips DESIGN and HYPOTHESIZE
/mtk:develop refactor "..."     same behaviour         characterization tests first
```

`/mtk:develop specs/x.md` still works. A spec that already has an Approach is
checked in DESIGN, not redone.

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
| 8 | pipeline grows to 6 phases: DESIGN, HYPOTHESIZE, and four task modes | done, not yet run on real work |
| 9 | each agent pinned to a model and effort | done |

## Models

Each agent names its own model, so a subagent never silently runs on whatever
expensive model the main session happens to use.

| Agent | model | effort | why |
|---|---|---|---|
| `tdd-implementer` | `sonnet` | `high` | writes code from a plan that is already decided |
| `quality-reviewer` | `sonnet` | `medium` | mostly runs checks and reads their output |
| `adversarial-verifier` | `opus` | `medium` | needs strong reasoning, and a different model from the one that wrote the code |

Aliases, not pinned IDs, so a new model release arrives without an edit.

The main session runs the gates, the design and the plan, and a plugin cannot
choose its model. Recommended: run `/mtk:develop` on Opus at medium effort.
Never Extra High by default.

## Output style

`/mtk:style short|full|default` sets how Claude writes its answers. With no argument it
shows the current style.

| Style | What Claude is told |
|---|---|
| `short` | answer in the first line, no preamble, no closing summary, no tables unless asked |
| `full` | the reason for each choice, the alternatives rejected, and a `Not checked:` line |
| `default` | nothing — Claude's normal style |

The choice is global, one file: `~/.mtk/style`. `hooks/style.sh` reads it on
`SessionStart` and again on every `UserPromptSubmit`, so the style does not drift away
in a long session. A change applies from the next message.

If caveman mode is active (`~/.claude/.caveman-active` exists), mtk adds nothing. Two
sets of style rules would disagree.

**Requested, not enforced.** A hook can add text to the session. It cannot make the
model follow it.

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

Python projects with `tests/test_*.py` and no pytest config run with
`python3 -m unittest`, so nothing has to be installed. mtk itself is one of them.

## Tests

`tests/test_hooks.py` runs the four hooks that enforce rules -- `memory.sh`,
`verify-gate.sh`, `strikes.sh`, `no-writes.sh` -- the way Claude Code does: a JSON
payload on stdin, the answer read from stdout. Each test uses a temp `HOME` and a
temp git repo, so your real `~/.mtk` is never touched.

```bash
./scripts/verify.sh                       # or: python3 -m unittest discover -s tests
```

One test is an expected failure: `python3 -c "open('f','w')"` gets past
`no-writes.sh` today. Not covered: `send.sh`, `style.sh`, `worktree.sh`,
`verify.sh` itself, and whether Claude Code really calls each hook.

## /mtk:doctor -- does mtk really run here?

```bash
sh scripts/doctor.sh            # or /mtk:doctor in a session
```

Every hook writes a heartbeat when it runs: `~/.mtk/beat/<script>-<mode>`, holding
the plugin folder it ran from (the file time says when). The doctor reads them and
reports, as OK / WARN / FAIL with a fix:

- which mtk copy really runs, and its version against the source folder
- each hook in `hooks.json`: did it run, and how long ago
- `python3` and `git`, the project's `.mtk/` memory, and whether ctk is also on

Why: the plugin registry said mtk 0.2.2 was installed while the 0.3.3 hooks ran --
with a `directory` marketplace, Claude Code runs the hooks straight from the source
folder and the registry number lags. And a hook once wired in skill frontmatter
never ran, with nothing to show it. Tests call hooks by hand; only a trace from a
real run proves Claude Code calls them. The doctor reads only and changes nothing.

## The optimize rule

Every tool in mtk must stay correct, fast, and small. Checked by code, not promised:

1. **Budget test.** `tests/test_budget.py` runs every hook in its worst realistic
   case (a 20 MB session transcript, big memory files) and fails if it is slower
   or prints more than its budget. A hook runs on every prompt, tool call or stop,
   and its output is paid for in tokens.
2. **Every wired hook has a budget.** A script in `hooks/hooks.json` or
   `agents/*.md` with no row in `BUDGETS` fails the tests. A new hook cannot skip
   step 1.
3. **Review pass before shipping.** Look for wrong results, slow paths and wasted
   tokens; fix what is found, each fix with a test that failed first.
4. **Measure before optimizing.** A change that makes the code bigger must save
   something measurable. (A transcript cache for `verify-gate.sh` saved 0.02 s per
   tool call -- most of the time is Python starting -- so it was not kept.)

| Hook | Budget | Measured (20 MB transcript) |
|---|---|---|
| `memory.sh start` | 1 s, 12 000 chars | 0.24 s, 9 816 chars |
| `memory.sh stop` | 1 s, 2 000 chars | 0.28 s |
| `verify-gate.sh base` (every tool call) | 1 s, 0 chars | 0.11 s |
| `verify-gate.sh stop` | 1 s, 1 000 chars | 0.32 s |
| `strikes.sh`, `no-writes.sh` (every Bash call) | 0.5 s / 1 s | 0.07 s |
| `style.sh` (every prompt) | 0.5 s, 600 chars | 0.01 s, 195 chars |

## What is in hooks/

Six scripts, six different jobs, all wired in `hooks/hooks.json`.

| Script | Job | Wired in | Scope |
|---|---|---|---|
| `send.sh` | records lifecycle events | `hooks/hooks.json` | whole plugin |
| `style.sh` | adds the chosen answer style | `hooks/hooks.json` | whole plugin |
| `verify-gate.sh` | blocks a chore from finishing until `verify.sh` checked the files | `hooks/hooks.json` | sessions that ran a chore |
| `memory.sh` | shows the memory at start and after compaction; stops once for `/mtk:handoff` after a commit or at 70% context | `hooks/hooks.json` | whole plugin |
| `no-writes.sh` | denies writing Bash commands, and catches any file change after a command | `hooks/hooks.json` | 2 reviewer agents (by `agent_type`) |
| `strikes.sh` | denies a command that keeps failing | `hooks/hooks.json` | all 3 agents (by `agent_type`) |

`no-writes.sh` and `strikes.sh` run on every Bash call but act only when the hook input's
`agent_type` names one of mtk's agents. A plugin-wide write block would stop `tdd-implementer`
doing its job, and a plugin-wide strike counter would count your own commands too. Until 0.3.5
they were wired in the agents' frontmatter instead -- and never ran: Claude Code ignores
`hooks:` in the frontmatter of an agent that comes from a plugin. The `/mtk:doctor` heartbeat
showed it on 2026-11-22. Neither rule had ever been enforced.

## Read-only agents are actually read-only

`quality-reviewer` and `adversarial-verifier` both hold `Bash`, because they need it to run
tests, lint, and `git diff`. `disallowedTools: [Write, Edit]` blocks tools by NAME, and Bash
is not named Write -- so `echo x > file` wrote anyway. The label was documentation, not
enforcement.

`hooks/no-writes.sh` is the enforcement, with two checks:

1. **Before** the command (`PreToolUse`): a deny-list stops the common writes before they
   happen -- redirects, `rm`, `mv`, `cp`, `sed -i`, `tee`, `chmod`,
   `git checkout/reset/clean/commit/push`, package installs.
2. **After** the command (`PostToolUse`): a list cannot see a write inside another program,
   like `python3 -c "open('f','w')..."`. So the hook compares the files git can see (changed
   and untracked, by time and size) with how they were before the command. Any change is a
   write, whatever made it. The hook cannot undo it -- that could destroy your own work -- so
   it blocks the agent with the list of changed files, and the agent must report them.

Not covered: files git ignores, and files outside the repo.

`tdd-implementer` has no such hook -- writing is its job.

## The 3-strikes rule is enforced, not requested

`development-pipeline` says "three failed attempts at the same step = STOP". That lived in a
markdown file, with the agent counting its own failures -- a counter inside the thing it counts
is a suggestion, not a limit.

`hooks/strikes.sh` moves it into code. `PostToolUse` and `PostToolUseFailure` record every Bash
result of an mtk agent; `PreToolUse` denies a command that has already failed three times **with the same
result**.

Command *and result*, deliberately. In TDD a failing test is the goal, so counting failures per
command would block `tdd-implementer` on its own first RED step. Stuck means no progress: the
same command, the same failure, again. Timings, dates, temp paths and hex ids are normalised out
first, so two identical failures are recognised as identical. A success clears every strike for
that command.

State lives in `~/.mtk/strikes/<session>.tsv` and is deleted after a day.
`MTK_STRIKE_LIMIT` changes the number.

## Memory: the plan survives sessions and compaction

`/mtk:handoff` writes three files at the repo root, committed with the code:

- `.mtk/now.md` — Goal, the one Next step, short Decisions.
- `.mtk/plan.json` — the steps: `{"id", "step", "done"}`. JSON, because models
  change JSON files less carelessly than Markdown (Anthropic, *Effective harnesses
  for long-running agents*).
- `.mtk/log.md` — one short entry per episode: what was done, what was decided,
  what is open. This is the project history across chats.

It always ends by showing what it wrote and asking you "correct, or something
missing?". Claude writes the memory; you are the check that it is complete.

**The hook decides when. Claude decides what.** A hook is a script and cannot
understand a chat, so `hooks/memory.sh` only finds the moment and stops Claude
once to run `/mtk:handoff`:

| When | Does | Enforced? |
|---|---|---|
| a commit was made after `now.md` last changed | stops once per new commit | yes |
| the context window is 70% full (`MTK_HANDOFF_AT`) | stops once per session; you then `/clear` | yes |
| before compaction | tells the summary to keep goal, steps, and unlogged work | yes |
| every session start, and after compaction | prints now.md, open steps, last 5 log entries; **STALE** if commits are newer | yes |
| a plan step was removed or renamed (vs git HEAD) | blocks | yes |
| — | that what is written is good and complete | no — your answer to the question is the check |

Context size comes from the session log: the token usage of the last answer. The
log does not say the window size, so the hook guesses: 1M for Opus models (seen on
this setup: 79.6k tokens shown as 8%) or once a session passed 200k, else 200k.
Set `MTK_CONTEXT_WINDOW` to override it.

Compared with ctk: `ledger` -> the three files; `/save-state` and `/create-handoff`
-> `/mtk:handoff`; `/resume-session` -> not needed, every session shows the memory.
Why not ctk's ledger: on 2026-11-22 it was 3 months old and its automatic handoff
had empty `next_steps`, by design: only manual commands write goals there, and
nothing checks age. Design and evidence: `specs/memory.md`.

Without `.mtk/now.md`, only the 70% stop runs (it creates the files on first use).

## A chore cannot finish without verify.sh

Found on real work: on Alta (PR #100), `/mtk:chore` ran 61 of 891 tests and lint on
3 files, then reported "lint shows no errors". The full `verify.sh` said `failures`.
The skill *asked* for `verify.sh`; the agent chose a faster check.

`hooks/verify-gate.sh` runs from `hooks/hooks.json` on `PreToolUse` and `Stop`. It does
nothing until `/mtk:chore` appears in the session. (It was first put in the chore
skill's frontmatter; in a real session that hook never ran, so it moved here.) It records the state
of the files when the chore starts (`git diff HEAD` plus untracked files). When the
chore tries to finish, it blocks if the files changed and `verify.sh` has not checked
that exact state. `verify.sh` records each full run; `--only` does not count.

It watches the files, not the tool names. The first version looked for `Edit` calls
and, run against the same Alta session, let it through: the agent had changed the
files with a Python script inside `Bash`.

Limits, stated plainly:
- It proves `verify.sh` ran. It cannot prove the verdict was reported honestly.
- Outside a git repo it allows, because there is no state to compare.
- Once a chore ran, it stays on for the rest of that session: later changes also
  need a `verify.sh` run before the session can stop.
- After 3 blocks on the same state it lets the stop through, so a project where
  `verify.sh` cannot run never loops forever.

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
