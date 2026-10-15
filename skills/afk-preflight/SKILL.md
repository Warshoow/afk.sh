---
name: afk-preflight
description: "Rereads and re-slices the ready-for-agent batch before an afk run: freezes, uncheckable criteria, oversized or colliding tickets. `apply` (afk-app.sh only) applies the mechanical fixes itself."
disable-model-invocation: true
---

# /afk-preflight

A badly written ticket does not cost five minutes, it costs `MAX_ATTEMPTS × TIMEOUT` of
the night — and if it blocks the others, it costs their night too. This skill rereads
the batch before the run and returns a list of corrections.

`./afk.sh -n` already gives the whole mechanism: waves, bases, stacks, frozen, effective
gate per ticket. Read it from there; if you and the script disagree, the script is right.
This skill judges the *content* of the tickets, which the script cannot do.

## 1 — Prerequisites

```bash
test -f .afk.env || echo "no .afk.env — run /afk-setup first"
```

No `.afk.env` → the gate will be a pnpm monorepo's, wrong everywhere else.
Stop there.

## 2 — The plan

```bash
./afk.sh -n            # the whole ready-for-agent batch
./afk.sh -n 43 48 49   # or an explicit batch
```

Read from it, without recomputing: the **frozen** tickets, the **waves** (who runs at
the same time as whom), the **bases** (who stacks on whom), and the `Verify:` /
`Timeout:` / `Model:` / `Effort:` lines the tickets gave themselves.

## 3 — The bodies

```bash
gh issue view <n> --json title,body,labels -q '.title, .body'
gh api "repos/{owner}/{repo}/issues/<n>/dependencies/blocked_by" --jq '.[].number'
```

One ticket per call, for the whole batch. It is the raw material for everything else.
The blockers are the native GitHub links first, the body's `Blocked by` section when
there are none, as `afk.sh` reads them: `/to-tickets` (mattpocock-skills 1.3+) leaves the
section out when it set the links.

## 4 — What to look for

Every ticket of the batch against every row of this table. Done when each pair has a
verdict — most are "does not apply", and that is still a verdict.

| What you see | What will happen | Fix |
|---|---|---|
| **Frozen — blocker open outside the run** | the ticket does not start, and neither do its dependants | three cases: (a) the blocker is done but its ticket was never closed → close it; (b) it has an open PR → `STACK_ON_OPEN_PR=1` is enough, nothing to do; (c) it really is still to do → add it to the batch, or take the dependant out |
| **Stale `Blocked by`** (blocker already merged) | a freeze for nothing | close the blocker, or remove the line from the body |
| **Acceptance criterion no gate can see** ("the user sees a toast") | "green" will mean "it compiles" | either a test that proves it plus a `Verify:` line that runs it, or accept it — but then say so, do not discover it in the summary |
| **Ticket crossing several apps with a `Verify:` shrunk to one** | the local gate does not see the breakage, only CI will — after the PR | widen the `Verify:`, or remove it to fall back on the complete gate |
| **Rework without a `Timeout:`** (migration + code + tests + docs, or more than ~6 criteria) | cut in the middle at `TIMEOUT`, twice | propose `Timeout: 90m` (the `timeout(1)` format) |
| **Fuzzy scope** ("improve X", "clean up Y") | the agent goes where it likes, the review has nothing to compare against | rewrite the acceptance criteria as checkable things, or take the ticket out of the batch |
| **Two tickets of the same wave on the same files** | each worktree starts from the base without seeing the other: it compiles on both sides and breaks at integration | serialise them with a `Blocked by` between the two |
| **Ticket already covered by an open PR** | it will come out `absorbed`, at best | close it, or leave it: `absorbed` is a clean result, not a failure |
| **Mechanical ticket** (rename, config, docs, version bump) | it will run on the rework model | `Model: sonnet` in the body |
| **Ticket whose previous run finished near the context window** ("Context" column of `.afk/summary.md`) | too big: quality degrades before the failure does | cut it — §5 |

## 5 — Cut, serialise, number

The three fixes that touch the **batch** rather than a body. They hold for any already
published ticket, whatever its origin — `/to-tickets`, a grilling, written by hand, or a
batch from three weeks ago. Nothing to cut is the normal case: a batch out of
`/to-tickets` is already in vertical slices of one session.

### Cutting a ticket that does not fit in one session

The signs, in order of reliability: the "Context" column of a previous run close to the
window; the ticket crosses several apps of the monorepo while its gate only sees one;
more than ~6 acceptance criteria; a title containing "and".
A longer `Timeout:` fixes nothing: the budget is not what is missing, the room is. A
ticket cut in the middle burns `MAX_ATTEMPTS × TIMEOUT` and returns a half-written
branch.

