# Changelog

One entry per change in **observable behaviour** — not one per commit: `git log`
already does that, and better. No version and no tag: the repo has none, the dates
are enough. The reasoning behind a change stays in `afk.sh`'s comments, next to the
code concerned; the verdict on proposed ideas is in
[docs/proposals.md](docs/proposals.md).

## 2026-09-21

### Added

- **Each session keeps a decision journal**, at `.afk/<ticket>-work.tsv`: six
  tab-separated columns (`ts`, `phase`, `decision`, `why`, `evidence`, `result`), appended
  as it goes, one line per decision the diff cannot show — the hypothesis taken because
  nobody was there to decide, the option ruled out and what ruled it out, the red gate and
  what the session concluded from it, anything done outside the ticket's scope.
  `build_prompt` asks for it; nothing enforces it, so a missing journal is a defect to
  record and not a red. `/afk-debrief` reads it at its step 5, **before** deciding wrong
  gate or real failure, and only falls back on `claude --resume` when the journal is silent
  on the point needed. The contract lives in the `/show-me-your-work` skill, outside this
  repo. Read it with `column -t -s $'\t' .afk/<n>-work.tsv`.

### Changed

- **`afk-app.sh`'s wave gained a step**: `/afk-wave` → **`/afk-preflight apply`** →
  `afk.sh` → `/afk-merge`. The batch was going into the night exactly as it was opened, so
  a ticket too big for its budget, a criterion no gate can see or two tickets writing into
  the same files cost the wave. A failure of this step is **not** fatal: the wave then runs
  unreviewed, which is the previous behaviour, and that is cheaper than losing the
  remaining waves. The ticket count is taken again afterwards — preflight cuts and
  serialises — and an emptied batch stops the loop (`preflight emptied the batch`).
- **`/afk-preflight` gained an `apply` mode**, invoked only by that loop. Steps 1 to 6 are
  unchanged; step 7 applies the mechanical fixes (cut, serialise with a `Blocked by`, hand
  out the ADR and migration numbers, fix a `Timeout:` or a proven `Verify:`) instead of
  proposing them, because nobody is awake to approve a table. It still refuses to rewrite
  an acceptance criterion — that is what the `afk-spec` tag exists to prevent — and takes
  such a ticket out of the batch with a comment instead. Called without `apply`, the skill
  behaves exactly as before.

## 2026-09-16

### Changed

- **Everything is in English** — code, comments, output, prompt, skills and docs. Two
  consequences for ticket authors: the session sentinels are now `AFK: ALREADY DONE` and
  `AFK: BLOCKED <what is missing>` (a ticket body or a prompt still saying
  `AFK: DEJA LIVRE` / `AFK: BLOQUE` is no longer recognised), and every line the run
  prints changed wording, so any script grepping `afk.sh`'s output has to be adjusted.
  `docs/defauts.md`, `docs/defauts-corriges.md` and `docs/propositions.md` are now
  `docs/defects.md`, `docs/defects-fixed.md` and `docs/proposals.md`; the defect numbering
  does not move.
- **`RUNS.md` no longer names the project.** `append_run_log` writes a stable digest of the
  repo directory name (`project-6c618d6f`) instead of the name itself: this log travels
  with afk's repo and gets read out of context, and the column is only read to group one
  project's rows. The same project always yields the same value, so the history stays
  comparable. The existing rows were rewritten with their matching digests, and
  `docs/defects*.md` uses the same ones.

## 2026-09-13

### Added

- **Three skills to build a whole app without waking up between two runs**:
  `/afk-spec` (an idea → `docs/spec.md`, the skeleton, the gate and the milestones, once
  only), `/afk-wave` (open the next wave of tickets from the unchecked criteria **and**
  the repo's real state), `/afk-merge` (land the wave on `dev`, check off what the command
  proves, say whether the loop continues). **`afk-app.sh`** chains them:
  `./afk-app.sh -w 4 -j 3`. Its control flow is mechanical — it counts the spec's boxes
  and the open tickets, never what a session says, so a session that declares itself
  victorious can neither extend the loop nor stop it. `afk.sh` does not change: the loop
  is above it, the orchestrator stays LLM-free. Every criterion of the spec carries the
  command that proves it, `docs/spec.md` is tagged `afk-spec` and can only receive boxes
  from then on — see [docs/proposals.md](docs/proposals.md).

