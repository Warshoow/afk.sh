---
name: afk-spec
description: "Turns an app idea into a repo afk can work on alone — picks the stack, writes docs/spec.md where every criterion carries the command that proves it, builds the skeleton that starts, the CI, the .afk.env, and sets up the milestones. Run once, at the very beginning, before the first wave. Triggers: /afk-spec, \"I want to build <idea>\", \"set up the repo for this idea\", \"write the spec\", \"wave 0\"."
---

# /afk-spec

An idea is not executable. This skill makes it executable: a repo that starts, a gate
that passes, and a list of criteria where **each one names the command that proves it**.
After that, `/afk-wave` and `/afk-merge` loop with nobody watching.

It is the only step of the loop worth reviewing awake: it picks the stack for everything
else, and it writes the only judge the loop will ever have.

## The rule that holds up all the rest

**`docs/spec.md` is written here and never changes again.** The later waves are only
allowed to check boxes — not to add, not to reword, not to remove a criterion.

Otherwise the loop declares itself the winner all by itself: whoever writes the criteria
and whoever fills them are the same model. It is the only failure mode that shows up
nowhere in the summary.

## 1 — The idea, and what it excludes

One sentence for what the app does. Then, explicitly, **what it will not do**:
anything not in the spec will never be built, and that is deliberate — the agent will
not catch an omission, it will invent.

Too big for a spec ("a Notion", "a CRM") → say so and propose the first slice that stands
on its own. A loop over fifty criteria spends its nights piling up code nobody reviews.

## 2 — The stack

The most boring one that holds. Two constraints, in this order:

- **the gate runs with no external service.** Each ticket runs in a throwaway worktree:
  a live Postgres, a Redis, a `docker compose` and every ticket dies red for a reason
  that is not its own. File-backed SQLite, in-memory server, fake client — it is a wave-0
  decision, not a detail.
- **the model knows it without looking things up.** A niche stack costs one documentation
  session per ticket, every night.

One line of justification per choice, in the `README.md`. Nobody will reread it before
six months.

## 3 — The criteria

The heart of the skill. A criterion is written like this:

```markdown
- [ ] **A3** — `POST /tasks` with a title returns 201 and the created id.
      `pnpm vitest run tests/api/tasks.spec.ts -t "creation"`
```

Three parts: a stable number, the sentence, **and the command that returns 0 when it is
true**. The test file does not exist yet: the path is an instruction for the ticket that
will take this criterion.

**The test, before writing anything: which command returns 0 if it is true, and non-0
otherwise?** No answer → it is not a criterion, it is a wish. Rewrite it or drop it.

| Wish | Criterion |
|---|---|
| "the user can create a task" | `POST /tasks` returns 201, and the task shows up in `GET /tasks` |
| "the interface is pleasant" | (not a criterion — see below) |
| "it is fast" | `GET /tasks` over 1000 rows answers in under 200 ms |
| "errors are handled" | `POST /tasks` without a title returns 400 and an `{error}` body |

What no command judges — a layout, an animation, a tone — **does not go in the spec**. It
gets handled later, ticket by ticket, with a `Gauntlet: <reference>` line once you have a
reference to aim at. A taste criterion in the spec blocks the loop forever or gets
checked off blind.

The first criterion is always the same: **A0 — the app starts**, with the command that
proves it. It is the one that catches "every ticket is green and nothing runs".

Aim for 10 to 30 criteria. Below that, the spec does not describe an app; above it, slice
the idea.

## 4 — The milestones

Group the criteria into ordered milestones, each one a thing that stands on its own
("the API answers", "you can log in", "the list screen"). A milestone is done when all
its criteria are checked. `/afk-wave` never works two milestones at once.

A milestone only depends on the previous ones. If two milestones claim each other, it is
one milestone.

```markdown
## Milestone 1 — The API answers
- [ ] **A0** — …
- [ ] **A1** — …

## Milestone 2 — Persistence
- [ ] **A4** — …
```

## 5 — The skeleton

The minimum for **A0 to pass and nothing else**. No empty screen "for later", no `utils/`
folder with nothing in it: every file that exists here is a file an agent will believe it
has to respect.

```bash
<A0's command>; echo "rc=$?"
```

`rc=0` or the skeleton is not done.

## 6 — The rest of the apparatus

In this order, each one a prerequisite for the next:

```bash
/mattpocock-skills:setup-matt-pocock-skills   # docs/agents/issue-tracker.md, the labels
/afk-setup                                     # .afk.env, the proven gate
```

Without the first, `afk.sh` refuses to start. Without the second, the gate will be a pnpm
monorepo's.

Then a CI that runs the same gate as `VERIFY_CMD` — it is what will verify the PRs, and
`/afk-merge` merges nothing without it.

## 7 — Setting the markers

```bash
git commit -am "chore: spec, skeleton and gate"
git tag afk-spec                     # the spec's reference version
git branch dev && git push -u origin dev
echo 'BASE_BRANCH="${BASE_BRANCH:-dev}"   # the loop lands on dev, never on master' >> .afk.env
```

`BASE_BRANCH=dev` is not optional: without it the worktrees start from `master` and the
PRs target it — every ticket would then ignore everything the previous waves delivered.

The tag is the guard: `/afk-wave` and `/afk-merge` compare `docs/spec.md` with
`git show afk-spec:docs/spec.md` and refuse to run if anything other than boxes moved.

`dev` is the landing branch. **`master` is never touched by the loop** — you merge `dev`
yourself, awake.

Finally, one GitHub milestone per milestone, in order:

```bash
gh api repos/{owner}/{repo}/milestones -f title="Milestone 1 — The API answers"
```

That is where `/afk-wave` will hang its tickets. No extra state file: the spec carries
the criteria, GitHub carries the tickets and the milestones, git carries the rest.

## 8 — Show, then wait

Show the spec and the stack, **wait for approval**. It is the only stopping point of the
whole loop — after it, nobody reviews anything before you wake up.

What matters in that review: does the list of criteria, once all checked, describe the
app you wanted? If not, it is now, not in three waves.

## What this skill does not do

- It does not run `afk.sh` and opens no ticket: that is `/afk-wave`, once the spec is
  approved.
- It writes no application code — only the skeleton that makes A0 pass.
- It does not put in the spec what no command judges.
- It never comes back to `docs/spec.md` after the tag. If the spec is wrong, that is a
  human decision: fix it, re-tag, and say so.
