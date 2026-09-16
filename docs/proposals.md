# Proposals and verdicts

What was proposed for `afk.sh`, what was decided, and why. One entry per proposal,
including — especially — the ones that get refused: an accepted idea leaves a comment in
the code next to what it produced, a refused idea leaves nothing, and it comes back in
three months with the same arguments.

Here and not in GitHub issues: the reasoning leans on line numbers and on `afk.sh`'s
invariants, it has to drift with the code and be readable without a network. An issue
stays the right place as soon as it needs discussing with several people or tracking a
state.

Format: title, verdict, reasoning. Verdicts used: **accepted**, **already done**,
**refused**.

---

## Judgement around the run, not inside it — accepted

*2026-09-03*

Proposed: two skills, `/afk-preflight` before the run and `/afk-debrief` after.

The orchestrator deliberately holds no LLM: ordering, launching, verifying, pushing,
labelling require no judgement. But two moments do, and they both fall **outside** the
loop:

- before: a ticket whose criteria no gate can check, or which will be frozen by a blocker
  already merged but not closed, costs `MAX_ATTEMPTS × TIMEOUT` of the night — and its
  dependants' night too. `./afk.sh -n` already gives the whole mechanism (waves, bases,
  freezes, effective gate); what was missing is the review of the *content*, which the
  script cannot do.
- after: a red does not say whose fault it is. Wrong gate, badly seeded worktree, model
  unavailable, ticket too big, real failure — five causes, five different files to read,
  five different follow-ups.

Accepted as skills and not as code: both produce a judgement and proposals, never an
action. Neither of them runs `afk.sh`, relabels or merges — otherwise it is LLM in the
loop, through the back door.

## What the session says about itself (`--output-format json`) — accepted

*2026-09-03*

Proposed: launch the sessions with `--output-format json` rather than as text, and read
the returned object.

Three things come out of it that no log reading gave:

- `subtype` **names** the failure (`error_during_execution`, `error_max_turns`) where the
  return code gave a number. That is the difference between "claude returned 1" and a
  cause.
- `session_id` makes the session resumable. A red ticket's worktree was already kept and
  the session already existed: only the id was missing to get back in. The summary turns
  it into a `(cd .afk/wt/<n> && claude --resume <id>)` — for the reds only, since
  `--resume` looks for the session in the directory where it ran, and a green ticket's
  worktree is thrown away.
- `total_cost_usd` and `canonicalModel` give the ticket's price and real model.

Price: `.afk/<n>-<attempt>.log` becomes an object and is no longer readable by eye.
Accepted — the session log was not what we read to diagnose (that is `<n>-fail.txt`), and
what it contained is better served by a `--resume`. The variant keeping both
(`stream-json` + an awk separating the text from the final object) was ruled out: it adds
a parser to preserve a file nobody opens.

`jval` and `jmodels` read with `grep`, without jq: the session's error output lands in the
same file, a strict JSON parser would refuse to read it — and `jq` is not among the
binaries required at startup.

## Fallback model when the main one is unavailable — accepted

*2026-09-03*

Proposed: `--fallback-model`.

An AFK run has nobody in front of it. Without a fallback, a transient model outage errors
the session out, the ticket burns both attempts in a few seconds and goes to
`ready-for-human` for a reason that has nothing to do with it — then the next one, and the
whole queue follows. The flag only works with `--print`, so exactly here.

The risk of the fallback is that it is silent: a night can change model without saying so,
and the next day's green rate is then read against a false baseline. That, and not the
cost, is why the summary gained a "model" column — a fallback is only acceptable if it is
visible. Same family as the `gh issue list` capped at 30 without saying so, or the build
cache returning a ✓ without compiling.

## Model and effort per ticket — accepted

*2026-09-03*

Proposed: `Model:` and `Effort:` lines in a ticket's body.

Same argument as `Verify:` and `Timeout:`, and that is the reason to accept it: the global
setting is cut for the average ticket, and whoever writes the ticket is the only one who
knows, before it runs, that this one is not average. A typo fix does not need the model of
a rework.

Since the four lines only differ by their name and by what they accept as a value, the two
existing parsers were replaced by a single one (`meta_line`) — so two extra fields cost no
function at all. Their validation patterns live next to it (`RE_TIMEOUT`, `RE_MODEL`,
`RE_EFFORT`) and are sourced by `check.sh`: a pattern copied into the test would only
verify itself.

`RE_MODEL` is not a list of known names — it would be stale at the next model. It only
forbids what is not a name. A well-formed but wrong name fails the session immediately,
exactly like a `Verify:` line that does not compile: it is the same trust surface.

