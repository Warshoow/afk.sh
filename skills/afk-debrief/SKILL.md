---
name: afk-debrief
description: "Goes through a finished afk run — reads .afk/summary.md and the traces, sorts each non-green by cause (wrong gate, ticket too big, real failure), proposes what to fix and what to relaunch, and records afk's own defects in its docs/defects.md. Run on waking up, before merging. Triggers: /afk-debrief, \"go through the run\", \"what failed last night?\", \"why is #48 red?\"."
---

# /afk-debrief

The run is over. This skill reads what it left behind, says **why** each ticket is not
green, and proposes what to fix before relaunching.

A red is not a verdict on the ticket: the gate may have been wrong, the worktree badly
seeded, the model unavailable. Sorting that out is the whole job.

## 1 — The summary

```bash
cat .afk/summary.md
```

No file → no run made it to the end; go to `.afk/<n>.out`.

Columns: result, PR, attempt, model, context, cost, duration. Below the table:
integration verdict, gates used, green rate on the 1st attempt, and the resume commands
for the reds.

## 2 — Read the run before the tickets

Four things are read on the whole, and a single one of them can explain every red at
once:

| What you see in the summary | What it says |
|---|---|
| **integration red while the tickets are green** | it is not N problems, it is one: the combination. `.afk/integration-verify.txt`, worktree kept in `.afk/wt/_integration` |
| **"duplicate numbers"** | two branches took the same ADR or migration number. No gate can see it, git neither: renumber before merging. The number stays with whoever cites it most (`git grep -c` decides) |
| **"same path created by several branches"** | two branches created the same file, with two APIs both of them right. Each compiles without the other: only the combination says so |
| **"tickets from this run cited in the merged docs"** | a sentence may be in the future tense about something delivered ten minutes ago. No git conflict, no gate: reread the cited lines |
| **"Model" column ≠ the requested model, without `(+N subagents)`** | `FALLBACK_MODEL` kicked in: the main one was unavailable. Last night's greens ran on the backup model, read them more closely |
| **"Model" column with `(+N subagents)`** | the session spawned N subagents; they carry the model of their definition (`.claude/agents/*.md`) and not the ticket's. One extra model comes from them, not from a fallback — and part of the cost too (defect 41) |
| **"Context" column close to the window** | ticket too big, even green. It is the thermometer of the slicing, not a quality grade |
| **"the base was already red before the run"** | the gate was failing on `origin/<base>` before any ticket ran. Open `.afk/base-verify.txt` **before** judging a red: a ticket whose `<n>-fail.txt` names the same failure is not to blame, and relaunches as-is once the base is fixed |
| **"no CI on this repo"** | the local gate is the only one that ran for the whole run. If it was replaced on some tickets, those had no complete gate at all — the line names them |

And one warning: **a 100% green rate means nothing if the gate verifies nothing.** The
tickets marked `⚠` had a local gate replaced by their `Verify:` line — on a repo that
has CI, only CI ran the repo's complete gate; without CI, nobody ran it.

## 3 — Sort each non-green

For each ticket that is not green, `sget` left the cause in `.afk/<n>.status`
(`reason=`), and the detail is in a specific file:

```bash
cat .afk/<n>.status          # result, reason, session, model, cost
cat .afk/<n>.out             # the orchestrator's trace for this ticket
```

| Result / `reason` | Where it is written | Likely cause | What to do |
|---|---|---|---|
| `ko` / `setup` | `<n>-setup.log` | the install failed **in the worktree**: no lockfile at the root, an indispensable gitignored file not seeded | fix `SETUP_CMD` or `SEED_GLOBS` in `.afk.env`, then relaunch the ticket |
| `ko` / `verify` | `<n>-fail.txt` (last failure kept) | to be decided: wrong gate or real failure — see step 4 | depending on the verdict |
| `ko` / `pr` | `<n>.out` | a PR is already open on this branch | close the PR, or close the ticket |
| `ko`, no commit | `<n>-verify.txt` | the agent produced nothing **and** the base was red: the repo was already broken before it | fix the base first, the whole batch depends on it |
| `draft` / `cut` | the PR itself | the `timeout` fired: the session may have been cut **in the middle of a file** | reread it in full before leaving draft, and see whether the ticket deserves a `Timeout:` line |
| `draft` / `abnormal` | the PR + `<n>-<attempt>.json` | the session stopped between two actions, `subtype` says which | reread; the work present compiles, its completeness is not guaranteed |
| `draft` / `not committed` | the PR itself | the orchestrator caught up a working tree the agent had not committed | the work is there; check the commit message, it carries the ticket title and not the repo's format |
| `unproven green` | the summary | local gate replaced (`Verify:`) **and** CI inconclusive: nothing ran the complete gate | rerun CI, or run the complete gate by hand on the branch |
| `push refused` | `<n>-push.txt` | the remote refused the branch (token without the `workflow` scope, branch already there). The work is complete and green locally | push by hand from the kept worktree; **do not** relaunch the ticket, the session would redo the same work |
| `frozen` | `<n>.out` | its blocker was not delivered — or the session itself said a prerequisite was missing from its base (`result=frozen`, the reason is in a comment on the issue and in `<n>-<attempt>.json`) | nothing to do about it: deliver what is missing and it will start. The label has not moved |
| `absorbed` | the comment left on the issue | nothing to do, the base was already green: a predecessor had delivered its content | check then close the ticket |
| `/ CI red` | `<n>-ci.txt` | the local gate was green, the repo's CI was not: the local gate is narrower than CI | widen `VERIFY_CMD`, or the ticket's `Verify:` line |

