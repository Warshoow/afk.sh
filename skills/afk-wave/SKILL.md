---
name: afk-wave
description: "Opens the next wave of ready-for-agent tickets from docs/spec.md and the repo's real state. Run by afk-app.sh between two runs."
disable-model-invocation: true
---

# /afk-wave

Between two runs. It reads what the spec still asks for, what the repo **really**
contains, and opens the next wave's tickets.

We do not slice everything up front because we cannot: a wave's tickets depend on the
code the previous wave actually wrote, not on the code we imagined.

## 0 — The guard, before anything else

`$base` below is the landing branch: `BASE_BRANCH` in `.afk.env`, `dev` when unset. A shell
call does not keep variables: recompute it in each one that uses it.

```bash
base=$(. ./.afk.env >/dev/null 2>&1; echo "${BASE_BRANCH:-dev}")   # the landing branch
git fetch -q origin && git switch -q "$base" && git pull -q
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
git log --oneline "afk-spec..$base" | head -40
git diff --stat "afk-spec..$base"
```

A ticket written against an imagined repo goes looking for files that do not exist and
burns its session. That is the difference between this wave and the previous one.

Done when every file, route or table your tickets will name exists on `$base`
(`git ls-files`, `grep`), or the ticket says it creates it.

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

Every ticket delivers **unchecked criteria of the spec**, and only those. No exceptions
— a ticket outside them is exactly the door through which the loop goes off building
what nobody asked for. A need discovered on the way goes into the report.

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
commands with `&&`. Prove it before writing it, by the rule of `/afk-setup` step 4
(`../afk-setup/SKILL.md`): `timeout 180`, then read `rc` there. The test file does not
exist yet, so the proof you want here is a clean failure, not `rc=0`: `rc=124` is the
watch trap.

## 6 — Serialising what steps on what

Apply `/afk-preflight` step 5 (`../afk-preflight/SKILL.md`) to the batch you just wrote:
serialise the tickets that announce the same files, and hand out the ADR and migration
numbers in the bodies. Done here, the `apply` pass that follows finds nothing to fix.

## 7 — Rereading your own batch

```bash
./afk.sh -n
```

Read from it: the waves, the bases, the freezes, the effective gate per ticket. A
**frozen** ticket in your own wave is a slicing mistake you just made — fix the
`Blocked by`.

If a `Verify:` line does not show up in the `-n` where the ticket writes one, it was
refused by the validation pattern: it ends in `:`, or still holds a backtick (prose
quoting commands rather than a command).

The rest of the content traps are `/afk-preflight`'s job, not this skill's: `afk-app.sh`
runs `/afk-preflight apply` right after this session. By hand, run `/afk-preflight`
before the launch.

## 8 — Reporting

A table: ticket, criteria delivered, `Blocked by`, gate. Then the launch command,
**without running it**:

```bash
nohup ./afk.sh -j 3 &
```

Unlike `/afk-preflight`, this skill **opens** the tickets without waiting for approval:
it runs in a loop where nobody is awake. What keeps it honest is the guardrail below.

## Guardrail

**`docs/spec.md` is read-only here** — not a box, not a word. Checking off is
`/afk-merge`'s job, after running the criterion's command.
