---
name: afk-wave
description: "Opens the next wave of ready-for-agent tickets from docs/spec.md and the repo's real state — picks the unchecked criteria of the current milestone, slices them into one-session tickets, serialises them, and stops when there is nothing left to open. Runs between two afk runs, with nobody watching. Triggers: /afk-wave, \"open the next wave\", \"the tickets for the current milestone\", \"what are we building now?\"."
---

# /afk-wave

Between two runs. It reads what the spec still asks for, what the repo **really**
contains, and opens the next wave's tickets.

We do not slice everything up front because we cannot: a wave's tickets depend on the
code the previous wave actually wrote, not on the code we imagined.

## 0 — The guard, before anything else

```bash
git fetch -q origin && git switch -q dev && git pull -q
diff <(git show afk-spec:docs/spec.md | sed 's/\[x\]/[ ]/g') <(sed 's/\[x\]/[ ]/g' docs/spec.md)
```

Any difference other than boxes → **stop and say so**. The spec has drifted: from then
on nothing judges the loop, it awards itself its own victory. It is a stop, not a
warning.

No `afk-spec` tag → the repo has not been through `/afk-spec`. Stop too.

## 1 — What is left

```bash
grep -n '^- \[ \]' docs/spec.md          # the unchecked criteria
grep -n '^## Milestone' docs/spec.md
gh issue list --state open --json number,title,labels,milestone
```

The **current milestone** is the first one that still has an unchecked criterion. We
only work on that one. All checked in every milestone → **there is nothing to open**,
say so and stop: that is the loop's normal end.

## 2 — What the repo really contains

The spec says what we want; it does not say what exists. Before slicing:

```bash
git log --oneline afk-spec..dev | head -40
git diff --stat afk-spec..dev
```

A ticket written against an imagined repo goes looking for files that do not exist and
burns its session. That is the difference between this wave and the previous one.

## 3 — The reds from the previous wave

```bash
gh issue list --state open --label ready-for-human --json number,title,comments
```

An unchecked criterion whose ticket has already been through once: **re-slice it
smaller**, do not reopen it as-is — it will fail the same way.

Two waves without a criterion landing → leave it in `ready-for-human`, do not put it
back in the wave, and **name it in your report**. It is one of the loop's three stopping
conditions; letting it pass silently costs every night that follows.

## 4 — Choosing

**3 to 6 criteria**, no more. The plan covers code that does not exist yet: beyond that
it is guessed, and the next wave will throw it away.

A ticket that delivers **no criterion from the spec** does not get opened. No exceptions
— that is exactly the door through which the loop goes off building what nobody asked
for.

## 5 — Writing the tickets

One vertical slice per ticket — schema, code, screen, test — otherwise the gate cannot
judge it on its own.

```bash
gh issue create -t "<title>" -l ready-for-agent -m "<current milestone>" -F - <<'EOF'
## What to build

<in one sentence, then what must not be touched>

## Acceptance criteria

- [ ] **A3** — `POST /tasks` with a title returns 201 and the created id
- [ ] the test lives in `tests/api/tasks.spec.ts`

## Blocked by

None

Verify: pnpm vitest run tests/api/tasks.spec.ts
EOF
```

The criteria copied **word for word** from the spec, number included. That is what lets
`/afk-merge` check them off mechanically, and lets you review without opening two files.

The `Verify:` line is the criterion's command. If the ticket carries several, chain the
commands with `&&`. Prove it before writing it — on a test file that does not exist yet,
it must fail cleanly, not hang:

```bash
timeout 120 bash -c '<the command>'; echo "rc=$?"
```

`rc=124` = it never returns (`vitest` without `run`, `jest --watch`): the ticket will die
on `TIMEOUT` for a reason that is not its own.

## 6 — Serialising what steps on what

Two tickets of the same wave each start from a base that does not contain the other:
both are green and the breakage only shows at integration — or never, when both create
the **same path** with two APIs each right on its own side.

Two tickets announcing the same files → a `Blocked by` on whichever can wait. Not a
merge: the second then starts from the first one's branch and sees its work.

And the numbers that get fought over (ADR, migration) are handed out **in the body**,
before the run:

```bash
ls docs/adr | tail -3
```

## 7 — Rereading your own batch

```bash
./afk.sh -n
```

Read from it: the waves, the bases, the freezes, the effective gate per ticket. A
**frozen** ticket in your own wave is a slicing mistake you just made — fix the
`Blocked by`.

If a `Verify:` line does not show up in the `-n` where the ticket writes one, it was
refused by the validation pattern: it ends in `:`, or in a backtick.

The rest of the content traps are in `/afk-preflight` — **read it rather than redo it**,
it is the same work on tickets coming from elsewhere.

## 8 — Reporting

A table: ticket, criteria delivered, `Blocked by`, gate. Then the launch command,
**without running it**:

```bash
nohup ./afk.sh -j 3 &
```

Unlike `/afk-preflight`, this skill **opens** the tickets without waiting for approval:
it runs in a loop where nobody is awake. That is why its prohibitions are mechanical and
not a matter of judgement — see below.

## What this skill does not do

- **It never touches `docs/spec.md`.** Not a box, not a word. Checking off is
  `/afk-merge`'s job, after running the criterion's command.
- **It invents no criterion.** A need discovered on the way that is not in the spec goes
  into the report; it does not become a ticket.
- It does not reopen an already checked criterion.
- It does not work two milestones at once.
- It does not run `afk.sh`: a run takes hours, it has no business inside a session. It
  is the loop above that calls it.
- It merges nothing and closes no ticket.
