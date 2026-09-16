# Fixed defects

The archive of [defects.md](defects.md): what broke in afk, for real, during a run, and
does not break any more. Same numbering, same writing rules — only the verdict changes,
and it is the verdict that decides the file.

They are kept because a fix gets reread: the correction is in `afk.sh` next to the code,
but what the defect cost before it was seen is written only here. A code comment pointing
at "defect 17" points at this file as soon as 17 is fixed.

---

## 1 — SSH passphrase asked for at every git operation — fixed

*2026-08-18 · project-6c618d6f · #38*

**What was seen.** `Enter passphrase for key …` **twice per ticket** — once on the base's
`git pull`, once on the `git push`. Over 13 tickets, ~26 interactive prompts in a tool whose
name means "away from keyboard". Seen again on #44, worse: the `git push` slept in `S+`
without printing anything, and from the user's side it looked exactly like a ticket taking
its time. Nothing in the output told "I am computing" from "I am waiting for your keyboard".

**The cause.** Remote on SSH, key protected by a passphrase, neither `ssh-agent` nor
`ssh-askpass` in the container. Detached — with no tty — the push fails outright instead of
asking, and the pushed work is lost.

**What was done about it.** `github.com` is rewritten to HTTPS for the duration of the run
(`GIT_CONFIG_COUNT` / `KEY_n`, never `.git/config`), the token served by
`gh auth git-credential`. `GIT_TERMINAL_PROMPT=0`: detached, it fails cleanly instead of
sleeping. Verified in the container — SSH fails, HTTPS passes, no token on disk.

## 2 — The "decisions captured" check only understands a single context — fixed

*2026-08-18 · project-6c618d6f · #38*

**What was seen.** The agent had updated `apps/mobile/docs/adr/0002-…` — so it *had*
captured its decision — and the warning "no CONTEXT.md or ADR touched" fired anyway. A false
positive every single time on this repo.

**The cause.** `grep -qE '^(CONTEXT\.md|docs/adr/)'` over the diff. A repo filing its
glossaries under `apps/*/CONTEXT.md` and its ADRs at two levels misses systematically.

**What was done about it.** `MEMORY_RE`, overridable, covers `CONTEXT.md`, `CONTEXT-MAP.md`,
`(apps|packages)/*/CONTEXT.md`, `docs/adr/` and `(apps|packages)/*/docs/adr/`.

## 3 — The "no CONTEXT.md" guard rail is a false negative — fixed

*2026-08-18 · project-6c618d6f*

**What was seen.** "The agents will have no project memory" at every launch, although the
memory exists and the agents find it.

**The cause.** Same as 2: the guard rail looked for a `CONTEXT.md` at the root, and this repo
has a `CONTEXT-MAP.md` pointing at a per-context `CONTEXT.md`.

**What was done about it.** The check accepts `CONTEXT.md`, `CONTEXT-MAP.md`, `docs/adr/` or
any `*/*/CONTEXT.md`.

## 4 — `DRY_RUN=1` inspected nothing — fixed

*2026-08-19 · project-6c618d6f · #44 #46*

**What was seen.** `DRY_RUN=1 afk 44 46` said nothing about #46 being blocked by #44. And
since the "dirty tree" guard rail was upstream, the plan could not even be consulted while a
file was lying around.

**The cause.** The script exited **before the loop**, so it never called `blockers()`: no
base, no stacks, no frozen.

**What was done about it.** The loop is walked dry — branch, base, absorbed branches,
effective gate, effective `Timeout:`, frozen — without launching `claude`. The clean-tree
check moved **after**.

## 5 — A stacked ticket's base depended on the listing order — fixed

*2026-08-20 · project-6c618d6f*

**What was seen.** Nothing, and that is the point: `base="${stack[-1]}"` happened to be right
on the 13 tickets of the moment because the edges had been created in topological order. Pure
luck.

**The cause.** For a ticket with several blockers, the base must be the **deepest** blocker.
The script took the **last one listed** by the API, i.e. the edge insertion order. One edge
added by hand later, and the stacked PR shows a diff inflated with its siblings' content.

**What was done about it.** `deepest_branch()` picks the blocker that already contains the
others (`git merge-base --is-ancestor`), falling back on the last one listed if none
dominates. Covered by `check.sh` on a real throwaway repo.

## 6 — Labelling failures were swallowed — fixed

*2026-08-19 · project-6c618d6f*

**What was seen.** An abandoned ticket **lost** `ready-for-agent` without gaining anything:
it disappeared from the orchestrator's query *and* from a human's.

**The cause.** `gh issue edit … >/dev/null 2>&1`, and the failure label did not exist yet on
the repo. The `--add-label` failed silently.

**What was done about it.** The labels are created at startup if they are missing — without
`--force`, so as not to repaint an existing label — and `relabel()` prints `gh`'s error
instead of throwing it away.

## 7 — The label was removed before any human review — fixed

*2026-08-19 · project-6c618d6f*

**What was seen.** On success, `ready-for-agent` went away as soon as the PR opened. PR
refused, ticket picked up by nobody.

**What was done about it.** An intermediate state: `ready-for-agent` → `in-review`. afk never
picks an `in-review` ticket back up through a label listing; an explicit list drops it with a
message (`ALLOW_REVIEW=1` to force), otherwise a second `gh pr create` on the same branch
fails.

## 8 — A crashed session was counted as a success — fixed

*2026-08-19 · project-6c618d6f · #44*

**What was seen.** The session ended on `Execution error` — a 314-byte log against ~2 KB for a
healthy run, so `rc != 0`. Then: the safety net commits the dirty tree, `HEAD != head0` becomes
true **thanks to the net itself**, verification passes, the PR opens, the label goes, and the
summary announces "green on 1st attempt: 1/1". Nobody learns the agent never finished.

**The cause.** The verdict was drawn from the diff, not from the session's exit code. Here the
work happened to be complete; nothing guaranteed it — **an agent crashing at 60% produces
exactly the same green output**, since `typecheck` and `lint` do not know what is missing. And
`MAX_ATTEMPTS` was never used, the retry being short-circuited by the apparent success.