### Fixed

- **The summary's "Context" column no longer goes dark on a path containing an
  underscore.** `ctx_of` rebuilt the transcript directory's name by replacing `/` and `.`,
  where Claude Code also replaces `_`: on a `$HOME` like `/home/jane_doe`, the
  directory it looked for did not exist and the column returned `—` on every ticket,
  without telling "nothing found" from "nothing to report" (defect 42).

- **A ticket whose blockers are delivered but do not hold together comes out
  "conflict", no longer "frozen".** The word was the one for a prerequisite never
  delivered, and the PR column is empty in both cases: the diagnosis went looking for a
  missing blocker that does not exist. The summary now names the conflicting paths under
  the table, as it already does for branches set aside at integration, and
  `.afk/<n>-wt.err` — the only log such a ticket has — entered the logs legend (defect 45).

- **`-n` no longer announces as frozen what the run launches.** The plan only counted as
  deliverable a blocker delivered *in this run*, where the scheduler is happy with a
  pushed branch: an out-of-batch blocker with an open PR came out "frozen — undeliverable
  blocker" in the very output that had just printed its base. It is when resuming an
  interrupted run that the plan is read, so exactly where it said the opposite of what was
  going to happen (defect 44).

### Added

- **A "Phases" column in the summary: install / session / gate.** A ticket's duration did
  not say where it went, and three of those four phases are tunable (`JOBS`, `TIMEOUT`,
  `VERIFY_CMD`, `SETUP_CMD`): serialising the gate has no effect where it lasts a minute.
  The fourth, waiting on a lock, is what "duration" carries on top of their sum. The
  phases are timed by afk, so background subagents included, where the session's own
  `duration_ms` only covers its main loop (defect 43).

## 2026-09-09

### Fixed

- **A session refusing because it is too early is no longer announced as "absorbed".**
  Exiting without a commit, it was decided by the gate on the base alone: green, the
  ticket moved to `in-review` with a comment inviting closure, although nothing had been
  done. The prompt now asks the session to name its case on its last line
  (`AFK: ALREADY DONE` or `AFK: BLOCKED <what is missing>`); "blocked" comes out
  **frozen** — label unchanged, no PR, a comment saying what is missing, and the ticket
  comes back on the next run. Without that line, the behaviour is the previous one
  (defect 40).
- **The "Model" column says how many subagents ran** — `sonnet-5 (+2 subagents)`.
  `modelUsage` aggregates the session and its subagents, which carry the model of their
  definition (`.claude/agents/*.md`): a second model read as a `FALLBACK_MODEL` fallback,
  when it came from a review the session launched. The summary's legend now says which of
  the two readings applies (defect 41).

## 2026-09-07

Three defects found on a batch of eleven tickets, one of which was not one.

### Added

- **The gate runs once on the base, before the first worktree.** A red test pushed
  straight onto `develop` (so no PR, so no CI) failed six tickets out of eleven, each
  paying for its own diagnosis then a second attempt, and seven branches fixing the same
  file on their own side. The gate only ever judges "base + ticket": it now judges the
  base alone first. Red, the run continues — whoever launched it has gone — but the
  header, the summary and `summary.md` say so, and `.afk/base-verify.txt` keeps what it
  takes to clear a red ticket (defect 38).

### Fixed

- A ticket's duration is repeated **after** its log, not only in its header: the last
  duration on screen was the project's test runner's, which times the gate (defect 37).

## 2026-09-06

### Fixed

- `.afk/summary.md` claimed "only their CI ran the complete gate" even on a repo without
  `.github/workflows`, where the summary printed on screen says the opposite. The sentence
  now follows the same condition as the summary: without CI, the written summary says the
  local gate is the only one that ran (defect 36).