## A log of findings between tickets of the same lineage — accepted, differently

*2026-09-02*

Proposed: at the end of a green ticket, the agent writes a summary (`DISCOVERY.md`,
`.afk/findings/<n>.md`) of what goes beyond its scope; when a dependent ticket opens, the
orchestrator walks up the DAG and concatenates its ancestors' files into its prompt.

The problem is real, it has cost twice: the absorbed ticket, which burns both attempts
rediscovering alone that its work is done, and the typed contract renamed by a dependant
that did not read its predecessor's ADR.

But both halves of the mechanism already exist. The capture: the prompt has required from
the start that every non-trivial decision be written into a `CONTEXT.md` or an ADR, and
the worker grumbles when nothing was touched. The DAG filtering: `launch()` creates the
dependant's worktree **from its blocker's branch**, so the predecessor's ADR is already on
disk, and the base only contains the ancestors. `.afk/findings/` would have copied into an
ephemeral file what is already committed.

What was missing was not the capture, it was the pointer: the agent starts in a fresh
session and does not know which files its ancestors touched. Accepted as a section of the
prompt (`inherited_note`) built from a `git diff --name-only "$BASE_REF...$head0"`,
filtered by `MEMORY_RE` for the "read before coding" list. No format imposed on the agent,
no file to produce.

Corollary, and it is the reason not to go through a file: several direct blockers merge by
themselves. `launch()` takes the dominating branch as the base and **merges the others on
top** in the worktree, so `head0` carries the work of every blocker and the diff covers
them all. A copied `.discovery.md` would have raised the question of write order and who
wins; a git merge does not — and if two siblings really overlap, the merge fails and the
dependant is frozen rather than launched on half the work. The harness's fifth run covers
this case (two independent siblings, one common dependant): the first run's diamond did
not reach it, its base always already containing the other branch.

## Building a whole app autonomously, from an idea — accepted

*2026-09-13*

Proposed: start from an app idea rather than from an already sliced batch of tickets.
Three skills above `afk.sh` — `afk-spec` once, then `afk-wave` and `afk-merge` in a loop
around each run.

What was missing was not the first slicing, it was the **re-slicing**: a wave's tickets
depend on the code the previous wave actually wrote. So everything cannot be sliced up
front, and that is what forced waking up between two runs.

These three act without approval, unlike the other three skills: they run when nobody is
around. `afk.sh` itself does not change and stays LLM-free — the loop is above it, not
inside it. What holds them is not their discipline but a mechanical guard: `docs/spec.md`
is written once, tagged `afk-spec`, and a `diff` that neutralises the boxes refuses any
other change. Without it, whoever writes the criteria and whoever fills them are the same
model. And a criterion carries the command that proves it: checking off means running the
command on `dev` and reading the return code, never reading the work.

### Claude Code's `/goal` as a stopping condition — refused

Its `Stop` hook rereads **the session transcript** and returns `{ok, reason, impossible}`.
Two things disqualify it: it judges an agent's narrative and not the repo — an agent that
says it works convinces it — and it makes **a single** session last, where afk's whole
design is a fresh session per ticket and per attempt. It would remain usable to replace
the worker's 2nd attempt; that is a bad trade.

### The `gauntlet-loop` loop on every ticket — refused

A critic with fresh context per ticket multiplies the bill while afk's gate is already
deterministic, and the critic adds nothing where a command decides. Its place is
elsewhere: the tickets no command can judge — a rendering, a page, an animation. The day a
real reference is named, that is written `Gauntlet: <reference>` in the ticket body, same
family as `Verify:` / `Model:` / `Timeout:`, same parser, same trust surface. Nothing to do
as long as no project has a reference to aim at — that is why `afk-spec`'s spec forbids
taste criteria: a criterion no command judges blocks the loop forever, or gets checked off
blind.

## Sharing `node_modules` between worktrees through a symlink — refused, differently

*2026-09-13*

Proposed: instead of reinstalling the dependencies in each worktree, a symlink of
`node_modules` from the main tree. `t_setup` is several minutes per ticket on a monorepo,
and it is paid as many times as there are tickets.

The symlink does not work, and not for a pnpm-specific reason. If `wt/node_modules` is a
link to `main/node_modules`, every relative path inside it resolves from where the real
folder lives: the kernel follows the link before resolving the `..`. In a workspace,
`apps/*/node_modules/@x/<package>` → `../../../packages/<package>` therefore lands in
**the main tree**. The worker compiles against code it does not modify, its own changes in
`packages/*` are invisible to it, and it goes green for the wrong reason. Incidentally it
reads the main tree, which the rest of the script forbids itself to touch. On a flat repo
without a workspace it does not bite, but writing remains: a `pnpm add` in a worktree
modifies the shared tree, and at `-j 3` two workers step on each other.