**What was done about it.** `rc != 0` or timeout → PR opened **as a draft**, exit code and log
path in the PR body, ticket excluded from "green on 1st attempt" and listed as `draft` in the
summary. The work is never thrown away; a human is the one who leaves draft.

## 9 — The safety net's commit message landed in the PR — fixed

*2026-08-19 · project-6c618d6f · #44*

**What was seen.** The catch-up commit was called `wip(#N): work not committed by the agent`.
On #44 it was the **only** commit of a 625-line batch, so the message `master` would have
kept. Reworded and force-pushed by hand.

**What was done about it.** `feat(#N): <ticket title>` (`fix` if the ticket carries `bug`), and
a triggered net marks the PR as a draft: not committing is an anomaly, not a success.

## 11 — Verification never saw the combination of the branches — fixed

*2026-08-19 · project-6c618d6f · #45 × #40*

**What was seen.** Each ticket was verified on its branch **alone**. Two branches green in
isolation produced a `CONFLICTING` on GitHub's side, over two files neither scope announced —
a `CLAUDE.md` and a neighbouring component.

**The cause.** An agent touches wider than the announced scope; a ticket describes an
intention, not a file list. The risk grows with the size of the batch and with the stacks,
where a PR's base is an unmerged branch.

**What was done about it.** An integration pass at the end of the run: every green branch
merged into `afk-integration`, then the gate. It reports the conflicts with their files and
the crossed breakages, and touches no PR (`INTEGRATION=0` to skip). It does not remove the
problem — that would require knowing what an agent will touch before it runs — it moves the
discovery from merge day to the end of the run.

## 12 — The repo's CI was never consulted — fixed

*2026-08-20 · project-6c618d6f*

**What was seen.** Five tickets green on afk's side, and CI **red on all five** — a container
left on the runner was holding a port, so the Postgres service did not start and the job died
before the `checkout`: no test had run for three weeks. afk pushed, opened the PRs and removed
the labels without ever asking GitHub.

**The cause.** `VERIFY_CMD` runs locally, and nothing read the other gate. The point is not
the outage, it is the silence: **a ticket can be delivered, labelled and merged although CI
never ran on it.**

**What was done about it.** After the PR, `gh pr checks --watch` bounded by `CI_TIMEOUT`. Red →
ticket moved back to `ready-for-human` with a comment. Timeout or no checks → a warning, the
run continues: a broken CI informs instead of freezing. (See defect 29, which reopens the
subject through the last ticket's door.)

## 13 — Nothing detected a ticket that had become empty — fixed

*2026-08-21 · project-6c618d6f · #64 → #65 #66*

**What was seen.** #64 came out green **having done #65 and #66 in full**. Without a manual
cut, the next two started from `feat/64`, found nothing to do there, produced no commit →
`no commit — the agent produced nothing`, two attempts each, then `ready-for-human` **for a
false reason**. Up to four sessions for nothing, and two tickets labelled as failures although
they were delivered.

**The cause.** The script did not tell "the agent failed" from "there was nothing left to do":
both came out as `no commit`.

**What was done about it.** "No commit" is no longer a verdict: the gate then runs **on the
base**. Red → the agent produced nothing, as before. Green → a third result, **`absorbed`**:
`in-review` + comment, no PR, neither red nor "green on 1st attempt", and its dependants start
from the base it used itself instead of freezing behind a false failure.

Corollary measured afterwards: "absorbed" **is not predictable** from criteria overlap. Two
predictions, wrong both times — a ticket with four of six criteria already met still produced
six files of real work. Launch the successor rather than closing it on sight; the gate decides
better.

## 14 — `TIMEOUT` was global while a ticket's size is not — fixed

*2026-08-21 · project-6c618d6f · #64*

**What was seen.** #64 consumed all 60 minutes without committing (31 dirty files at 58:29),
the `timeout` fired, the net committed, the gate passed. Result: a draft PR and a ticket out of
"green on the first attempt", although the work was complete and CI confirmed it.

**The cause.** A single default sized for an average ticket. A rework ticket — migration,
formula, purge, guards, tests, docs — does not fit in it.

**What was done about it.** A `Timeout: 90m` line in the ticket body, symmetric with `Verify:`:
same place, same parser, tested by `check.sh`. `timeout(1)`'s format; a value of any other
shape is **ignored** rather than passed on, otherwise a badly written ticket would stop the
session from starting. The cut-off message reminds you the line exists. First time it paid
off: a 49-minute ticket which, at the 45-minute default, would have been killed and counted
red — at the head of the batch's deepest chain.

## 15 — A green ticket's worktree survived the orchestrator's death — fixed

*2026-08-21 · project-6c618d6f*

**What was seen.** Killing the orchestrator between a worker's exit and its reaping left the
worktree in place with `feat/<n>` **checked out in it** — which the plan then refuses for any
future run on that ticket.

**The cause.** `drop_worktree` was only called by the reaping, so inside the loop.

**What was done about it.** `trap … EXIT INT TERM`: kills each worker's **descendants** (the
worker is a subshell, `claude` and the build commands are under it — killing the subshell alone
left them orphaned and alive), then collects the worktrees of the green or absorbed tickets.
The reds and the interrupted ones stay: that is where we go to read.

## 16 — The integration pass announced a verdict without its scope — fixed

*2026-08-24 · project-6c618d6f · batch 68-71*

**What was seen.**

```
merge feat/69  ✓
merge feat/70  ✗ CONFLICT
→ verification … ✓ the whole compiles
```

"The whole" only covered **two branches out of three**. The verdict is accurate — it simply
does not say what it is talking about, and it falls *after* the line that amputated it. Read in
the summary, it reads "the three branches combine", which was precisely the open question.
Confirmed worse on the next batch: `afk-integration` carried 6 branches out of 8, and the
announced red came from a cause (defect 20) unrelated to the conflict cited on the same line —
two independent failures, one report line.

