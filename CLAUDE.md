# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## What this is

Three bash scripts, no dependencies, no LLM in the orchestrator. `afk.sh` chains
`claude -p "/implement GitHub ticket #N"` sessions over the `ready-for-agent` tickets of a
GitHub repo configured by `/setup-matt-pocock-skills`. The README describes the user-facing
behaviour; this file describes the internal invariants.

`skills/` holds two families, and they do not have the same rights.

**Framing a run** — `afk-setup` (write the `.afk.env`), `afk-preflight` (reread the batch
before launching), `afk-debrief` (go through the run on waking up). They propose, they do
not act — a skill launching `afk.sh` or relabelling a ticket would put an LLM back into the
loop through the back door.

**Building an app autonomously** — `afk-spec` (idea → `docs/spec.md` + skeleton + gate,
once), `afk-wave` (open the next wave of tickets), `afk-merge` (land the wave on `dev`,
check the boxes, decide whether to continue). `afk-app.sh` chains them around `afk.sh`, one
wave after another. Those ones **act**: they run in a loop when nobody is awake, so waiting
for approval makes no sense. The invariant holds all the same: they stay **above**
`afk.sh`, which still has no LLM inside — it is the loop that judges, not the orchestrator.

What keeps them honest is not their good will, it is a mechanical guard: `docs/spec.md` is
written once by `afk-spec` and tagged `afk-spec`. The other two can only check boxes, and
they verify it at every turn:

```bash
diff <(git show afk-spec:docs/spec.md | sed 's/\[x\]/[ ]/g') <(sed 's/\[x\]/[ ]/g' docs/spec.md)
```

Non-empty → the loop stops. Without it, whoever writes the criteria and whoever fills them
are the same model. The boxes are neutralised **on both sides** of the `diff`: the tagged
version already contains a checked one (the skeleton makes A0 pass), and a guard
neutralising only one side refuses to run from the very first wave.

And a box is only checked after the criterion's command has **passed on `dev`**: the
counter is mechanical, never a reading. `afk-app.sh` leans on the same principle — it counts
the boxes and the open tickets, it never reads what a session says to decide whether to
continue.

The code and the comments are in English — stick to it.

## Commands

```bash
./afk-app.sh -w 4 -j 3   # the autonomous loop: /afk-wave → afk.sh → /afk-merge, ×4
./check.sh          # pure parsers, ~1 s, no side effects
./harness.sh        # the whole orchestrator, claude and gh stubbed, local bare remote (~1 min)
bash -n afk.sh      # syntax only (check.sh does it first anyway)
./afk.sh -n 43 48   # the plan, without launching anything — useful to validate the scheduler by hand
```

No per-test runner: `harness.sh` is monolithic, it runs in full. To isolate, comment out
the unrelated `want`/`want2`/`want4` calls, or read the traces it leaves in its temporary
`$T` (`run.log`, `run2.log`, `gh.log`).

**Run `./harness.sh` after any change to the loop** (scheduler, worker, worktrees, CI /
integration phases). It found three bugs on its first execution.

## Architecture

### One file, two halves

`afk.sh` splits in two at the line `[[ -n "${AFK_LIB:-}" ]] && return 0`:

- **above**: the pure parsers (`label_for`, `blocked_refs`, `meta_line`, `deepest_branch`,
  `peak_context`, `clashing_numbers`, `jval`, `jmodels`, `jspawned`). `check.sh` does
  `AFK_LIB=1 source ./afk.sh` to test them alone. They must read no global and write
  nothing. The override validation patterns (`RE_TIMEOUT`, `RE_MODEL`, `RE_EFFORT`,
  `RE_VERIFY`) are there too, so `check.sh` tests the ones that actually serve rather than
  a copy. **All four fields pass a pattern**: `Verify` was the only one that did not, and
  the only one whose value is executed.
- **below**: config, guard rails, and the loop. None of that is testable by `check.sh` —
  it goes through `harness.sh`.

Adding a parser ⇒ put it above the guard and give it a case in `check.sh`.

### The pipeline

`plan_run` → `schedule` (→ `launch` → `worker`) → `ci_phase` → `integration_check` → `write_summary`

- **`plan_run`** reads each ticket once through `gh` and caches everything in
  `.afk/<n>.{body,title,labels,verify,timeout}`. The worker never calls the API back for
  metadata. It also sorts the blockers into `DEPS` (in the run, or outside the run but with
  an open PR) and `EXT` (outside the run, freezing).
- **`schedule`** loops over `deps_state`, whose **return code is a tri-state**: `0` ready,
  `1` wait, `2` frozen. Up to `JOBS` live workers.
- **`worker`** runs in a subshell, cwd = its worktree.

### The parent/child protocol

A worker is a subshell: **it cannot write anything into the parent's arrays.** It drops
`key=value` lines into `.afk/<n>.status`, the parent reads them back with `sget`. Any new
information a worker surfaces goes through there.

Keys: `result` (`ok` | `ko` | `absorbed` | `frozen`), `branch`, `base`, `base_ref`,
`attempt`, `pr`, `draft`, `draft_why`, `reason`, `dur`, `session`, `cost`, `model`,
`subagents`. `draft` is a flag set on an `ok`, not a result.

The file is **append-only** and `sget` reads the last line. So the cautious value written at
startup is called `result_initial`, not `result`: a human running `cat` or `grep result=` on
a green ticket used to read `result=ko` at the top. A missing `result` counts as red (`reap`
handles it in its default branch).

