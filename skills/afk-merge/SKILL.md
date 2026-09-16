---
name: afk-merge
description: "Lands an afk wave on dev — merges the green PRs in base order, checks off in docs/spec.md the criteria whose command really passes, takes the reds out, and says whether the loop continues or stops. Runs after each run, with nobody watching. Triggers: /afk-merge, \"land the wave\", \"merge what is green\", \"do we continue?\"."
---

# /afk-merge

The run is over. This skill lands what holds, leaves the rest outside, and decides the
loop's only question: **do we launch one more wave?**

It does not diagnose the reds — `/afk-debrief` does that, better, and without redoing it
here. This skill decides; the other one explains.

## The rule

**A criterion is only checked off after its command has passed on `dev`.** Not because
the ticket is green, not because the PR is merged, not because the work looks done. We
run the command, we read the return code.

That is what makes the counter mechanical. A model that checks off by reading ends up
checking everything off.

## 1 — The state

```bash
cat .afk/summary.md
git fetch -q origin && git switch -q dev && git pull -q
diff <(git show afk-spec:docs/spec.md | sed 's/\[x\]/[ ]/g') <(sed 's/\[x\]/[ ]/g' docs/spec.md)
```

The `diff` returns nothing other than boxes, otherwise **the loop stops**: the spec has
drifted, nothing judges it any more.

No `.afk/summary.md` → no run made it to the end. Merge nothing, say so.

## 2 — What is allowed to land

A ticket lands if **all three** are true:

| | where it is written |
|---|---|
| `GREEN` in the summary (not `OK` — `OK` contains the unproven greens) | `.afk/summary.md` |
| the PR is not a draft | `sget <n> draft` |
| the PR's CI is green | `gh pr checks <n>` |

An `unproven green` (local gate shrunk **and** CI inconclusive) does not land: nobody ran
the complete gate. It goes out as `ready-for-human`.

## 3 — Merging, in base order

afk stacks: a blocked ticket's branch starts from its blocker's. Merging it before its
blocker brings the other one's work in through a merge that does not say so.

```bash
grep -h '^base_ref=' .afk/*.status        # the chain, ticket by ticket
gh pr merge <n> --merge --delete-branch   # in order: blocker first
```

`--merge`, not `--squash`: a squash rewrites the blocker's commits, and the dependant
brings them back a second time.

**After each merge**, the gate on `dev`:

```bash
<VERIFY_CMD>; echo "rc=$?"
```

Red → the merge that just arrived breaks what was working. Revert it
(`git revert -m 1 HEAD`), take the ticket out as `ready-for-human` with the gate's output
as a comment, and carry on with the next ones. A single bad ticket does not cost the
wave.

## 4 — Checking off

For each unchecked criterion of the current milestone, its command, on `dev`, exactly as
written in the spec:

```bash
timeout 300 bash -c '<the criterion command>'; echo "rc=$?"
```

`rc=0` → `- [ ]` becomes `- [x]`. Anything else → the box does not move, whatever the
ticket says.

A criterion that passes while its ticket is red gets checked off anyway: it is the
command that judges, not the run.

Then, and **only** that:

```bash
git commit -am "chore(spec): wave <n> — A3 A4 checked"
git push
diff <(git show afk-spec:docs/spec.md | sed 's/\[x\]/[ ]/g') <(sed 's/\[x\]/[ ]/g' docs/spec.md)   # must be empty
```

The `diff` after the commit is not a courtesy: it is what catches the hand that slipped
on a sentence of the spec.

## 5 — The reds

```bash
/afk-debrief
```

Do not redo its work. What you need from it is one thing per red: **ticket or
environment**.

- environment (wrong gate, red base, `setup`, push refused) → the ticket starts again
  as-is on the next wave, after the fix it points at
- ticket → `ready-for-human`, and `/afk-wave` will re-slice it smaller

```bash
gh issue edit <n> --add-label ready-for-human --remove-label ready-for-agent
```

And record in afk's `docs/defects.md` whatever would have broken the same way on any
repo — `/afk-debrief` says which ones. Nothing to record is the normal case.

## 6 — The milestone

All of a milestone's criteria checked → close its milestone and say which one starts:

```bash
gh api -X PATCH repos/{owner}/{repo}/milestones/<id> -f state=closed
```

## 7 — Deciding

Three stops. **There have to be three, otherwise the loop runs for nothing:**

| | what you say |
|---|---|
| every criterion checked | done — `dev` is ready to be merged into `master`, by a human |
| budget exhausted (the ceiling given at launch) | what the spend bought: criteria checked / total, and the milestone in progress |
| **two waves in a row without a single criterion being checked** | the loop is not moving. Name the criterion that blocks and what `/afk-debrief` says about it |

Those three only. "The wave went badly" is not a stop: one red wave in three is the
normal regime, and the next one re-slices smaller.

In every other case: `/afk-wave`, then one more run.

## 8 — Reporting

Short, it is read on waking up, in series with the other waves:

```
Wave 4 — 3 tickets, 2 merged, 1 taken out
Checked: A7 A8   (14/26)
Out    : #61 — the gate on dev breaks after merging, revert done
Next   : /afk-wave (milestone 2)
```

## What this skill does not do

- **It never merges into `master`.** `dev` only. The last merge is a human decision, and
  it is the only thing left to be one.
- **It checks off no criterion whose command it has not run itself.**
- **It does not modify the text of `docs/spec.md`** — only `[ ]` into `[x]`. A criterion
  that turns out to be impossible is flagged in the report and stops the loop; it does
  not get rewritten.
- It opens no ticket: that is `/afk-wave`.
- It does not review the greens' code. The gate and CI are what we have; widening them
  is a `.afk.env` change, not an end-of-wave judgement.
- It does not relaunch `afk.sh`.