**What was done about it.** The verdict carries its scope — "the whole compiles — PARTIAL: 6/8
branches, without `feat/110` `feat/113`" — in the output **and** in `summary.md`, which lists
the branches actually merged. Along the way: a **refused** merge (dirty tree, missing base) is
written `REFUSED` with git's reason, not `CONFLICT` — it is not the same information and it
sent you looking in the wrong place.

## 17 — Test databases shared between worktrees — fixed

*2026-08-28 · project-6c618d6f · #82*

**What was seen.** In parallel, healthy tickets came out red, with migration errors that did
not talk about their code. The same ticket relaunched alone went green.

**The cause.** The test database name was hardcoded in a versioned `.env.test`. Every worktree
copied the same one, and a neighbour's `migrate()` / `rollback()` emptied the database from
under the current ticket's tests. The gate marked the ticket red for someone else's work — the
worst possible case, since nothing in its trace points anywhere but at itself.

**What was done about it.** `afk.sh` exports `AFK_TICKET` and `AFK_WORKTREE` before
`SETUP_CMD`, which already runs under the `install` lock. It is up to the project to isolate
itself with them — one database per ticket number, a port, a bucket: it alone knows what it
must isolate from. The README gives the example, section "Isolating a worktree from its
neighbours".

## 19 — `gh issue list` caps at 30 without saying so — fixed

*2026-08-31 · project-6c618d6f*

**What was seen.** On a repo with 41 open tickets, the dry plan showed 30 tickets and
**6 "blockers open outside the run"** that were nothing but tickets that had fallen outside the
slice. A silent freeze: no error, no warning, a plan that looks complete.

**The cause.** The listing of labelled tickets was done without `--limit`. `gh`'s default is
**30**, and it returns the most **recent** ones.

**What was done about it.** `--limit 500`. It is the first defect on the list that strikes
**before** the run, at plan time — where you trust what you read the most.

## 22 — Nothing detected two tickets claiming the same number — fixed

*2026-08-31 · project-6c618d6f · batch of 8*

**What was seen.** One batch produced **three** ADRs `0018-…` and **two** migrations `…034_…`.
None of these duplicates flags itself: the file names differ, so git sees no conflict; it
compiles; the tests pass. The gate is mute by construction.

**The cause.** A sequential number is a shared namespace, and each worktree starts from its base
without seeing its neighbours. Each agent took the free number it could see, and it was right.

**What was done about it.** `clashing_numbers` receives the files **added** by the run's
branches and returns one line per clash: same directory, same leading numeric prefix, several
files. Generic — ADRs, migrations, any `NNN_name` convention — replayed at the integration pass,
covered by `check.sh` with the batch's two clashes as a fixture. Reapplied to the 8 branches, it
finds exactly what the manual review had found; on the next batch it stayed silent, rightly,
which counts just as much.

**Seen four times since, and the cost varies from 1 to 25.** The detector fires, but the repair
is **not** a `git mv`: one merged tree carried **25 references** to "ADR 0009" across **10
files**, each with a `§N` that only means something against *its* document. Two practical rules
came out of it:

- **the number stays with whoever cites it most** (`git grep -c` settles it in one command: 12
  references against 1, 9 against 6);
- a renumbering `sed` **misses references broken by a line wrap** — `grep -rn "mobile ADR$"`
  finds them, and nothing else would, an ADR number not being a reference the compiler follows.

Which follows from the same observation: **the better an agent documents, the more a clash
costs.** The real remedy is not fewer references, it is handing out the number **before** the
run, in the ticket body, rather than letting it be discovered.

## 23 — The summary announced "integration" twice — fixed

*2026-08-31 · project-6c618d6f*

**What was seen.** Two consecutive lines with the same name, one for the conflict and one for
the verdict, read as two contradictory verdicts — all the more so since the verdict carries its
scope (defect 16).

**What was done about it.** A single line, with the conflict as an actionable suffix.

## 25 — Nothing flags two branches that **create** the same file — fixed

*2026-09-01 · project-6c618d6f · #95 × #96*

**What was seen.** Two tickets created `apps/mobile/lib/equipment.ts` — the same need seen from
both sides of the same list — with two different APIs, both of them right. Both branches are
green alone, both CIs are green, and **no gate can see the problem**: each compiles perfectly
without the other. Only the integration pass said so, as `CONFLICT (add/add)`, and only because
it ran.

**The cause.** afk **already has the material**: `numbering_clashes` collects the files added by
each green branch. Two things stop it from serving:

1. `clashing_numbers` only looks at names **starting with digits**, it is defect 22's detector;
   an ordinary path never enters its awk;
2. and above all its input `sort -u` **crushes the very case** we want to catch: two branches
   adding the **exact same path** produce two identical lines, deduplicated before any counting.
   What makes the number detector correct is exactly what blinds the path detector.

**The lead.** Count the added paths **before** the `sort -u`, and flag any path added by more
than one branch. One trap to avoid, otherwise the cure makes more noise than the disease: a
**stacked** branch contains its base's commits, so it also "adds" its blocker's files. Each
branch must be diffed against **its** base — the one the plan already prints and `<n>.status`
writes — and not against the common base.

**What was done about it (2026-09-04).** `same_path_adds` counts the added paths **before** any
deduplication and flags those added by more than one branch. The announced trap is avoided: each
branch is diffed against **its** base, read from `<n>.status`, and not against the common base —
otherwise a stacked branch would also "add" its blocker's files. `numbering_clashes` eats the
same list, it loses nothing.

## 26 — The integration's conflicting files are written nowhere — fixed

*2026-09-01 · project-6c618d6f*

**What was seen.** `summary.md` says "set aside at merge: feat/91 feat/104 feat/96". It does
**not** say on what. `integration-merge.err` is useless: it is overwritten at every branch, so
at best it carries the last one, and it was **empty** — git reports the `CONFLICT`s on stdout,
not on stderr. Terminal closed, it had to be rebuilt with `git merge-tree --write-tree
--name-only` on each branch, which assumes guessing the original merge order.

**The cause.** And yet the information exists: `integration_check` computes it
(`git diff --name-only --diff-filter=U`), prints it to the console… and throws it away.

