# afk

An outer loop that chains `/implement` over the `ready-for-agent` tickets.
One ticket = one fresh Claude session = one PR. No LLM in the orchestrator:
it orders, it launches, it verifies, it pushes, it labels.

Plugs into the [mattpocock/skills](https://github.com/mattpocock/skills) workflow.

**Once per project**, never again:

```
/setup-matt-pocock-skills   →   /afk-setup
 (docs/agents/, the triage        (.afk.env: the command that says
  labels, the project              "this ticket is done" here)
  memory)
```

**For every batch of work**:

```
/grill-with-docs  →  /to-tickets  →  /triage  →  /afk-preflight
 (clarify what      (issues +        (label       (reread the batch:
  there is to        Blocked by)      ready-       what would cost
  do)                                 for-agent)   the night)

        →  ./afk.sh  →  /afk-debrief  →  you merge
           (N headless    (sort the
            sessions)      non-greens)
```

Between `/afk-preflight` and `/afk-debrief`, you sleep.

## Prerequisites

- Repo configured by `/setup-matt-pocock-skills`, **GitHub** tracker (`docs/agents/issue-tracker.md`).
- A `.afk.env` at the root, written by `/afk-setup` (see [Per-project config](#per-project-config)).
  Without it, the verification gate stays a pnpm monorepo's — wrong everywhere else.
- `claude`, `gh`, `git`, `timeout` in the PATH. Clean working tree.
- `gh auth login` done: the token is also used to push, without a passphrase.
- The mattpocock skills installed in the `CLAUDE_CONFIG_DIR` the script uses
  (default `~/.claude`) — otherwise `/implement` does not exist in the headless session.

## Usage

```bash
./afk.sh                      # every ready-for-agent ticket, in series
./afk.sh 43 48 49 50          # these ones
./afk.sh -j 3 43 48 49 50     # in parallel wherever the DAG allows it
./afk.sh -n -j 3 43 48 49 50  # the plan: waves, bases, stacks, frozen, effective gate
VERIFY_CMD="npm test" ./afk.sh
CI_TIMEOUT=0 ./afk.sh         # do not wait for CI
./check.sh                    # tests the parsers
./harness.sh                  # tests the orchestrator (claude and gh stubbed)
```

No human interaction by default: no passphrase (see below), no pause
(`CHECKPOINT_EVERY=0`), no permission prompt. `nohup ./afk.sh -j 3 &`
and you read it back on waking up.

| Env | Default | |
|---|---|---|
| `VERIFY_CMD` | `pnpm typecheck && pnpm test && pnpm lint` | the definition of "done", overridable per ticket |
| `INTEGRATION_VERIFY_CMD` | `$VERIFY_CMD` | the integration pass's gate — put the **uncached** form there (`turbo … --force`) |
| `MAX_ATTEMPTS` | `2` | 1 attempt + 1 retry, in a fresh session |
| `TIMEOUT` | `45m` | bounds a run (`--max-turns` is gone in 2.1.x), overridable per ticket |
| `CI_TIMEOUT` | `15m` | how long we wait for CI after opening a PR; `0` = do not consult it |
| `CI_RETRY_WAIT` | `10` | seconds before retrying a "not registered yet" CI |
| `MODEL` | empty | the sessions' model; empty = `claude`'s default, overridable per ticket |
| `EFFORT` | empty | thinking level (`low`…`max`); empty = the default, overridable per ticket |
| `FALLBACK_MODEL` | `sonnet` | fallback model when the main one is unavailable; empty = no fallback |
| `INTEGRATION` | `1` | integration pass over the green branches at the end of the run; `0` = skip |
| `LABEL` / `LABEL_REVIEW` / `LABEL_KO` | read from `docs/agents/triage-labels.md` | |
| `MEMORY_RE` | root + `apps/*` + `packages/*` | paths that count as "decision captured" |
| `BASE_BRANCH` | the remote's default branch | |
| `JOBS` | `1` | simultaneous sessions; `auto` = `nproc/4` capped at 4 |
| `VERIFY_LOCK` | `1` | serialises the verifications when `JOBS > 1` |
| `SETUP_CMD` | deduced from the lockfile | seeding a worktree (`pnpm install --frozen-lockfile`) — receives `AFK_TICKET` and `AFK_WORKTREE` |
| `SEED_GLOBS` | `.env`, `apps/*/.env`, … | gitignored files copied into each worktree |
| `KEEP_WORKTREES` | `0` | keep the green worktrees too (the red ones always are) |
| `AFK_HOME` | the script's folder | where `RUNS.md` is written — redirect it if afk's repo is mounted read-only |
| `CHECKPOINT_EVERY` | `0` | pause to review the PRs; `0` = never |
| `STACK_ON_OPEN_PR` | `1` | stack on an out-of-run blocker with an open PR, instead of freezing |
| `ALLOW_REVIEW` | `0` | relaunch a ticket already `in-review` (it already has an open PR) |

## Per-project config

The defaults in the table above are cut for a pnpm monorepo. A Python, PHP or Rust repo
does not have the same definition of "done" — and even on an npm repo, `npm test` often
opens a watcher that never returns (`vitest` without `run`): the ticket then dies on
`TIMEOUT`, for a reason that has nothing to do with it.

So a repo declares its gate in a `.afk.env` at its root, versioned next to the code:

```bash
# .afk.env — project-fb0a2365
# `pnpm test` = vitest in watch mode: it never returns. test:run is the one to use.
VERIFY_CMD="${VERIFY_CMD:-pnpm lint && pnpm test:run}"
```

It is sourced after the arguments: **command line > `.afk.env` > the script's default**,
hence the `${VAR:-...}`. Only put in what differs.

It is shell from the repo, executed as-is — the same trust surface as a ticket's
`Verify:` lines.

### The integration gate separates from the tickets'

A build cache can make a gate hollow. Turbo, for instance, hashes the files **tracked by
git**: a generated, gitignored file does not enter the key, so a worktree that has not
produced it yields **the same fingerprint** as the main tree that has → cache hit, logs
replayed, nothing executed. The gate prints `$ tsc --noEmit` and a ✓ without compiling a
line, and if the cache is shared between worktrees the false green travels. On a real run,
eight tickets went green over a defect only the integration pass saw — it presented the
first combination of contents ever seen, so a cache miss, so an execution.

**`Cached: n cached` is a safety line, not a performance statistic.**

`INTEGRATION_VERIFY_CMD` lets you pay the honest form **once**, on the combination,
without imposing it on every ticket:

```bash
# .afk.env
INTEGRATION_VERIFY_CMD="${INTEGRATION_VERIFY_CMD:-pnpm exec turbo typecheck lint --force && pnpm test}"
```

The pass announces its gate when it differs, and the summary records both.

### Isolating a worktree from its neighbours

Two parallel worktrees are two copies of the code, not two copies of what lives
**around** it: a test database, a port, a bucket. If the repo hardcodes its test database
name in a versioned file, both suites migrate and roll it back at the same time — and the
current ticket is marked red for a neighbour's migration. It happened, and the symptom
never blames the real culprit (`unable to release database lock`, or a
`Schema file "…033_…" is missing` coming from a file absent from THIS branch).

`SETUP_CMD` already runs **in** the worktree and **under the `install` lock**, so
serialised. It receives what it needs to tell itself apart:

| variable | value |
|---|---|
| `AFK_TICKET` | the ticket number, or `_integration` for the final pass |
| `AFK_WORKTREE` | the worktree's absolute path |

It is up to the project to do what it wants with them — it is the one that knows what it
has to isolate from:

```bash
# .afk.env
SETUP_CMD="${SETUP_CMD:-scripts/afk-worktree-setup.sh && pnpm install --frozen-lockfile --prefer-offline}"
```

```bash
# scripts/afk-worktree-setup.sh — one test database per worktree
[ -n "$AFK_TICKET" ] || exit 0          # launched outside afk: nothing to isolate
db="myapp_test_${AFK_TICKET#_}"
echo "DB_DATABASE=$db" > apps/backend/.env.test.local
dropdb --if-exists "$db" && createdb "$db"
```

Nothing is destroyed on exit: one empty database per ticket number, recreated on the next
run of the same ticket. If that becomes annoying, it is a `dropdb` in a `TEARDOWN_CMD`
that does not exist yet.

The `/afk-setup` skill (in [`skills/afk-setup/`](skills/afk-setup/SKILL.md)) reads the
repo — scripts, CI workflows, `CLAUDE.md` —, proves the proposed command then writes that
file. Once per project, after `/setup-matt-pocock-skills` and before the first run. To
install it:

```bash
ln -s "$PWD/skills/afk-setup" ~/.claude/skills/afk-setup   # or your CLAUDE_CONFIG_DIR
```

## The run's two skills

`afk.sh` has no LLM: it orders, launches, verifies, pushes, labels. The judgement is
before and after, in an interactive session.

[`/afk-preflight`](skills/afk-preflight/SKILL.md) — **between `/triage` and the run.**
Reads the plan (`./afk.sh -n`) and the ticket bodies, and says what is going to cost the
night: a ticket frozen by a blocker already merged but not closed, an acceptance criterion
no gate can see, a rework without a `Timeout:`, two tickets of the same wave on the same
files, a mechanical ticket that does not need the rework model.
It also re-slices the batch when needed: cut a ticket that does not fit in one session (a
longer `Timeout:` does not fix a lack of room), serialise with a `Blocked by` two tickets
writing into the same files, hand out the ADR and migration numbers before the run rather
than discovering them duplicated at integration.
It proposes the fixes, it does not apply them and it does not launch the run.

[`/afk-debrief`](skills/afk-debrief/SKILL.md) — **on waking up, before merging.** Reads
`.afk/summary.md` and the traces, and sorts each non-green by cause: wrong gate, badly
seeded worktree, ticket too big, real failure. It can tell a red caused by the ticket from
a red caused by the environment, and proposes what to put back to `ready-for-agent` for
the next night.

```bash
ln -s "$PWD/skills/afk-preflight" ~/.claude/skills/afk-preflight
ln -s "$PWD/skills/afk-debrief"   ~/.claude/skills/afk-debrief
```

## Parallelism

`-j N` launches N tickets at a time. **One ticket = one git worktree** (`.afk/wt/<n>`):
two agents in the same working tree trample each other, and it is also what frees the
main tree — the script no longer does any `checkout`, `pull` or `reset` in it. You can
keep working in it, on whatever branch you like, while a run is going.
The worktrees start from `origin/<base>`, never from the local branch.

The scheduler respects the blocker DAG: a ticket only starts when all its blockers in the
run are green, and a red blocker freezes its dependants (their base does not exist). `-n`
prints the waves, so exactly where parallelism is possible and where the DAG forbids it:

```
wave 1 (parallel, 3 at a time):
  #43   base origin/master  [mobile] The canvas logo turns into a radar…
  #48   base origin/master  [backend][mobile] Review: a comment attached to…
wave 2 (sequential):
  #49   base feat/48        [backend][mobile] Reporting a standard…
wave 3 (sequential):
  #50   base feat/49        [admin] Moderation queue for the reports
```

**The Claude sessions run in parallel, the verifications queue up.** A session shares
nothing; a verification holds the test Postgres, some ports and the RAM of a
`turbo typecheck`. Two simultaneous `node ace test` on the same database destroy each
other. Hence `VERIFY_LOCK=1`: `flock` serialises verifications and installs, the long part
stays parallel. Measured on project-6c618d6f: seeding a worktree takes 19 s (worktree 1 s,
`pnpm install` 4 s in hard links from the local store, `typecheck` 13 s) — negligible next
to a session.

A branch can only be checked out in one worktree: if you have `feat/48` checked out in
your tree, `-n` tells you before launching anything.

## What it does, ticket by ticket

0. **The base first.** The gate runs once on `origin/<base>`, before the first worktree.
   Red, the whole batch is going to fail on the same test with nothing saying so: the gate
   only ever judges "base + ticket". The run continues anyway — you have gone — but the
   header, the summary and `summary.md` say the base was red, and `.afk/base-verify.txt`
   keeps what it takes to compare with a ticket's `<n>-fail.txt`.
1. **Boundary.** Reads the blockers (native GitHub dependencies, otherwise the
   `## Blocked by` section written by `/to-tickets`). Blocker still open and not handled
   in this run → ticket frozen, not launched — unless it has an open PR: its branch is
   pushed and readable, we stack on it like on a blocker from the run
   (`STACK_ON_OPEN_PR=0` to freeze anyway).
2. **Stacked PRs.** Blocker delivered in this run but not merged yet → the branch starts
   from its own, and its PR targets its branch. Several blockers → the base is the one
   that already contains the others (`merge-base --is-ancestor`), the remaining ones are
   merged; conflict → frozen.
3. **Fresh session**: `claude -p "/implement GitHub ticket #N …"`, never `--resume`.
   Resuming a session that just failed means restarting from the context that failed.
   The retry receives the last 60 lines of the failure, in a pristine session.
   `--resume` stays on offer to a human on a red ticket, at the end of the summary.
4. **External verification.** The script grades the work, not the agent.
   Zero commits produced → if the session says it was blocked, the ticket is **frozen**;
   otherwise the gate is run **on the base** to decide: red, it is a failure; green, the
   ticket is **absorbed** (see below).
5. **Green** → push, PR `Closes #N` on the right base, ticket switched to `in-review`,
   then waiting for CI. **Red** → `ready-for-human` + a comment with the failure output.
   `/triage`'s state machine keeps turning while you sleep.
6. **Worktree dropped** if green, **kept** if red: that is where we go to read what
   happened, with the `node_modules` already in place.
7. **CI** at the end of the run, every PR watched in parallel (waiting in the worker would
   tie up a slot for polling).
8. **Integration** at the end of the run: every green branch merged into a throwaway
   worktree — **in topological order**, a stacked one after its base, otherwise it
   conflicts by construction —, then `INTEGRATION_VERIFY_CMD`. It reports; it touches no
   PR. It also flags three things no gate can see: two files claiming the **same number**
   (ADR, migration), the **same path created** by two branches, and the **run's tickets
   cited in the merged docs** — a future-tense sentence about something delivered ten
   minutes ago produces no conflict. The conflicting files are written into `summary.md`,
   not just displayed.

## Logs

Everything is in `.afk/` (self-ignored), one family of files per ticket:

| File | Contents |
|---|---|
| `<n>.out` | the orchestrator's trace for this ticket — what you read first |
| `<n>-<attempt>.json` | what the session says about itself: failure, cost, model, `session_id` |
| `<n>-verify.txt` / `<n>-fail.txt` | the gate's output, last failure kept |
| `<n>-setup.log` | the worktree's install |
| `<n>-ci.txt` | `gh pr checks`'s output |
| `<n>-push.txt` | the remote's refusal, when the push fails |
| `base-verify.txt` | the gate run on the base before the run — one per run, not per ticket |
| `<n>.status` | the machine verdict (`result`, `pr`, `draft`, `draft_why`, `attempt`, `session`, `cost`, `model`) |
| `summary.md` | the run's table: result, PR, attempt, model, **peak context**, cost, CI, integration |

**`.afk/` is overwritten on the next run.** What has to survive lives in afk's own repo —
mounted in each of your projects, so common to all of them:

| File | Contents | Written by |
|---|---|---|
| `RUNS.md` | one line per run: date, project, green/unproven/drafts/reds/refused pushes/frozen/absorbed, 1st attempt, model, cost, duration, integration | `afk.sh`, at the end of each run |
| `docs/defects.md` | **afk's** still-live defects, seen for real during a run, numbered | `/afk-debrief`, or by hand |
| `docs/defects-fixed.md` | the same, once fixed: same numbering, the archive | same, at fixing time |

The path is the script's (`AFK_HOME`), not the project's: whether you launch `afk.sh` from
a devcontainer where it is mounted or from outside, it writes to the same place.
Repo mounted read-only → nothing is logged, and that is not a run error.

In series, the trace also comes out live on screen. In parallel it is set aside and dumped
in one block when the ticket finishes, otherwise the outputs interleave; a
`…  running: #48 (3m12) #50 (1m04)` line every two minutes says who is working.

## Context as the thermometer of the slicing

A fresh session guarantees a clean start, not a clean finish. With a 1M window, nothing
compacts: the session grows until the ticket is done. Measured on project-6c618d6f — same run,
same rules:

| ticket | turns | peak context |
|---|---|---|
| #43 | 64 | 140k |
| #49 | 208 | 289k |
| #50 | 214 | 312k |

So `summary.md` carries a **context** column, read from the session's transcript. It is
the same information as "green on 1st attempt", taken upstream: a ticket brushing the
window was too big, and it shows **before** quality suffers.

## Per-ticket verification gate

`VERIFY_CMD` is a single gate for every ticket. On a monorepo, that contradicts "stay
within the ticket's scope": a backend ticket touching an end-to-end typed contract breaks
the client's typecheck, and the agent has to step outside its scope to produce green.

So a ticket can declare its own gate, with a line in its body:

```
Verify: pnpm turbo typecheck --filter=@acme/backend
```

The script reads it and uses it instead of `VERIFY_CMD` — for that ticket only.
The line is executed as-is: tickets are part of the trust surface, just like the session's
`bypassPermissions`.

Two forms are accepted, the bare one above and the command in `code`. When the value
**starts** with a backtick span, only that span is the gate — what follows is a note for
the agent:

```
**Verify:** `ruff check app/ && pytest tests/ -q`, plus one fresh test per criterion
```

A value ending in `:` is an introducing sentence, not a command: it is ignored and the
ticket falls back on `VERIFY_CMD`. Same rule as `Timeout:`, `Model:` and `Effort:` — a
badly written ticket must not cost a run.

That makes three levels, from the most general to the most specific — **the most specific
wins**:

```
the script's default  →  the repo's .afk.env  →  the ticket's Verify: line
(pnpm monorepo)          (this project)          (this ticket)
```

It is also the answer to the symmetric risk of the green rate: **100% green means nothing
if the gate verifies nothing.** On a cosmetic ticket, "green" means "it compiles".

## Per-ticket time budget

`TIMEOUT` is global, a ticket's size is not: a rework — migration, formula, guards, tests,
four docs — does not fit the shape of an average ticket, and gets cut in the middle. Same
place, same parser as `Verify:`:

```
Timeout: 90m
```

The format is `timeout(1)`'s (`90m`, `2h`, `3600`). A value of any other shape is ignored:
passed as-is, it would stop the session from starting.

## Per-ticket model and effort

Same place, same parser, for the same reason: the global setting was chosen for the
average ticket, and a typo fix does not need the model of a rework.

```
Model: sonnet
Effort: high
```

`Model:` accepts an alias (`opus`, `sonnet`, `haiku`) or a full name; `Effort:` one of
`claude`'s levels (`low`, `medium`, `high`, `xhigh`, `max`). Without these lines, `MODEL`
and `EFFORT` apply; without them, `claude`'s defaults.

The summary gives the models that **actually** ran: `FALLBACK_MODEL` switches to a backup
model when the main one is unavailable — without that, a whole night can change model
without saying so. It is that fallback which stops a transient outage from burning a
ticket's two attempts in a few seconds and emptying the queue.

The column also carries the number of subagents the session spawned
(`sonnet-5 (+2 subagents)`): they carry the model of their definition
(`.claude/agents/*.md`) and not the ticket's, so several models are only a fallback
without them — and part of the cost comes from them (defect 41).

## Resuming a failed session

A ticket handed back to `ready-for-human` keeps its worktree **and** its session. The
summary gives the command to get back in:

```
(cd .afk/wt/48 && claude --resume 42ce8dfe-…)
```

It is the only way to ask the agent why it took that path — a log will never say.

## When a ticket has nothing left to do

A ticket can be delivered by its predecessor — the previous ticket's agent went beyond its
scope, which is the norm as soon as a typed contract crosses the apps. "The agent failed"
and "there was nothing left to do" both came out as `no commit`: two attempts burned per
ticket, then `ready-for-human` for a false reason.

But the gate on the base says nothing about the ticket's content: it is green because the
repo compiles, not because the requested work happened. A ticket the agent judges too
early — a prerequisite that is not in this base — therefore came out "absorbed", so
invited to close (defect 40). The prompt now asks the session to name its case on its last
line when it commits nothing:

- `AFK: BLOCKED <what is missing>` → the ticket is **frozen**, as behind an unlifted
  blocker: label unchanged, no PR, a comment citing what is missing, no second attempt
  (same session, same base, same conclusion). It starts again on the next run.
- `AFK: ALREADY DONE`, or no line at all → the gate runs **on the base**:
  - **red** → the agent really did produce nothing, next attempt then `ready-for-human`;
  - **green** → the ticket is **absorbed**: switched to `in-review` with a comment, no PR,
    neither red nor "green on 1st attempt". Its dependants start from the base it used
    itself, instead of freezing behind a false failure.

## When a session ends badly

A Claude session can die after producing complete work, or at 60%: the gate returns
exactly the same green in both cases. The script does not throw the work away — the net
commits the dirty tree, with the ticket title as the message — but:

- the PR comes out **as a draft**, with the failure and the session file's path in its body;
- the ticket does not count as "green on the first attempt", and it leaves the summary's
  `green` line: a draft PR does not get merged;
- it shows up in the summary's `draft` line, **with the reason** — `cut`, `abnormal` or
  `not committed`.

Same treatment when the agent did not commit by itself: it is an anomaly, not a success.

The three are not reread the same way. A session **cut** at the `timeout` may have been cut
in the middle of a file; a session ended **abnormally** stopped between two actions;
**not committed** means the work is there and only the commit was missing. The gate tells
none of the three apart: it says that what exists compiles, not that the work is complete.

## Green, and yet unproven

Two results leave the `green` column without being failures:

- **unproven green** — the ticket had a `Verify:` line (local gate replaced by its own)
  **and** its CI did not conclude. Its only complete gate is the one that returned no
  verdict: nobody checked what its line does not cover. A repo **without** CI does not
  count: that is not a missing verdict, it is a property of the repo, and the summary says
  it once for the run instead of once per ticket.
- **push refused** — the branch is complete, green and committed locally, but the remote
  refused the `git push` (token without the `workflow` scope on a ticket touching
  `.github/workflows/`, branch already there). No session is relaunched — the second
  attempt would fail identically —, no label is changed, the worktree is kept, and the
  remote's reason is carried into the summary from `<n>-push.txt`.

## Ctrl-C

A tool that runs for hours gets interrupted. On `INT`/`TERM`, the orchestrator kills each
worker's **descendants** — the worker is a subshell, `claude` and `pnpm` are under it, and
killing the subshell alone left them orphaned and alive — then collects the worktrees of
the green or absorbed tickets. Those of the reds and the interrupted ones stay: that is
where we go to read what happened.

## Git without a keyboard

The remote is often on SSH, with a passphrase-protected key and no `ssh-agent` — every
`pull` and every `push` then ask for the keyboard, in a tool that means *away from
keyboard*. Worse: detached, the push sleeps without printing anything, indistinguishable
from a ticket taking its time.

The script rewrites `github.com` to HTTPS for the duration of the run and serves the `gh`
token through its credential helper. Nothing is written into `.git/config`, the token never
touches the disk, and the repo's original configuration is not modified (everything goes
through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`).

## Tests

- `./check.sh` — the pure parsers (`label_for`, `blocked_refs`, `meta_line`,
  `deepest_branch`, `peak_context`, `clashing_numbers`, `jval`, `jmodels`, `jspawned`).
  Fast, no side effects.
- `./harness.sh` — the whole orchestrator, without network or LLM: `claude` and `gh`
  stubbed, local bare remote, 8 tickets covering a diamond DAG, the safety net, a crashed
  session, an open external blocker, a cascading freeze, the CI phase and integration.
  It found three bugs on its first run — run it after any change to the loop.

## Accepted limits

- It merges nothing. Human review stays the last gate.
- Parallelism only applies to independent tickets. A chain of four stacked tickets stays a
  chain: `-j 8` will not change that.
- One `pnpm install` per worktree. Hard links from the store, so nearly free on disk, but a
  remote store or a non-hoisted `nodeLinker` would change the bill.
- The integration pass detects the clashes, it does not resolve them.
- `--permission-mode bypassPermissions`: run it in a container if the repo is not
  disposable.
