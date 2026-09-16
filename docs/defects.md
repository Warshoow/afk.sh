# Defects

What broke **in afk**, for real, during a run. One defect per entry, numbered, dated,
with the project and the ticket where it showed up.

Here and nowhere else:

- [CHANGELOG.md](../CHANGELOG.md) says what **changed** for the user. It does not say
  what the change cost before it was made.
- [proposals.md](proposals.md) says what was **considered** and why it was decided. A
  proposal starts from an idea, a defect starts from damage.
- [RUNS.md](../RUNS.md) gives the **facts** of each run, appended by `afk.sh`. A defect
  is a judgement passed on them.

Projects are named by the same stable digest as in [RUNS.md](../RUNS.md) — a digest of the
repo directory name, so the same project always yields the same value and its runs and its
defects can be cross-referenced without the name being disclosed.

**What has no business here**: the worked-on project's problems. A flaky test, a badly
tuned gate, a badly sliced ticket get fixed in that project. Only what would have broken
the same way on any repo is recorded here.

Written by `/afk-debrief` when going through a run, or by hand. Continuous numbering,
verdict in the title: **fixed**, **mitigated** (the damage is reduced, the cause remains)
or **open**.

**This file only keeps the live defects** — open and mitigated. A fixed defect moves to
[defects-fixed.md](defects-fixed.md): the numbering is shared and continuous,
`grep -rn 'defect 17' docs/` finds both. The split exists because a debrief reads this
file end to end, and thirty closed entries cost as much to read as the four that still
need a decision.

Defects 1 to 32 were observed before this file existed. They are carried over here from
the log kept in the repo where they came out — `docs/agents/afk.md` of project-6c618d6f, which
keeps the long detail, the measurements and the slicing lessons. Here we only keep the
defect. **18** is missing: it was a problem of that repo (a generated, gitignored file,
therefore absent from a fresh worktree, which made its gate fail), it has nothing to do
with afk and it only appears as the thing that revealed defect 20.

---

## 10 — The global gate pushes the agent outside its ticket's scope — mitigated

*2026-08-19 · project-6c618d6f · #44, quantified on #64 on 2026-08-21*

**What was seen.** The prompt demands "no off-topic files", the gate demands a
repo-wide `typecheck`. On #44, labelled `[backend]`, removing a field from a transformer
broke the client's typecheck: the agent had to modify 10 mobile files to get green, and it
was right. On #64, the same mechanism on a bigger scale — 31 files, +1342/−538, including
220 insertions on the mobile side for a ticket announced as "backend + types + docs".

**The cause.** The two constraints contradict each other as soon as a ticket touches an
end-to-end typed contract. It is not a bug of the script: it is the interaction between its
gate and the slicing. **Slicing by app is incompatible with a repo-wide gate.**

**What was done about it.** A ticket can declare `Verify: <cmd>` in its body; the script
uses that instead. The prompt acknowledges the tension: if holding the scope makes the gate
unreachable, do the minimum outside the scope **and write it into a decision**. The root
issue stays a slicing problem — vertical slice, not app — and it belongs to whoever writes
the tickets.

## 20 — A green gate does not prove it ran — mitigated

*2026-08-31 · project-6c618d6f · batch of 8*

**What was seen.** The gate was **green on all 8 tickets** and **red at integration**, on
an error that hit every fresh worktree the same way. It printed
`admin:typecheck $ tsc -b --noEmit` and a `✓` without compiling a line.

**The cause.** The build cache computes its key over the files **tracked by git**. A
generated, gitignored file does not enter the key: a fresh worktree that has not produced it
yields **the same fingerprint anyway** as the main repo that has → cache hit, logs replayed,
compiler never launched. Integration, on the other hand, presents a combination of contents
never seen before → cache miss → real execution → the errors come out. And the cache is
**shared between the worktrees**, which makes a false green travel from tree to tree.

**What was done about it.** `INTEGRATION_VERIFY_CMD` separates the integration pass's gate
from the tickets', and the project puts the uncached form (`--force`) there. Too expensive to
pay on every ticket, indispensable on the combination: it is the only verdict that counts.

**What remains.** Nothing flags that a *ticket*'s gate did not run. `Cached: n cached` in
the build output is a **safety signal**, not a performance statistic: a "7/7" gate fully
cached verified nothing. It is the line to read before believing a green.

## 21 — A reduced `Verify:` no longer reduces when the ticket overflows — mitigated

*2026-08-31 · project-6c618d6f · #113*

**What was seen.** 23 interface tickets carried a `Verify:` without the tests, absent from
their half of the repo. #113, labelled `[mobile]`, added a **server route**, modified a
controller and **three** test files. Its local gate could not run them: it had been cut from
the ticket's label. Only the PR's CI covered them — green, so the case holds, but the
guarantee held through CI, not through the gate.

**The cause.** A ticket's declared scope is a **prediction**. Reducing a gate must reduce its
**duration**, never its **coverage** — or else you have to accept that CI is the only gate
that counts and that the local gate is merely a fast filter.

**What was done about it.** It is the second branch that is accepted, and it is now
**written where it gets read**: a PR whose local gate was reduced says so in its body, with
the repo's complete gate, so you know what was seen only by CI; its line in the summary
carries a ⚠.

**What remains.** The root issue is a slicing problem, not a tooling one. The pattern that
predicts a lying label, found after three occurrences and readable in the criteria without
opening the code: an interface ticket touches the server as soon as it makes **new data
appear**, **reads data the server still bounds**, or **the route it needs does not exist**
(its predecessor only delivered part of the CRUD).

## 24 — A stale reference is not a conflict, nobody flags it — mitigated

*2026-08-31 · project-6c618d6f · batch of 5*