**Seen twice, on a second output.** Same story for defect 22's duplicate numbers: the
orchestrator now prints the clashing **file names**, which is enough to repair without
searching, but `summary.md` — the only file that survives the terminal — keeps only four words
of it, "+ duplicate numbers". So the defect is no longer in the detection nor in the display: it
is in what gets **written**.

**The lead.** Write the per-branch list into `summary.md` or into a `<branch>-conflict.txt` /
`integration-clashes.txt`. It is the data the review needs first: it says which of the conflicts
are docs and which are code, so how much resolving will cost.

**What was done about it (2026-09-04).** A branch's conflicting files are kept in `summary.md`,
one per line under the integration verdict — together with the duplicate numbers and paths, and
defect 24's references. A **refused** merge writes its reason there rather than an empty list.
`integration-merge.err` stays what it is: a buffer, overwritten at every branch.

## 27 — Integration merges in completion order and ignores the stack it built — fixed

*2026-09-01 · project-6c618d6f · #96 on #91*

**What was seen.** `integration_check` iterates the list of green tickets, filled **in the order
they finish**. On that run, `feat/96` was therefore merged **before `feat/91`, which is its own
base** — afk knew it, it had printed it twice.

**The consequence.** Honestly, order would not have saved that run: both branches conflicted with
others anyway. But trying a stacked branch before its base is a conflict **by construction**,
for free, and it muddies the diagnosis — three branches set aside read as three real overlaps
when one of the three was only an inverted order.

**The lead.** Sort the list topologically — a branch after its base — before the merge loop.

**What was done about it (2026-09-04).** `merge_order` sorts the green branches by number of
commits since the common base before the merge loop. A stacked branch has strictly more than its
own, so it comes after — without having to re-sort the DAG, which the scheduler already did.

## 28 — `<n>.status` is append-only, its first line says `result=ko` — fixed

*2026-09-01 · project-6c618d6f · #104*

**What was seen.** A **green** ticket's status file reads:

```
result=ko
branch=feat/104
base=origin/master
attempt=1
result=ok
pr=146
```

The `result=ko` is the cautious default written at startup; the real verdict is **appended** at
the end. A `cat` — or a `grep result=` — therefore gives `ko` first on a perfectly green ticket,
and it is precisely the file you open to know what happened once the terminal is closed.

**The lead.** Rewrite the file instead of appending, or name the default differently
(`result_initial=`).

**What was done about it (2026-09-04).** The second lead, the simplest: the value written at
startup is called `result_initial`. `sget` reads the last line and was never concerned; it was
the human `cat` that was. A missing `result` counts as red anyway, `reap` handles it in its
default branch.

## 29 — `gh pr checks --watch` does not wait for a CI that does not exist yet — fixed

*2026-09-01 · project-6c618d6f · #114*

**What was seen.** `114-ci.txt` holds one line, `no checks reported on the 'feat/114' branch`,
and the ticket is filed as "no CI declared". That is **false**: CI ran and is green, run
registered 4 minutes earlier on GitHub's side.

**The cause.** `gh pr checks --watch` only watches check runs that **already exist**: with zero,
it does not wait, it exits immediately. And the CI phase runs **at the end of the run**, so a few
seconds after the last `gh pr create` — which structurally exposes the ticket that finishes last.
Two different situations are rendered by the same sentence: a repo **without** CI, and a CI **not
registered yet**. The first is a fact, the second is fixed by retrying.

**Measured window: ~4 seconds**, the delay between `gh pr create` and GitHub registering the run.
So what decides is not the last ticket's duration — a hypothesis written then disproved on the
next run — but the **position of the last PR created in the watch queue**: the `gh pr checks`
before it are usually enough to cover the 4 seconds. It is intermittent, not systematic, and it
reopens defect 12 through another door.

**The lead.** Loop a few times on `no checks` instead of concluding, or wait for the run to exist
(`gh run list --branch "$b" --event pull_request --limit 1`) before launching `--watch`. Two
minutes of patience are enough — three seconds were missing.

**What was done about it (2026-09-04).** Four attempts spaced by `CI_RETRY_WAIT` (10 s) as long
as the output says `no checks`, instead of concluding on the first pass. A repo without CI pays
30 seconds, in parallel with the other PRs; a repo that has one sees it.

## 30 — "green" + "CI inconclusive" + reduced gate = nothing ran the complete gate — fixed

*2026-09-01 · project-6c618d6f · #114*

**What was seen.** The summary prints both facts, three lines apart, and never crosses them:

```
  green  (5): 100 109 103 111 114
  …
  CI inconclusive (1): 114
```

`summary.md` even writes the premise in black and white — "the tickets marked ⚠ had a local gate
REDUCED: only their CI ran the complete gate" — without drawing the conclusion. #114 is marked ⚠
**and** its CI is inconclusive: its only complete gate is the one that returned no verdict, and it
stays counted "green" with no reservation. It is up to the reader to match two ticket lists to
notice it.

On that particular ticket the hole was theoretical — the reduced gate was equivalent to the
complete one over its scope. But it is exactly the combination that let defect 21's overflow
through, and afk cannot tell the two cases apart.

**Seen twice more, in another form**: a ticket counted in `green (4)` **and** in `draft (1)`,
three batches in a row. A draft PR does not get merged, so it does not belong in the same column.

**The lead.** Cross the lists before printing: a ticket with a reduced gate whose CI did not
conclude comes out in a category of its own — "unproven green" — or keeps `ready-for-agent`
instead of moving to `in-review`. And take out of "green" anything carrying a ⚠.

**What was done about it (2026-09-04).** The lists are crossed before being printed. `OK` stays
the raw list of tickets that opened a PR; `GREEN` removes the drafts and the reduced-gate tickets
whose CI did not conclude, which come out on their own line, **unproven green**. It is `GREEN`
that is displayed, and that counts in `RUNS.md`.

## 31 — A session can yield its turn waiting for its gate, and does not commit — fixed

*2026-09-02 · project-6c618d6f · #105, made worse on #99*

**What was seen.** `.afk/105-1.log` contains **a single line**, and it is the agent's last
message: `Gate still running. I'll report once it finishes.` afk follows with "agent did not
commit — committing for it", draft PR, "abnormal session: read before leaving draft".