Each piece keeps a **complete slice** — schema, API, screen, tests — otherwise the gate
cannot judge it on its own and the ticket becomes a half-ticket nothing verifies.
The pieces are serialised with `Blocked by` in the order they get built: afk then stacks
the branches and each one inherits the previous one's work.

The original **never** stays in the batch: either it loses its label and serves as a
parent, or it gets closed pointing at its pieces. Otherwise it starts again the next
night and redoes the work of its own children.

```bash
gh issue create -t "<piece title>" -l ready-for-agent -F - <<'EOF'
## What to build
…
## Acceptance criteria
- [ ] …
## Blocked by
- #<previous piece>, or "None"
EOF
gh issue edit <original> --remove-label ready-for-agent   # parent: out of the batch
gh issue comment <original> --body "Cut into #a #b #c for an afk run."
```

### Serialising two tickets writing into the same files

Two tickets of the same wave each start from a base that does not contain the other:
both are green, and the breakage only shows at integration — or not at all, when both
create the **same path** with two APIs each right on its own side (defect 25).
The fix is a `Blocked by` on whichever of the two can wait, not a merge: the second one
then starts from the first one's branch and sees its work. We only merge them when
neither verifies without the other.

Read it off `./afk.sh -n` (who runs in the same wave) crossed with the bodies (which
files each one announces it touches).

### Handing out the numbers before the run

Two branches claiming the same ADR, migration or RFC number are each green on their own
side and no gate will see it (defect 22) — the integration pass flags it, but after the
PRs. So a number is handed out **in the body**, before the run:

```bash
ls docs/adr | tail -3            # the last one taken
ls apps/*/migrations | tail -3
```

Then, in each ticket concerned: "this ticket's ADR is `0042`, not the next free one".
Two tickets never get the same one.

## 6 — Prove every `Verify:` line before proposing it

Prove each one by the rule of `/afk-setup` step 4 (`../afk-setup/SKILL.md`): `timeout 180`,
then read `rc` there — `rc=124` is the watch trap.

Prove the command the script will **actually** run, not the one the ticket looks like it
writes: `./afk.sh -n` prints it, extracted. Two forms pass — the bare command, and the
command in `code` followed by prose, where only the span counts. A value ending in `:`
is ignored and the ticket falls back on `VERIFY_CMD`; if the `-n` shows no `Verify:`
line where the ticket writes one, that is why.

## 7 — Give the verdict

A table, one ticket per line: **goes as is** / **to fix** / **to cut** /
**to take out of the batch**, with the reason in one line. Then the concrete fixes, ready
to paste:

```bash
gh issue edit <n> --body-file -    # corrected body
gh issue edit <n> --remove-label <ready-for-agent>   # take it out of the batch
```

What happens to them depends on how you were invoked:

- **`/afk-preflight`** (a human): propose, and wait for approval before any edit, label,
  ticket created or closed. A ticket body is trust surface: its `Verify:` and `Timeout:`
  lines are executed as-is by the run. An uncheckable criterion gets a proposed wording;
  the human decides. Finish with the launch command suited to the batch, for the human
  to run:

  ```bash
  nohup ./afk.sh -j 3 43 48 49 &
  ```

- **`/afk-preflight apply`** (only `afk-app.sh`'s loop, where nobody is awake to approve
  a table): apply the fixes yourself, within the limits of the next section, then give
  the table anyway.

## Apply mode — what it may change

What you may apply on your own, because it is mechanical and `./afk.sh -n` proves it:

- **cut** a ticket that does not fit in one session, into the pieces step 5 describes;
- **serialise** two tickets writing into the same files, with a `Blocked by`;
- **hand out** the ADR and migration numbers before the run;
- **fix** a `Timeout:`, a `Verify:` proven in step 6, a `Blocked by` pointing at a blocker
  already merged and closed.

What you may **not** apply, whatever it costs: rewriting an acceptance criterion. That is
the judgement `docs/spec.md` reserves for `/afk-spec`, and a criterion rewritten by
whoever is going to fill it is the exact failure the `afk-spec` tag exists to prevent.
A ticket whose criteria no gate can check is therefore taken **out of the batch**:

```bash
gh issue comment <n> --body "preflight: <the criterion> is not checkable by a gate — out of this wave"
gh issue edit <n> --remove-label <ready-for-agent>
```

It will come back through `/afk-wave` on a later wave, or by hand. An emptied batch is a
result: `afk-app.sh` stops on it and says so.

Re-run `./afk.sh -n` after your edits and check it agrees with what you intended. It is
the script that is right. Then finish with the step 7 table, in the session's output: it
is the only trace the morning will have of what you changed.