**What was seen.** One branch writes "it is **#116** that will open this list"; #116 opens the
list in the same run; nobody rewrites the sentence — neither the branch that wrote it (it is
finished), nor #116 (it does not know it is quoted). Both sides agree on those lines, git
merges them silently, and the repo's docs state in the future tense what has been delivered
for ten minutes. **Five** references of this kind in a single batch, across four files, two
of which no PR review would have caught because they are in no branch's diff — a document
**inherited as-is** by a stacked branch.

**The cause.** It is the hidden half of the rule "on a conflict, do not pick a side without
reading both": it assumes there is a conflict. The most frequent drift produces **none**.
Neither git nor afk is wrong — no gate sees a sentence that has become false.

**Seen in two other guises since.** The **duplicate bullet**: two tickets document the same
module in two different places of the same file, git sees no conflict, and the merged tree
describes the same module twice with two APIs, one of them wrong. And the **stale reference
from the other end**: a ticket deletes a screen and updates its references, except the one in
a file a neighbouring ticket had written the day before and that it never reopened.

**The lead.** It is a review step, and it is mechanisable — so afk could carry it, after the
merges:

```bash
# the batch's tickets cited in the future tense
grep -rnE "#(107|116|88|89|94)[^0-9]" --include=*.md --include=*.ts --include=*.tsx . \
  | grep -v node_modules \
  | grep -iE "will open|will arrive|will come|will be|not yet|by then|it is #[0-9]+ that|remains "

# the same file/module documented twice
grep -rn '^- `' --include=CLAUDE.md --include=CONTEXT.md . | grep -v node_modules \
  | sed -E 's/^([^:]+):[0-9]+:- `([^`]+)`.*/\1 \2/' | sort | uniq -d
```

A run log must come out of the first filter: its entries are historical, they **must** stay
in the past tense of their date.

**What was done about it (2026-09-04).** Detection only, and on `.md` only: the integration
pass lists the run's tickets cited in the merged docs, with their file and their line. It
does not judge the sentence — that would need a list of future-tense verbs, which would be
wrong as soon as the language or the style changes. It says where to look, which is exactly
what was missing: those references are in no branch's diff. The duplicate bullet and the
stale reference from the other end stay invisible.

---

## 40 — "absorbed" does not tell "already delivered" from "blocked, the agent refused" — mitigated

*2026-09-09 · project-84812fac · #114*

**What was seen.** #114 deleted `agent.py` and `app/llm/`. The session exited in 7m20
without a commit, with an explicit verdict: *"#114 cannot be done now — blocked by
#107/#108/#109, not merged into this base yet. No change made."* It cited the three callers
still alive, file and line. afk ran the gate on the base, found it green, and concluded
**absorbed**: the ticket moved to `in-review` with a comment telling it to *"check then
close"*. The files to delete are still there.

**The cause.** `absorbed` is decided on two facts — no commit, green base — and nothing
else. That was the fix for a real defect: a ticket emptied by its predecessor burned both its
attempts then went to `ready-for-human` for a false reason. But the gate on the base proves
nothing about a ticket's content: it is green because the repo compiles, not because the
deletion happened. A deletion ticket is the species where the gap shows, it is not the only
one — any ticket the agent judges too early comes out this way. And the verdict is not
neutral: it relabels and invites closing, so it makes the ticket disappear from the next
batch.

**What was done about it (2026-09-09).** The third case exists. The prompt asks the session,
when it commits nothing, to name its case on its last line: `AFK: ALREADY DONE`, or
`AFK: BLOCKED <what is missing>`. The second comes out **frozen** — the same verdict as an
unlifted blocker, because it is the same fact, said by the session instead of the scheduler:
label unchanged, no PR, a comment citing what is missing, no second attempt (same session,
same base, same conclusion), and the ticket starts again on the next run. Without the line,
the gate on the base decides as before.

Mitigated and not fixed: the witness is the session itself. A session that refuses without
saying so passes for absorbed again. Telling it apart *without* reading its text was ruled
out — requiring a blocker delivered in this run breaks the original case, a ticket the repo
had already delivered before the run has no blocker in this run (see docs/proposals.md).

---

## 41 — The "Model" column counts the subagents and makes you read a fallback that did not happen — mitigated

*2026-09-09 · project-84812fac · #111*

**What was seen.** #111 carried `Model: sonnet`, the orchestrator's trace prints
`model       : sonnet`, and the summary puts `opus-5 sonnet-5` in its "Model" column. The
legend under the table says that a model other than the one requested means `FALLBACK_MODEL`
kicked in — so, read that way, sonnet would have been unavailable. It is the opposite:
sonnet held for the whole session, opus only ran in the two `reviewer` subagents the session
spawned, and which the repo pins to opus in `.claude/agents/`.

**The cause.** `jmodels()` collects every `canonicalModel` from `modelUsage` and returns them
deduplicated. `modelUsage` aggregates the session **and** its subagents, which carry the
model of their definition and not the ticket's. So the column measures "which models were
billed" where its legend promises "which model answered". This hits any repo whose
`.claude/agents/*.md` name a model, and that is precisely the case of repos where a review is
asked for before committing.

**What was done about it (2026-09-09).** `subagent_stats.spawned` is read (`jspawned`) and
shown with the models, not in a column of its own: `sonnet-5 (+2 subagents)`. It is what says
whether a second model is a fallback or a review, and it explains part of the cost at the
same time, since the cost aggregates the subagents like `modelUsage` does. The legend now
says what is true: several models **without** a subagent = a fallback; with subagents, they
carry the model of their definition and not the ticket's.

Mitigated and not fixed: the column still does not say *which* of the models was the
session's. The first `modelUsage` is (the session calls the API before any subagent exists),
but relying on that makes a mid-session fallback invisible — the full list plus the number of
subagents lie about nothing.