**The cause.** #105 was the only ticket of the batch without a `Verify:` line, so on the
**complete** gate — several minutes. The agent launched it itself in the background, yielded its
turn waiting for it, and its session ended there, on a promise of a report that could no longer
arrive.

**What held.** The "agent did not commit" net produced a rescue commit, the PR came out as a
draft, the warning asked for a review — and the work was complete. But the branch comes out
**not mergeable as-is**, for two reasons that are not in the code: the PR is a draft, and the
rescue commit's subject is the **ticket title**, not a message in the repo's format. The reword
changes the SHA, so the PR no longer closes itself on push and has to be closed by hand.

**Made worse on the next batch: a timeout is not a gate dragging on.** `#99` comes out with
`timeout 45m` then `agent did not commit`, and its log is **empty** — the session was **cut**, it
did not yield its turn. Yet the summary writes the same thing in both cases (`draft` + "abnormal
session") although the risk is not comparable: a cut session may have been cut in the middle of a
file, and the gate says nothing about completeness, only that what exists compiles. Here it was
the **review** that established the work was complete, not afk.

**The leads.** The gate is **external to the agent** by design: an agent running it itself does
the work twice, and it is that execution that ate its turn. A line in the prompt ("do not run the
gate, commit") costs less than one more safety net. And telling apart in the summary the **cut**
session from the one that **yielded its turn**: it is not the same review.

**What was done about it (2026-09-04).** Both leads. A prompt line tells the agent not to run the
gate itself — it is external by design, running it makes it run twice. And the summary
distinguishes the three anomalies that put a PR into draft: `cut` (the `timeout` fired, the
session may have been cut in the middle of a file), `abnormal` (it stopped between two actions),
`not committed` (the work is there, only the commit was missing). The PR body carries the same
distinction.

## 32 — A refused push is reported as a failed implementation — fixed

*2026-09-02 · project-6c618d6f · #86*

**What was seen.** #86 comes out `red`, with no PR, "moved to ready-for-human". The file
`.afk/86-push.txt` says something entirely different:

```
! [remote rejected] feat/86 -> feat/86 (refusing to allow an OAuth App to create
  or update workflow `.github/workflows/deploy.yml` without `workflow` scope)
```

**The cause.** The container's token does not carry the `workflow` scope, and GitHub refuses to
let an OAuth App token create or modify a file under `.github/workflows/`. The ticket touched a
workflow: the push could not go through, whatever the quality of the work.

**The impact.** The branch is **complete, green and committed locally**, and it leaves the run
through the failure door. Four cascading consequences: no PR, so the CI phase does not see it;
excluded from the integration merge, which therefore announces a partial; filed in the summary in
the same column as a ticket whose code is wrong, with nothing to tell them apart; and the summary
**lies** on the last point — it announces `→ moved to ready-for-human` when labelling comes after
the push in the loop and never happened. Consequence: the next run would restart the ticket from
scratch.

**The lead.** A refused push is not a failed attempt. Do not relaunch a session — the second
attempt would fail identically —, do not count the branch red, and announce it on its own line in
the summary: "push refused (1): 86", with the reason read from `<n>-push.txt`. The local branch is
already kept; it is the filing that misleads.

**What was done about it (2026-09-04).** A refused push has its own category: no session relaunch,
no label change, no counting among the reds. Its summary line carries the remote's reason read
from `<n>-push.txt`, its worktree is kept like a red one's and its session stays resumable. Its
dependants freeze all the same — its branch is not on the remote, they have nothing to stack on.

## 33 — The `Verify:` line is not validated, and the prose goes to `bash -c` — fixed

*2026-09-04 · project-84812fac · #40 → #54*

Observed with `afk -n` and reproduced by hand, **before** launching: the run never happened.

**What was seen.** The batch's fifteen tickets write their gate the way it is written in a well
written ticket — the command in `code`, then what it does not cover, in prose:

```
**Verify:** `ruff check app/ && python -m pytest tests/ -q`, plus one fresh test per point:
```

`meta_line Verify` extracts from it:

```
** ruff check app/ && python -m pytest tests/ -q, plus one fresh test per point:
```

and that is what becomes the gate. Played the way afk plays it:

```
$ bash -c "** ruff check app/ && python -m pytest tests/ -q, plus one fresh test per point:"
bash: line 1: c2.sh: command not found
rc=127
```

`**` globbed over the cwd and bash tried to execute the file it found.

**The cause.** `meta_line` takes a validation pattern as `$2`, and the four fields do not use it
the same way: `Timeout`, `Model` and `Effort` pass one (`RE_TIMEOUT`, `RE_MODEL`, `RE_EFFORT`),
`Verify` passes none — so the default pattern, `.+`. Everything after the `:` is accepted as-is.
The comment above the function already states the rule: "A value that does not match its pattern
is IGNORED rather than passed as-is to claude(1) or timeout(1)". `Verify` is the only one of the
four not applying it, and the only one whose value is executed.

The `**` comes from markdown bold: the first `sed` eats `[[:space:]>*+-]*` before the field name,
but the two closing asterisks are **after** the `:`, so out of its reach.

**The impact.** Fifteen tickets red on both attempts, in a few seconds each, for a reason that has
nothing to do with their content — and the `.afk.env`'s `VERIFY_CMD`, written on purpose for that
repo, never runs once. A whole night, a whole batch. The `-n` mode shows the extracted value,
`** ruff check …`: it is readable before launching, but it reads as a display artefact, not as the
command that is going to run.

**The lead.** Give `Verify` a pattern like the other three: only accept the value if it is
**entirely** a single backtick span (`` `cmd` ``), otherwise fall back on `VERIFY_CMD`. A line of
prose is then no longer a gate, it is a note for the agent — which is what it is. On that batch,
all fifteen fall back on `ruff check app/ && python -m pytest tests/ -q`, which is the right
gate.

The other end — rewriting the ticket bodies as bare commands — costs more and does not protect the
next well written ticket, on that repo or another.

**What was done about it (2026-09-04).** `meta_line` cleans the value before validating it: the
bold that follows the `:` — out of reach of the first `sed`, which only eats what precedes the
field name — then, if the value **starts** with a backtick span, only that span is kept. The prose
that follows is a note for the agent, not a gate. The README's bare form (`Verify: pnpm test`)
stays accepted as-is: imposing anything else would have broken every ticket already written.

And `Verify` finally gets its pattern, `RE_VERIFY`, like the other three fields: the value is
refused if it ends in `:`. That is the shape of an introducing sentence, and it is exactly the one
that ended up at `bash -c`. A refused ticket falls back on `VERIFY_CMD`.

**Completed the same day, on the same fifteen tickets.** The cleanup above saved eleven of them
and let three through: `#51`, `#52` and `#54` write a gate that **starts in prose** and quotes its
commands mid-sentence ("by hand, `python -m app hub` + `npm run dev`: …"). It does not start
with a span, so point 2 has nothing to keep; it does not end in `:` but in a full stop, so
`RE_VERIFY` accepted it; and the `` s/`//g `` erased its backticks before anyone could use them.
All three went whole to `bash -c` — `by: command not found`, red on both attempts.

So the backticks now only fall when the value **is** the whole span, and `RE_VERIFY` refuses one
that keeps a backtick: after cleanup, a leftover backtick can only come from prose quoting
commands. It is the only trace telling it apart from a command, and erasing it blindly destroyed
it. Price paid, accepted: an old-style `` `cmd` `` substitution is refused too — it is written
`$(cmd)`.

**What that does not catch.** `#42` declares `` `npm run dev` `` at the head of its line: a span,
in first position, syntactically a command — accepted, and it is a development server that never
returns. The ticket dies on `TIMEOUT`, twice, full budget. No pattern tells a command that finishes
from a command that runs (defect 14 already said it about `npm test` without `run`): that gets
fixed in the ticket, not here.

## 34 — Without a declared CI, every ticket with a `Verify:` comes out "unproven green" — fixed

*2026-09-04 · project-84812fac · #40 → #54*

**What was seen.** The batch declares fifteen `Verify:`, and the repo declares no GitHub
workflow. `UNPROVEN` is filled on `CI inconclusive AND "${VERIFY[$t]}" != "$VERIFY_CMD"`: both
terms are true for all fifteen. Everything that would be green would come out "unproven green",
and every summary line would carry the `⚠`.

**The cause.** The comparison is a string equality with the global setting, and it serves as a
proxy for "**reduced** gate". A `Verify:` adding to the complete gate instead of reducing it is
filed the same way. On a repo without CI, the second term of the `AND` is permanently true: it no
longer filters anything.

**The impact.** The column no longer distinguishes any of what it was added for (defect 30):
fifteen identically marked lines, and the real "unproven green" would drown in them. No damage to
the code, noise on the only document read on waking up.

**The lead.** With defect 33 fixed, all fifteen fall back on `VERIFY_CMD` and the column empties
itself — that is probably all it takes. Still, on a repo without a workflow, `CI_TIMEOUT=0` in the
`.afk.env` already says "do not consult": the classification could read that as "no CI expected"
rather than as "CI inconclusive", and not mark unproven what nobody was expecting.

**What was done about it (2026-09-04).** "No CI declared" leaves `CI_UNKNOWN` for its own array,
`CI_NONE`. The first is a property of the **repo**, true for every ticket of every run; the second
is a verdict missing on that particular ticket. Only the second can make a ticket "unproven
green". When the whole run has no CI, the summary says it **once**, naming the reduced-gate
tickets — saying it fifteen times teaches the fifteenth nothing the first did not.

The first term of the `AND` stays a string equality with `VERIFY_CMD`: it does not tell a reduced
gate from a widened one. Nothing allows that without running both, which is precisely the price we
refuse to pay.

## 35 — `git merge -q` writes to stdout, so every ticket absorbing a branch dies in 0s — fixed

*2026-09-04 · project-84812fac · #46 #48 #50*

**What was seen.** Three tickets out red in `0m00s`, `0m02s`, `0m03s`, without a line of session,
on the same message:

```
    worktree    : Auto-merging CLAUDE.md
  /workspaces/project-84812fac/.afk/wt/50
  afk: line 705: cd: $'Auto-merging CLAUDE.md\n/workspaces/project-84812fac/.afk/wt/50': No such file or directory
    ✗ worktree unreachable
```

All three — and only they — had an `absorbs:` line. Five other tickets froze behind them: eight of
the batch's fifteen lost, on a run otherwise green 7/7.

**The cause.** `make_worktree` returns the worktree path **on stdout**, and its caller reads it
with `wt=$(make_worktree …)`. In its absorption loop, `git merge -q --no-edit` is not silent: `-q`
silences the diffstat, not the merge engine's "Auto-merging <file>", which go to **stdout**. So
they end up glued in front of the path, and the `cd` fails on a three-line string. The trigger is
not "absorbing", it is "absorbing a branch touching a file the base already touched" — a merge
without overlap says nothing and passes.

**The impact.** A healthy ticket marked red without having been launched, and its descendants
frozen. The price is highest on a stacked batch: those are the latest tickets, so the most
expensive to redo, and the red blames the worktree rather than the merge.

**Why `harness.sh` did not see it.** It does cover the case ("independent siblings: one serves as
base, the other is absorbed"), and it passes **both before and after** the fix: its absorbed
branches modify no common file, so the merge stays mute. The missing case is not the absorption,
it is the overlap.

**What was done about it (2026-09-04).** The merge writes into `<n>-wt.err` —
`>>"$AFK_DIR/$ticket-wt.err" 2>&1` — where the worktree already keeps its trace, rather than
`>/dev/null`: the merged file is exactly what we want to read when an absorption goes wrong. It
remains to give the harness's fixture two absorbed branches that overlap, otherwise the same class
of leak will come back through another chatty `git`.

## 36 — "no CI on this repo" does not reach `summary.md`, which keeps pointing at it — fixed

*2026-09-04 · project-84812fac · #73, #75*

**What was seen.** Two green tickets, #75 carrying a `Verify:` line strictly wider than the global
gate (`ruff && pytest && (cd hub && npm run build)`). The gate ran in full: 379 tests, then a green
`vite build`. `.afk/summary.md` marks it `ok ⚠` and states "the tickets marked ⚠ had a local gate
REDUCED (`Verify:` line): only their CI ran the complete gate". The repo has no `.github/workflows`.

**The cause.** The sentence on line 1276 is an unconditional `printf` in the block that writes
`summary.md`. Defect 34's fix had added the counter-sentence — "no CI on this repo: the local gate
is the only one that ran" — but as an `echo`, line 1450, so on stdout: it lands in `run.log` and
never in the summary. The two documents say the opposite of each other, and 34 was precisely meant
to make "the summary say it once".

**The impact.** The only document the debrief asks you to open first points at a CI that does not
exist, and presents as insufficiently verified the ticket that was verified the most. On that run,
it costs reopening `75-verify.txt` to see the build had run — exactly the work the `Verify:` line
was supposed to avoid.

**The fix.** `summary.md`'s sentence moved under the same condition as the summary's
(`${#CI_NONE[@]} == ${#OK[@]}`): on a repo without a workflow, the written summary also says the
local gate is the only one that ran. And "REDUCED" becomes "REPLACED" everywhere — summary,
written summary, PR body: the ticket's line replaces the global gate, whether it is narrower or
wider, and that at least we know without running both. The harness's run 7 now checks
`summary.md`, not only stdout.

## 37 — The last duration shown under a ticket is the gate's, not the ticket's — fixed

*2026-09-07 · project-6c618d6f*

**What was seen.** A ticket that ran for more than thirty minutes ends on `Time:    2m3.821s`.
Either the measurement is wrong, or the ticket finished fast and the run continues for nothing.

**The cause.** Neither: that line is not afk's, which never prints milliseconds (`fmt_dur` returns
`2m03s`). It is the project's test runner — Japa, on that repo — and it times **the gate**. In
parallel, `reap` announces the ticket's duration in the header `═══ #N — title (32m10s) ═══` then
copies its whole log underneath: thirty lines later the header is off screen and the last visible
duration is the gate's.

**The fix.** `reap` repeats its measurement **after** the dump, naming the ticket and specifying
that the durations above are the gate's. Nothing to change in the computation, which was right.

## 38 — The base is never gated before the run, and every ticket re-diagnoses it at its own expense — fixed

*2026-09-07 · project-6c618d6f · #169 to #179 (11 tickets, two runs)*

**What was seen.** Eleven tickets launched on `origin/develop`, six of them red on the first
attempt. The six fail on **the same test**, in a file none of the eleven names:
`apps/backend/tests/functional/map_objects.spec.ts`, which expects seven map objects when the
import command's table has held ten since a commit pushed the day before straight onto `develop`
(so no PR, so no CI). One red test out of 605.

The eleven branches all fixed that test. Seven carry a separate commit for it, with seven different
messages ("the palette imports ten objects, not seven — the test says so", "the seeder assertion
catches up with the ten versioned map objects", …); the other four folded it into their feature
commit. Six burned a full second attempt to discover it.

**The cause.** afk only ran the gate on `BASE_REF` in one case: when the session had produced **no
commit** ("no commit — running the gate on the base to decide"). As soon as the agent commits, the
gate only judges `base + ticket`, and nothing separates the two terms. So the machinery already
existed — it simply was never called upfront, although the run pays for a full gate execution at
the integration pass anyway.

**The impact.** The trace blames the wrong culprit, and it does so eleven times. The red ticket
carries `reason=verify`, its `<n>-fail.txt` names a test outside its scope, and the summary shows
it "red": #169 went to `ready-for-human` over a defect that is not its own. The price is paid three
times — the six second attempts, the attention of eleven agents on an off-topic test, and seven
concurrent fixes of the same file to review one by one at merge time.

**The fix.** `base_check` runs the gate once on `BASE_REF`, in a detached worktree, before the
first ticket worktree. Green, it says so in one line. Red, it names what fails, keeps
`.afk/base-verify.txt`, and has it repeated in the summary and in `summary.md`: a red ticket whose
failure also appears there is not the ticket's fault. The run **continues** — whoever launched it
has gone to bed, and a run that stops on a red base costs the whole night. The cost is one gate
execution per run, the one the integration pass already runs at the end. Harness run 9.

## 39 — The summary's "Cost" column claims a total and only shows the last attempt — not a defect

*2026-09-07 · project-6c618d6f · #179*

**What we thought we saw.** `summary.md` gives #179 as `$11.0831` over two attempts when its
`.afk/179.status` carries two lines, `cost=8.9192` then `cost=11.0831` — so a $20.00 ticket whose
summary would show only 55%.

**Why that is wrong.** `cost` is already cumulated **inside the worker**: it starts at 0 and each
attempt writes the sum (`awk 'BEGIN{printf "%.4f", a+b}'`). So the `.status`'s last line is the
total, not the last attempt — $11.0831 contains the $8.9192, and the second attempt cost $2.16.
The `sget` reading the last line returns exactly what the legend promises, and the harness has
guaranteed it since the second run: two sessions at $0.50 come out as `$1.0000` in the summary.

**What to take from it.** Adding up a `.status`'s `cost=` lines counts twice. The figures cited in
defect 38 had been obtained that way, and were roughly double.

## 42 — The "Context" column is empty as soon as the repo path contains an underscore — fixed

*2026-09-11 · project-84812fac · #148–#152*

**What was seen.** The summary's "Context" column at `—` on all five tickets of the run, and on
the three of the previous run. Eight tickets in a row without a single measurement, although the
legend under the table explains in three lines how to read it, and `/afk-debrief` makes it the
first signal of a ticket that is too big. Nothing in the output tells "no transcript found" from
"this ticket had nothing remarkable": both are written `—`.

**The cause.** `ctx_of()` rebuilds the name of the directory where Claude Code files the
transcripts, `$CLAUDE_CONFIG_DIR/projects/<the session's cwd>`, by replacing the path separators:
`sed 's#[/.]#-#g'`. Claude Code also replaces the **underscore**. Here the worktree is
`/home/jane_doe/…/.afk/wt/152`: afk looked for `-home-jane_doe-…`, the directory
was called `-home-jane-doe-…`. The `[[ -d "$d" ]] || return 0` at the head of the function
swallows the discrepancy without a word. It does not depend on any repo: any username or directory
name carrying an underscore turns the column off everywhere.

**What was done about it.** One more character class: `sed 's#[/._]#-#g'`. Verified by rebuilding
the path of the run's five worktrees, which all land on the real directory, and by replaying
`peak_context` on them: 178k, 168k, 147k, 185k, 138k. So the batch's slicing was right — no ticket
above a fifth of the window — but that is something we only learned after repairing the
thermometer.

## 43 — The summary times the ticket, never its phases — fixed

*2026-09-12 · project-84812fac · run of 2026-09-11*

**What was seen.** "Why do the tickets take so long?" The summary cannot answer: it gives one
duration per ticket and nothing else. The `.afk/<n>-<attempt>.json` files had to be opened one by
one and their `duration_ms` compared with the `.status`'s `dur` to see where the time goes:

```
#148  ticket 20m13  session 1m28   #149  13m10 / 12m07   #150  10m59 / 10m03
#151  10m58 / 9m57  #152  16m52 / 15m52
```

So ~95% in the session, and **one minute** for `SETUP_CMD` plus the two gate passes — the opposite
of what we suspected. `#148` is an exception for another reason: `duration_ms` only covers the main
loop, its two review subagents were running in the background (`duration_api_ms` = 14m47), and
those 18 minutes appear nowhere.

**The cause.** `reap` writes `dur=` and that is all. Yet the worker goes through four measurable
phases of different natures — `SETUP_CMD`, the session, the gate, and waiting on a lock when
`JOBS > 1` — three of which are tunable (`JOBS`, `TIMEOUT`, `VERIFY_CMD`, `SETUP_CMD`) and one is
not. Without the breakdown, the only possible reading is "it is slow", and the settings get chosen
at random: serialising the gate has no effect where it lasts a minute, and a repo whose gate lasts
ten minutes is exactly the opposite case. `peak_context` already solved that problem for the size
of the work; the duration stayed a single number.

**What was done about it (2026-09-13).** Three `st` calls in the worker — `$SECONDS` around
`SETUP_CMD`, around each `claude -p` and around each gate pass, the last two cumulated over the
attempts like the cost — and a "Phases" column in the written summary rendering them
`0m58s / 15m52s / 0m38s`. The fourth phase, waiting on a lock, is not measured: it is deduced,
`duration` minus the sum of the three, and the legend says so with the value of `JOBS`. Background
subagents are counted in `t_session` without our having had to decide: it is afk that does the
timing, from the launch of the `claude` process to its exit, where `duration_ms` only covers the
main loop.

## 44 — The plan freezes an out-of-run blocker that the real run knows how to stack on — fixed

`-n` shows "frozen — undeliverable blocker" for any ticket whose blocker is outside the batch but
carries an open PR. The real run, meanwhile, launches it without blinking.

The two paths do not ask the same question:

- `deps_state`: `[[ -n "${BRANCH_OF[$b]:-}" ]] && continue` — the PR's branch is enough, the ticket
  is ready;
- the plan (`DRY_RUN` block): `[[ -n "${DELIVERED[$b]:-}" ]]` — only a ticket delivered *in this
  run* counts, `BRANCH_OF` is ignored.

The plan contradicts itself in the same output: it has just printed, while reading the tickets,
"· #20: blocker #16 delivered outside the run (open PR) → base origin/feat/16".

Seen on project-1a3c4c1d on 2026-09-12, while resuming an interrupted run: the first 5 tickets had moved to
`in-review` with their PRs open, and the plan for the remainder announced the 4 remaining tickets
as frozen. None of them was.

What that costs: it is precisely in that situation — resuming after an interruption, batch
partially delivered — that the plan is consulted before relaunching. It says exactly the opposite
of what is going to happen, and pushes you not to relaunch.

**What was done about it (2026-09-13).** `DELIVERED` is primed with the blockers that already have
a branch, before the wave loop: the plan now asks the same question as `deps_state`. The harness
replays the fourth run's batch in `-n` and checks both halves — the announced base really is
`origin/feat/99`, and the word "frozen" appears nowhere.

## 45 — A stacking that conflicts is filed as "frozen", like an undelivered blocker — fixed

A ticket whose blockers are **all delivered** comes out "frozen" in the summary when merging their
branches into its worktree fails. The word is the same as for a blocker never delivered, and the PR
column is empty in both cases: nothing tells "its prerequisite is missing" from "its prerequisites
are there but do not hold together".

And yet the trace exists, alone and uncited: `.afk/<n>-wt.err` contains the `CONFLICT (content)`
and the paths involved. Neither `<n>.out` nor `<n>.status` is written — `launch` fails before. The
summary points at `<n>-wt.err` nowhere; its legend only names `<n>.out`, `<n>-<attempt>.json`,
`<n>-verify.txt` and `<n>-ci.txt`.

Seen on project-1a3c4c1d on 2026-09-12: #23 depended on #19, #20, #21 and #22, all delivered with their PRs.
It came out "frozen". `23-wt.err` said `CONFLICT (content): Merge conflict in CONTEXT.md` and a
second one on `app/components/Suivie.vue`. Read without that file, the summary sends you looking
for a missing blocker that does not exist.

What that costs: it is the most useful information of the run — the combination of the branches
does not hold — and it is the only one that does not surface. The diagnosis is done by hand,
digging into a file the legend does not mention.

**What was done about it (2026-09-13).** All three. The ticket stays in `SKIP` — its dependants
freeze for the same reason as before — but it also enters `CONFLICT`, and the summary writes
**conflict**. The paths are extracted from `<n>-wt.err` at the moment the merge fails, said on
screen and repeated under the table like the integration pass's, with the log's name. And
`<n>-wt.err` is in the logs legend.
