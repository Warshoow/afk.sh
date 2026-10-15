---
name: afk-merge
description: "Lands an afk wave on the landing branch (BASE_BRANCH, dev by default): merges the green PRs in base order, checks off the criteria whose command passes, takes the reds out. Run by afk-app.sh after each run."
disable-model-invocation: true
---

# /afk-merge

The run is over. This skill lands what holds, leaves the rest outside, and decides the
loop's only question: **do we launch one more wave?**

It does not diagnose the reds — `/afk-debrief` does that, better, and without redoing it
here. This skill decides; the other one explains.

## The rule

**A criterion is only checked off after its command has passed on the landing branch.** Not because
the ticket is green, not because the PR is merged, not because the work looks done. We
run the command, we read the return code.

That is what makes the counter mechanical. A model that checks off by reading ends up
checking everything off.

## 1 — The state

`$base` below is the landing branch: `BASE_BRANCH` in `.afk.env`, `dev` when unset. A shell
call does not keep variables: recompute it in each one that uses it.

```bash
cat .afk/summary.md
base=$(. ./.afk.env >/dev/null 2>&1; echo "${BASE_BRANCH:-dev}")   # the landing branch
git fetch -q origin && git switch -q "$base" && git pull -q
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
| the PR is not a draft | `grep '^draft=' .afk/<n>.status \| tail -1` |
| the PR's CI is green | `gh pr checks <n>` |

An `unproven green` (local gate shrunk **and** CI inconclusive) does not land: nobody ran
the complete gate. It goes out as `ready-for-human`.

## 3 — Merging, in base order

First, decide whether the gate needs to run between merges. The run's integration pass
already ran the complete gate on its branches merged together, and wrote the content it
passed on in `.afk/green.tree` (line 1: a git tree). Try the same merges locally, without
touching the remote:

```bash
base=$(. ./.afk.env >/dev/null 2>&1; echo "${BASE_BRANCH:-dev}")
git worktree add -q --detach .afk/wt/_trial "origin/$base"
for b in <the landable branches, in base order>; do
  git -C .afk/wt/_trial merge -q --no-edit "origin/$b" || { git -C .afk/wt/_trial merge --abort; echo CONFLICT; break; }
done
git -C .afk/wt/_trial diff --quiet "$(head -1 .afk/green.tree)" HEAD -- . ':(exclude)docs/spec.md' &&
  echo SAME || echo DIFFERENT
git worktree remove --force .afk/wt/_trial
```

- `SAME` → that exact content already passed the gate: merge them all below **without**
  the gate after each merge. Once all are in and pulled, run the same `git diff --quiet`
  against `$base`'s `HEAD`: still `SAME` → close each ticket and clean its branches, as
  in "Green" below. `DIFFERENT` at that point should not happen: run the gate once; red →
  merge nothing more, stop the loop and say so.
- `DIFFERENT`, `CONFLICT`, or no `.afk/green.tree` (a green ticket held back, an
  integration pass red or skipped) → the gate after each merge, as below.

afk stacks: a blocked ticket's branch starts from its blocker's. Merging it before its
blocker brings the other one's work in through a merge that does not say so.

```bash
grep -h '^base_ref=' .afk/*.status        # the chain, ticket by ticket
# before merging a blocker: move the PRs stacked on its branch onto $base
gh pr list --base <blocker branch> --json number -q '.[].number' |
  xargs -r -I{} gh pr edit {} --base "$base"
gh pr merge <n> --merge --delete-branch   # in order: blocker first
```

`--merge`, not `--squash`: a squash rewrites the blocker's commits, and the dependant
brings them back a second time.

The retarget comes first because `--delete-branch` deletes the branch through the API,
and GitHub then **closes** the PRs based on it instead of moving them; a closed PR's base
can no longer be changed (defect 53).

A PR that GitHub says conflicts, on the glossary only (`GLOSSARY.md`, `GLOSSARY-MAP.md`, or
`CONTEXT.md` / `CONTEXT-MAP.md` in older repos): merge `$base`
into its branch locally and push. afk sets those files to `merge=union` in
`.git/info/attributes`, so git keeps both sides' lines (defect 51); then reread the merged
file and drop the notes a landed ticket made false ("X does not exist yet").

**After each merge**, unless the trial above said `SAME`, the gate on `$base` (`git pull -q`
first: the merge happened on GitHub):

```bash
<VERIFY_CMD>; echo "rc=$?"
```

Green after the last merge → record it, so the next run does not gate this content again:

```bash
printf '%s\n%s\n' "$(git rev-parse 'HEAD^{tree}')" '<VERIFY_CMD>' > .afk/green.tree
```

Red → the merge that just arrived breaks what was working. Revert it
(`git revert -m 1 HEAD`), take the ticket out as `ready-for-human` with the gate's output
as a comment, and carry on with the next ones. A single bad ticket does not cost the
wave.

Green → close the ticket. The PR's `Closes #<ticket>` only fires on a merge into the
repo's default branch, and `$base` usually is not it:

```bash
gh issue close <ticket> --comment "Landed on $base by PR #<pr>."
```

Then delete what a remote builder (`AFK_BUILD_CMD`) left on the remote for this ticket:
the `afk-base/<ticket>` it pushed to start from, and its own branch `feat/<ticket>-<k>`
that afk copied into `feat/<ticket>`. Only those already contained in `$base`:

```bash
git fetch -q origin
for b in $(git ls-remote --heads origin "afk-base/<ticket>" "feat/<ticket>-*" | sed 's#.*refs/heads/##'); do
  git merge-base --is-ancestor "origin/$b" "origin/$base" && git push -q origin --delete "$b"
done
```

## 4 — Checking off

For each unchecked criterion of the current milestone, its command, on `$base`, exactly as
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
repo — `/afk-debrief` says which ones. Nothing to record is the normal case. The next
number is the highest one in `docs/defects.md` **and** `docs/defects-fixed.md` plus one,
and a defect already there gets an "Again" paragraph, not a new number.

## 6 — The milestone

All of a milestone's criteria checked → close its milestone and say which one starts:

```bash
gh api -X PATCH repos/{owner}/{repo}/milestones/<id> -f state=closed
```

## 7 — Deciding

`afk-app.sh` decides, by counting the boxes and the open tickets — never from this
report. The report says which case holds, so the morning reads the same verdict:

| | what you say |
|---|---|
| every criterion checked | done — `$base` is ready to be merged into `master`, by a human |
| **two waves in a row without a single criterion being checked** | the loop is not moving. Name the criterion that blocks and what `/afk-debrief` says about it |

"The wave went badly" is not a stop: one red wave in three is the normal regime, and the
next one re-slices smaller.

In every other case the report says `Next: /afk-wave`. Do not run it: the loop does.

## 8 — Reporting

Short, it is read on waking up, in series with the other waves:

```
Wave 4 — 3 tickets, 2 merged, 1 taken out
Checked: A7 A8   (14/26)
Out    : #61 — the gate on the landing branch breaks after merging, revert done
Next   : /afk-wave (milestone 2)
```

## What this skill does not do

- **It never merges into `master`.** The landing branch only. The last merge is a human decision, and
  it is the only thing left to be one.
- **It checks off no criterion whose command it has not run itself.**
- **It does not modify the text of `docs/spec.md`** — only `[ ]` into `[x]`. A criterion
  that turns out to be impossible is flagged in the report and stops the loop; it does
  not get rewritten.
- It opens no ticket: that is `/afk-wave`.
- It does not review the greens' code. The gate and CI are what we have; widening them
  is a `.afk.env` change, not an end-of-wave judgement.
- It does not relaunch `afk.sh`.