What works instead is a **hard-link copy** (`cp -al`): each worktree has its own directory
tree, so relative paths resolve at home, and the files share their inodes — neither disk
nor time. The only blind spot is a `postinstall` that modifies a file in place, which
would leak to the neighbours.

Nothing to change in `afk.sh` for all that: `SETUP_CMD` is already the project's hook, and
it receives `AFK_TICKET` / `AFK_WORKTREE` exactly for this, under the `install` lock so
serialised.

```bash
SETUP_CMD='cp -al "$REPO_ROOT/node_modules" "$AFK_WORKTREE/node_modules" 2>/dev/null; pnpm install --prefer-offline'
```

It is a project decision and not afk's: the script cannot know whether the repo is a
workspace, whether a `postinstall` writes in place, nor where the store is. And before all
that, `grep -h 't_setup=' .afk/*.status` — on a shared pnpm store and on the same
filesystem, a fresh install is hard links and costs only seconds; when it is long, it is
often the `postinstall`s (`prisma generate`, native builds) that no `node_modules` sharing
would avoid.

## Bringing failure logs back onto the GitHub issue — already done

*2026-09-02*

Proposed: when the gate fails, post the error log as a comment on the issue, to diagnose
on waking up from GitHub without opening a terminal.

That is the current behaviour. After `MAX_ATTEMPTS`, the worker posts the last 40 lines of
`<n>-fail.txt` on the issue and moves the ticket back to `ready-for-human`; the CI phase
does the same when the repo's CI is red while the local gate was green.

## Enriching the retry with the previous failure log — already done

*2026-09-02*

Proposed: on attempt 2, inject the previous failure's log (or the issue's latest comments)
into the prompt so the agent can pivot.

That is the `--- RETRY (attempt n) ---` block of `build_prompt`, which injects the last 60
lines of `<n>-fail.txt`. Deliberately the local log and not the issue's comments: it is the
same information, without a network call.

## A socket registry, orchestrator → worker — refused

*2026-09-02*

Proposed: each worker publishes its `CLAUDE_CODE_MESSAGING_SOCKET` into `.afk/<n>.socket`,
with `crossSessionInbound: "accept"` in its `--settings`, so the orchestrator can talk to a
running session.

The three use cases cited cannot happen:

- "a blocker turns red while its dependant is working" — `deps_state` only returns `0`
  (ready) when every blocker in the run is green. A dependant is never alive at the same
  time as its blocker.
- "the CI of a stacked PR breaks while the next ticket works on it" — `ci_phase` runs after
  `schedule`, no worker is alive any more.
- "graceful shutdown on INT" — the work is not lost: `result=ko` is written as soon as the
  worker starts, so `finish()` keeps the worktree, dirty tree included.

Remaining gain: one more `git add -A` on interruption. Price: a settings file per worker, a
socket, one more entry path into a session in `bypassPermissions`, and logging every
injected message to keep reproducible logs. To reconsider only if the scheduler stops
waiting for the blockers — that is, if it changes nature.

## "Absorbed" requires a blocker delivered in this run — refused

*2026-09-09*

To settle defect 40 without reading the session's text: a ticket is only declared absorbed
if at least one of its blockers delivered a branch in this run — otherwise nobody could
have absorbed it. It is mechanical, and it would have caught the case seen (#114 had no
declared blocker, so no inherited base).

But it breaks the case "absorbed" was written for: a ticket whose content was already in
`master` **before** the run has no blocker in this run, and it would become a red with two
attempts again for a false reason. The rule trades a false "to close" for a false "handed
back to a human". So we read the session, which is the only witness to the difference.

## Messaging between concurrent workers — refused

*2026-09-02*

The DAG guarantees that two workers launched at the same time are independent: they have
nothing to say to each other. What they really share is a resource, not information (the
test Postgres, the ports, the RAM), and that is settled with `flock` — `VERIFY_LOCK` and
the `install` lock — not by a negotiation between agents.

## Memory capture by an LLM (claude-mem and the like) — refused

*2026-09-02*

Slicing into tickets *is* the memory system: one ticket = one fresh session = one scope.
The ADRs and `CONTEXT.md` are its durable trace, written by the agent that made the
decision. Adding an LLM capture on top puts noise into a loop deliberately kept LLM-free —
the orchestrator orders, launches, verifies, pushes, labels, and none of that requires
judgement.