`reap` translates these statuses into the parent's arrays (`OK` `KO` `SKIP` `DRAFT`
`ABSORBED` `PUSH_KO` `BRANCH_OF` `FIRST_TRY`), which then feed `ci_phase`,
`integration_check` and the summary. `GREEN` and `UNPROVEN` are computed at summary time
only: `OK` stays the raw list of tickets that opened a PR, `GREEN` removes from it anything
no complete gate has seen (draft, or reduced gate + inconclusive CI). It is `GREEN` that is
displayed.

### Isolation

One ticket = one worktree `.afk/wt/<n>` on `feat/<n>`, created from `origin/<base>`.
**The main tree is never touched** — no `checkout`, `pull` or `reset`. Every git operation
of a worker must stay inside its worktree (`git -C "$wt"` from the parent).
A green worktree is dropped, a red one is kept: it is the debugging artefact.

`set -uo pipefail`, **without `-e`**: a worker failing is a result, not a reason to stop the
run.

### The session

`claude -p … --output-format json`, never `--resume`: the output is an object, not a log.
`jval` reads `subtype` from it (the failure is NAMED instead of returning a code),
`session_id` (the summary turns it into a `claude --resume` for the reds, whose worktree is
kept), `total_cost_usd` (cumulated over the ticket's attempts); `jmodels` reads the models
actually used, the only way to see a `FALLBACK_MODEL` fallback. But `modelUsage` **and** the
cost aggregate the session and its subagents, which carry the model of their definition and
not the ticket's: `jspawned` reads their number, without which a second model reads as a
fallback that never happened (defect 41). Adding a session flag means passing it through
`copts` — and checking that the harness's fake `claude` still returns a readable object,
otherwise every session looks mute.

### The prompt

`build_prompt` receives `head0` — the HEAD from BEFORE the session — and not `HEAD`:
`inherited_note` uses it to list what the blockers delivered
(`git diff --name-only "$BASE_REF...$head0"`). On attempt 2, `HEAD` already carries the
agent's work, which it has nothing to learn from. The harness's fake `claude` copies its
prompt into `$T/prompt-<n>.txt`: the prompt is testable like the rest.

### Deliberate duplication

The `DRY_RUN` block redoes `launch()`'s base/absorption computation (the run's branches do
not exist yet, so `deepest_branch` falls back on its fallback). **The two must stay in
agreement** — changing one without the other makes `-n` lie.

### Git auth

`setup_git_auth` rewrites github.com to HTTPS and wires gh's credential helper, only through
exported `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n`. **Never write into `.git/config`**: the
token must not touch the disk and the host repo's config must not move. The indices are
contiguous — adding a key means incrementing `COUNT`.

## Touching the harness

`harness.sh` stubs `claude` and `gh` with two scripts in a temporary `$PATH`.
**Adding a `gh` call in `afk.sh` means handling it in the fake `gh`** — otherwise it falls
into the final `exit 0` and returns an empty string, which shows up very far from the cause.
Same for a new agent behaviour: it is simulated by a case in the fake `claude`, keyed on the
ticket number extracted from the prompt.

The harness's eight runs are independent and ordered: parallel (diamond DAG, safety net,
crash, freeze), series (absorbed, frozen by its own session, `Timeout:`, in-review),
interruption, stacking on a PR open outside the run (plus the same batch replayed in `-n`,
which must say the same thing), two independent direct blockers (base + absorption, double
inheritance), push refused by the remote + the same path created twice + a stale reference +
a dependant of both whose stacking conflicts, repo without CI, and reduced gate with CI that
does not conclude. The ticket numbers carry their scenario (see the file header) — reusing an
existing number for something else breaks the assertions.

The bare remote carries an `update` hook refusing `feat/17`: that is how a rejected
`git push` is simulated without a network. And the fake `gh pr checks` obeys `NO_CHECKS`
(the repo has no CI), `NO_CHECKS_ONCE` (CI exists but is not registered yet) and `HANG_CI`
(it is still running) — three situations `--watch` rendered with two sentences.

## The logs

Written by hand, one entry per event, never one per commit — `git log` already does that,
and better:

- `CHANGELOG.md` — a change in **observable behaviour**. To fill in at the same time as the
  change, not after.
- `docs/proposals.md` — an idea that was proposed, with its verdict and the reasoning,
  **including the refusals**: an accepted idea leaves a comment in the code, a refused idea
  leaves nothing and comes back. Dismissing a proposal without writing it there means
  agreeing to redo the reasoning.
- `docs/defects.md` — an afk defect observed **for real during a run**, numbered. A code
  comment can point at it (`defect 17`). Only what would have broken the same way on any
  repo goes in: the worked-on project's problems get fixed over there. Written by
  `/afk-debrief` or by hand.
- `docs/defects-fixed.md` — the same ones once **fixed**, same numbering. The live file only
  keeps the open and mitigated ones: a debrief reads it end to end, and thirty closed
  entries cost as much to read as the four that still need a decision. So a reference is
  looked up in `docs/defects*.md`.

Written by the machine:

- `RUNS.md` — one line per run, appended by `append_run_log` at the very end. The facts, not
  a judgement. It lives in `$AFK_HOME` (the script's repo, not the worked-on project)
  because it is the only place mounted in every project, and because `.afk/summary.md` is
  overwritten on the next run. `harness.sh` redirects `AFK_HOME`: without it, its test runs
  would append to it. The project column is a stable digest of the repo directory name, not
  the name itself — this log travels with afk's repo and gets read out of context.

The why of a choice already implemented stays in the comment next to the code — these files
do not duplicate it, they point at it.

## Trust surface

A ticket's `Verify:` and `Timeout:` lines are executed / passed as-is. Tickets are part of
the trust surface, just like the sessions' `--permission-mode bypassPermissions`.