## 4 — Wrong gate or real failure

A `ko / verify` does not yet say whose fault it is. The red ticket's worktree is
**kept**, dependencies installed:

```bash
cd .afk/wt/<n>
git log --oneline origin/<base>..HEAD      # what the agent produced
<the ticket's gate>                         # rerun it by hand
git stash list; git status                  # what it left hanging
```

Then compare what the gate complains about with what the agent touched:

```bash
git -C .afk/wt/<n> diff --name-only origin/<base>..HEAD
```

The gate complains about files **absent from that list** → it is the environment or the
gate, not the ticket: the worktree does not have what it needs, or the gate is wider than
the scope. It complains about files **from the list** → real failure, and `<n>-fail.txt`
says which one.

Do not reset the worktree onto the base to decide: that destroys the state of the
failure, which is exactly what you came to read.

## 5 — Read the journal, then ask the session

Each session keeps a decision journal, appended as it goes, at `.afk/<n>-work.tsv`:
six tab-separated columns — `ts`, `phase`, `decision`, `why`, `evidence`, `result`.
`afk.sh` asks every ticket for it (`build_prompt`), and `/show-me-your-work` holds the
contract.

```bash
column -t -s $'\t' .afk/<n>-work.tsv          # one red
grep -H . .afk/*-work.tsv | head -40          # the whole run at a glance
```

Read it **before** step 4's verdict: it holds what no trace contains and what the diff
cannot show — the hypothesis taken because nobody was there to decide, the option ruled
out and what ruled it out, the red gate and what the session concluded from it, the
premise that turned out false, anything done outside the ticket's scope. A `result` of
`ko` or `abandoned` on a line whose `evidence` says `none` is the signature of a
session that guessed.

No file → the session never wrote one. Note it as an afk defect (step 7) if it happens
across a whole run: the instruction is in the prompt, so it is the prompt that failed.

Only then, and only if the journal is silent on the point you need, get back into the
session that produced the red — the summary gives what it takes:

```bash
(cd .afk/wt/<n> && claude --resume <id>)
```

Useful when the failure is a design choice, useless when the environment was broken — in
that case the answer is in `.afk.env`.

## 6 — Decide, then propose

A table, one ticket per line: **relaunch as-is** / **fix the gate then relaunch** /
**re-slice** / **take it by hand**, each with the reason in one line.

Then the actions, ready to paste — the exact label names are in
`docs/agents/triage-labels.md`:

```bash
gh issue edit <n> --add-label <ready-for-agent> --remove-label <ready-for-human>
```

And when a ticket has to be re-sliced, say so explicitly: that is `/to-tickets`'s job,
not this skill's.

**Propose, wait for approval, relabel nothing unprompted.** A ticket put back to
`ready-for-agent` starts again the next night: it is a run decision.

## 7 — Record what is an afk defect

afk's repo is mounted in every project: it is the only place that spans the runs **and**
the projects. `RUNS.md` already receives each run's facts, appended by `afk.sh`. What
needs judgement goes into `docs/defects.md`, and you are the one who puts it there.

The path is the script's, not the project's:

```bash
d=$(dirname "$(readlink -f "$(command -v afk.sh || echo ./afk.sh)")")
tail -40 "$d/docs/defects.md"      # the format of an entry
grep -h '^## ' "$d"/docs/defects*.md | tail -3   # the last number taken (the archive carries it)
```

**The sorting is the whole job.** Only write in what would have broken **the same way on
any repo**: the orchestrator, the worktrees, the gate, the prompt, the parent/child
protocol. A flaky test, a badly tuned `.afk.env`, a badly sliced ticket are **project**
problems — they get fixed over there and have no business in this register.

An afk defect is recognised by one thing: the trace blames the wrong culprit. A healthy
ticket marked red, a freeze with no real blocker, a green that compiled nothing, a ticket
burning its attempts for a reason that is not its own.

Next number, verdict in the title (**fixed** if you already have the fix, **open**
otherwise), and three paragraphs: what was seen, the cause, what was done about it.
An entry is written in `docs/defects.md`, which only keeps the live defects; a **fixed**
defect goes into `docs/defects-fixed.md`, and one that a later fix closes moves there
as-is, keeping its number.
Then **show the entry you wrote**. Unlike tickets and PRs, you do not wait for approval
on this one: a defect that is not recorded comes back, and gets re-diagnosed from
scratch.

Nothing to record is the normal case. Do not fill the register for the sake of filling
it.

## 8 — Cleanup

Red worktrees are kept on purpose. Once the ticket is understood:

```bash
git worktree remove --force .afk/wt/<n>
```

Do not delete them before you have concluded — they contain the exact state of the
failure, `node_modules` included.

## What this skill does not do

- It merges no PR and does not review the greens' code: that is the review.
- It does not relaunch `afk.sh`.
- It relabels and closes no ticket without approval.
- It does not conclude from a red that the ticket was bad: half the reds are gates, not
  tickets.
- It does not write the worked-on project's problems into `docs/defects.md`: that
  register is about afk only, it is read from every project.