- The summary, the written summary and the PR bodies speak of a local gate **replaced**
  and no longer "reduced": a `Verify:` line can be wider than the repo's gate, and a
  ticket verified more than the others was presented as the least verified.

## 2026-09-04 (2)

Two defects seen with `-n` on a batch of fifteen tickets, **before** launching: the run
never happened.

### Fixed

- A `Verify:` line written as in a well written ticket — the command in `code`, then in
  prose what it does not cover — went **whole** to `bash -c`, markdown bold included,
  where the `**` globbed over the cwd. Fifteen tickets red on both attempts for a reason
  that had nothing to do with them, and the `.afk.env`'s `VERIFY_CMD` never run once.
  `meta_line` eats the bold that follows the `:` and, when the value starts with a
  backtick span, keeps only that span. The README's bare form stays accepted (defect 33).
- `Verify` gets its validation pattern, `RE_VERIFY`, like `Timeout`, `Model` and `Effort`:
  a value ending in `:` is an introducing sentence, not a command — it is ignored and the
  ticket falls back on `VERIFY_CMD` (defect 33).
- A gate that **starts in prose** and quotes its commands mid-sentence ("by hand,
  `python -m app hub` + `npm run dev`: …") is refused too. It does not start with a
  span and does not end in `:`: the two rules above let it through whole, three tickets
  out of fifteen. So the backticks now only fall when the value **is** the span, and
  `RE_VERIFY` refuses one that keeps a backtick — after cleanup, a leftover backtick can
  only come from prose quoting commands. An old-style `` `cmd` `` substitution is refused
  along with it (defect 33).
- "No CI declared" no longer counts as "CI inconclusive". The first is a property of the
  repo: on a repo without a workflow, it marked "unproven green" any ticket carrying a
  `Verify:`. The summary now says it once for the run, naming the reduced-gate tickets
  (defect 34).

## 2026-09-04

Nine defects recorded in [docs/defects.md](docs/defects.md) after heavy use on a real
repo. Eight fixed, one mitigated.

### Added

- **`unproven green`** and **`push refused`** in the summary. A ticket with a reduced
  local gate whose CI did not conclude was seen by no complete gate; a branch the remote
  refused to receive is complete and green, only not pushed. Both leave the `green`
  column, and a refused push changes no label and relaunches no session — the second
  attempt would fail identically (defects 30, 32).
- The summary's `draft` line says **which** of the three anomalies put it there: `cut`,
  `abnormal`, `not committed`. A session cut at the `timeout` may have been cut in the
  middle of a file — that is not the same review as a session that yielded its turn, and
  the PR body says so too (defect 31).
- Integration flags the **same path created by several branches**: two branches adding the
  same file are each green on their own side, and only the merge sees it (defect 25). And
  it lists the **run's tickets cited in the merged docs**: a future-tense sentence about
  something delivered ten minutes ago produces no conflict (defect 24, detection only).
- One line in the prompt: the agent does not run the gate itself. That is what ate a
  session's turn, which ended on `Gate still running` without having committed (defect 31).
- `CI_RETRY_WAIT`: `gh pr checks --watch` only watches checks that are already registered
  and exits immediately when there are none. The last PR created was therefore
  structurally exposed — four seconds late, filed as "no CI declared". afk retries four
  times before concluding (defect 29).

### Fixed

- Integration merges in **topological order**: a stacked branch merged before its base
  conflicts by construction, and that read as a real overlap (defect 27).
- `summary.md` keeps the **conflicting files** branch by branch, along with the duplicate
  numbers and paths. It was displayed then thrown away: terminal closed, it had to be
  rebuilt with `git merge-tree` while guessing the merge order (defect 26).
- A branch's added files are counted against **its** base and not against the common base:
  a stacked branch carries its blocker's commits (defect 25).
- The first line of `<n>.status` no longer says `result=ko` on a green ticket: the cautious
  startup value is called `result_initial` (defect 28).

## 2026-09-03

### Added

- The summary gives, per ticket, the **model that actually ran** and the **cost**
  cumulated over its attempts. The sessions run with a fallback model
  (`FALLBACK_MODEL=sonnet`): without it, a transient model outage burns a ticket's two
  attempts in a few seconds and empties the queue — an AFK run has nobody in front of it
  to see it.
- A red ticket can be resumed by hand: the summary gives its
  `(cd .afk/wt/<n> && claude --resume <id>)`. Its worktree was already kept, its session
  too — what was missing was a way back in.
- A ticket can declare its model and its thinking level, as it already declares its gate
  and its time budget: `Model:` and `Effort:` lines in its body (`MODEL` / `EFFORT` for
  the global setting).
- `RUNS.md` in afk's repo: one line per run, appended automatically at the end. Since
  `.afk/summary.md` is overwritten on the next run, no history survived anywhere; this one
  spans the runs **and** the projects, afk's repo being mounted in each of them.
  `AFK_HOME` says where it is written.
- `docs/defects.md`: the register of afk's defects seen during a run, numbered and written
  by `/afk-debrief`. `afk.sh` already cited "defect 17" without that number pointing at
  anything.
- Two skills frame the run, where judgement is needed and the script has none:
  `/afk-preflight` rereads the batch before launching (what will be frozen, what no gate
  can check, what does not fit in its budget), `/afk-debrief` goes through the run on
  waking up and sorts each non-green by cause.

### Fixed

- A session that stops badly **names** its failure (`error_during_execution`,
  `error_max_turns`, …) instead of returning a code. The sessions come out in JSON
  (`--output-format json`), so `.afk/<n>-<attempt>.log` becomes `.afk/<n>-<attempt>.json`.

## 2026-09-02

### Added

- A stacked ticket receives in its prompt what its blockers already delivered: the list of
  their ADRs / `CONTEXT.md` to read before coding, then the list of files already touched.
  The work was already on disk (the worktree starts from the blocker's branch), but the
  agent started in a fresh session without knowing it — it redid work already done, or
  renamed a contract it had just inherited.

### Fixed

- `CLAUDE_CONFIG_DIR`: the default looks for the directory that really contains the
  mattpocock plugin, instead of a hardcoded path — in a devcontainer, `$HOME` is not where
  the host config is mounted.

## 2026-08-31

### Fixed

- The ticket listing no longer truncates at 30 without saying so (`gh issue list` caps
  silently, and returns the most recent ones): the tickets outside the slice showed up as
  "blockers open outside the run", so a silent freeze.
- `SETUP_CMD` receives `AFK_TICKET` / `AFK_WORKTREE`, what it takes to isolate a worktree
  from its neighbours. Without it, several worktrees shared the test database of a
  versioned `.env.test`, and a neighbour's migration marked the current ticket red.
- The integration pass names its scope: a green verdict after a branch was set aside at
  merge read as "everything combines", the very question it exists to answer. It also
  accepts a separate gate (`INTEGRATION_VERIFY_CMD`), because a build cache hashing the
  files tracked by git returns a ✓ without having compiled a line.
- A refused merge (dirty tree, missing base) is no longer written "CONFLICT": it is not
  the same information, and it sent you looking in the wrong place.
- Numbers taken twice (ADRs, migrations) are flagged at integration. Each worktree starts
  from the base without seeing its neighbours, so each agent takes the free number it sees
  and it is right: the names differ, git sees no conflict, no gate can say it.
- A single "integration" verdict in the summary: two lines with the same name read as two
  contradictory verdicts.
- The run header announces the integration gate when it differs from the tickets' gate.

## 2026-08-22

### Added

- `afk.sh`: chains `/implement` over the `ready-for-agent` tickets, one worktree and one
  fresh session per ticket, PRs stacked according to the blocker DAG.
- `check.sh` (pure parsers) and `harness.sh` (the whole loop, `claude` and `gh` stubbed).
- `.afk.env`: the project declares its own verification gate and its dependency install,
  where the real definition of "done" lives.
- `/afk-setup` to write that `.afk.env`.
- Each session's peak context in `.afk/summary.md`: the thermometer of the slicing. It
  measures the size of the work, not its quality.
