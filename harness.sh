#!/usr/bin/env bash
# harness.sh — integration test of the orchestrator, without network or LLM.
#
# check.sh tests the parsers. This one tests everything else: the scheduler over the
# DAG, the worktrees, the safety net, crashed-session detection, stacked PRs, cascading
# freezes, the CI phase and integration. `claude` and `gh` are stubbed, the remote is a
# local bare repo.
#
# It found three bugs on its first run (duplicated freeze message, printf whose format
# starts with "-", undefined reaping order). Run it after any change to the loop.
set -uo pipefail
cd "$(dirname "$0")"
AFK="$PWD/afk.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fix" "$T/cfg/plugins/cache/mattpocock"

# ─── The test DAG ─────────────────────────────────────────────────────────────
# 1 ← 3 ← 4, and 4 ← 1 too: the base of 4 must be feat/3 (which contains feat/1),
#                           and feat/1 must NOT be announced as absorbed.
# 2: the agent does not commit           → safety net → draft
# 5: blocked by #99, open outside the run → frozen
# 6: the agent crashes (rc=1) after committing → draft
# 7: verification red on both attempts   → ko
# 8: blocked by 7                        → cascading freeze
printf '## Blocked by\n\nNone\n' > "$T/fix/1.body"
for n in 2 6 7; do cp "$T/fix/1.body" "$T/fix/$n.body"; done
printf '## Blocked by\n\n- #1\n'       > "$T/fix/3.body"
printf '## Blocked by\n\n- #1\n- #3\n' > "$T/fix/4.body"
printf '## Blocked by\n\n- #99\n'      > "$T/fix/5.body"
printf '## Blocked by\n\n- #7\n'       > "$T/fix/8.body"

# ─── The second run's batch ───────────────────────────────────────────────────
#  9: the agent produces nothing, the base is green → absorbed (neither red nor ready-for-human)
# 10: blocked by 9                                  → does not freeze, starts from 9's base
# 11: already in-review                             → dropped from the list
# 12: Timeout:/Model:/Effort: in the body           → ticket-level overrides
# 13: the agent produces nothing, its gate is red   → real failure, ko
# 25: the agent produces nothing, the base is green, but it SAYS it is blocked → frozen
printf '## Blocked by\n\nNone\n'                    > "$T/fix/9.body"
printf '## Blocked by\n\n- #9\n'                    > "$T/fix/10.body"
printf '## Blocked by\n\nNone\n'                    > "$T/fix/11.body"
printf 'Timeout: 90m\nModel: sonnet\n**Effort**: high\n\n## Blocked by\n\nNone\n' > "$T/fix/12.body"
printf 'Verify: false\n\n## Blocked by\n\nNone\n'  > "$T/fix/13.body"
printf 'in-review\n'                                 > "$T/fix/11.labels"
printf '## Blocked by\n\nNone\n'                    > "$T/fix/20.body"
printf '## Blocked by\n\nNone\n'                    > "$T/fix/25.body"

# ─── The sixth run's batch ────────────────────────────────────────────────────
# 17: the remote refuses its branch     → push refused, not an implementation failure
# 18 × 19: create the same file         → no gate sees it, only the merge says so
# 18 cites #19 in the future tense in a .md → stale reference, git merges that silently
# 21: reduced gate + silent CI          → "green" without any complete gate having run
# 22: gate written in markdown          → the command comes out of the span, the prose stays
# 23: gate red on the base              → said once, before the first worktree
for n in 17 18 19; do printf '## Blocked by\n\nNone\n' > "$T/fix/$n.body"; done
# 26: blocked by 18 AND 19, which write the same file → merging their branches in its
# worktree conflicts. Its prerequisites are ALL delivered: "frozen" said the opposite,
# and the only trace (26-wt.err) was cited nowhere (defect 45).
printf '## Blocked by\n\n- #18\n- #19\n' > "$T/fix/26.body"
printf 'Verify: true\n\n## Blocked by\n\nNone\n'      > "$T/fix/21.body"
# 22: the gate written as in a well written ticket — the command in `code`, then in
# prose what it does not cover. The whole line went to `bash -c`.
printf '**Verify:** `true`, plus one fresh test per point:\n\n## Blocked by\n\nNone\n' > "$T/fix/22.body"
# 23: the base is red before the run → say it once, and do not blame the ticket
printf '## Blocked by\n\nNone\n' > "$T/fix/23.body"

cat > "$T/bin/gh" <<'X'
#!/usr/bin/env bash
FIX="$HARNESS/fix"; log() { echo "$*" >> "$HARNESS/gh.log"; }
case "$1" in
  auth)  [[ "$2" == token ]] && echo faketoken; exit 0 ;;
  api)   exit 1 ;;                                  # no native dependencies
  label) case "$2" in
           list)   printf 'ready-for-agent\nin-review\nready-for-human\n' ;;
           create) log "label create $3" ;;
         esac; exit 0 ;;
  issue) case "$2" in
           view) n="$3"
             [[ "$*" == *"--json body"*   ]] && { cat "$FIX/$n.body" 2>/dev/null; exit 0; }
             [[ "$*" == *"--json title"*  ]] && { echo "title of ticket $n"; exit 0; }
             [[ "$*" == *"--json labels"* ]] && { cat "$FIX/$n.labels" 2>/dev/null || echo enhancement; exit 0; }
             [[ "$*" == *"--json state"*  ]] && { echo OPEN; exit 0; } ;;
           edit)    log "edit $*" ;;
           comment) log "comment $3" ;;
           list)    printf '1\n2\n' ;;
         esac; exit 0 ;;
  pr)    case "$2" in
           # Open PR for #99, only when the test asks for it: the first run needs #99
           # not to have one, to check the freeze.
           list)   [[ -n "${OPEN_PR:-}" && "$*" == *"--head feat/99"* ]] && echo "feat/99"
                   exit 0 ;;
           create) for a in "$@"; do [[ ${prev:-} == --head ]] && b=$a; prev=$a; done
                   log "pr create $*"; echo "https://x/y/pull/9${b##*/}"; exit 0 ;;
           # NO_CHECKS       : the repo has no CI, --watch exits immediately.
           # NO_CHECKS_ONCE  : CI exists but is not registered YET (the real case,
           #                   ~4 s after `gh pr create`) — afk must retry.
           checks) [[ "$3" == --help ]] && { echo "  --fail-fast"; exit 0; }
                   nc() { echo "no checks reported on the 'feat/x' branch"; exit 1; }
                   [[ -n "${HANG_CI:-}" ]] && sleep 987   # CI still running: timeout
                   [[ -n "${NO_CHECKS:-}" ]] && nc
                   [[ -n "${NO_CHECKS_ONCE:-}" && ! -f "$HARNESS/ci-$3" ]] && { touch "$HARNESS/ci-$3"; nc; }
                   exit 0 ;;
         esac ;;
esac
exit 0
X

cat > "$T/bin/claude" <<'X'
#!/usr/bin/env bash
p=""; for a in "$@"; do [[ ${prev:-} == -p ]] && p=$a; prev=$a; done
n=$(grep -o '#[0-9]\+' <<<"$p" | head -1 | tr -d '#')
printf '%s\n' "$p" >> "$HARNESS/prompt-$n.txt"   # the prompt is testable, like the rest
printf '%s\n' "$*" >> "$HARNESS/args-$n.txt"     # so are the flags passed to claude

# The object of `claude -p --output-format json`, on stdout: afk reads the failure, the
# cost, the model actually used and the session id from it. Empty or free-form output
# would make every session look mute.
res() { printf '{"session_id":"sess-%s","total_cost_usd":0.5,"is_error":%s,"subtype":"%s",' \
          "$n" "${2:-false}" "${1:-success}"
        printf '"subagent_stats":{"spawned":%s,"spawned_by_subagents":0},' "${SPAWNED:-0}"
        printf '"modelUsage":{"m":{"canonicalModel":"claude-sonnet-5"}},"result":"done"}\n'; }
# The session of #12 launches two reviews: one extra model in modelUsage without any
# fallback having kicked in (defect 41).
[[ "$n" == 12 ]] && SPAWNED=2
case "$n" in
  9|13) res; exit 0 ;;                 # exits cleanly without producing anything
  # Nothing produced, base green — but the session NAMES what is missing: frozen, not absorbed.
  25) printf '{"session_id":"sess-25","total_cost_usd":0.5,"is_error":false,"subtype":"success",'
      printf '"modelUsage":{"m":{"canonicalModel":"claude-sonnet-5"}},'
      printf '"result":"No change.\\nAFK: BLOCKED #107 not merged into this base yet"}\n'
      exit 0 ;;
  20) sleep 987654 ;;                  # never finishes: target of the interruption
  2) echo "i write and i do not commit" > work-$n.txt; res; exit 0 ;;
  6) echo x > work-$n.txt; git add -A; git commit -qm "feat(#6): ok"
     res error_during_execution true; exit 1 ;;
  7) touch BROKEN; git add -A; git commit -qm "feat(#7): breaks"; res; exit 0 ;;
  18) echo "export const a = 1" > shared.ts
      mkdir -p docs; echo "the list: #19 is the one that will open it" > docs/stale.md
      git add -A; git commit -qm "feat(#18): ok"; res; exit 0 ;;
  19) echo "export const b = 2" > shared.ts
      git add -A; git commit -qm "feat(#19): ok"; res; exit 0 ;;
  *) echo x > work-$n.txt; mkdir -p docs/adr; echo "adr $n" > "docs/adr/000$n-x.md"
     git add -A; git commit -qm "feat(#$n): ok"; res; exit 0 ;;
esac
X
chmod +x "$T/bin/gh" "$T/bin/claude"

# ─── Throwaway repo ───────────────────────────────────────────────────────────
git init -qb master "$T/repo"; git init -q --bare "$T/origin.git"
cd "$T/repo"
git config user.email a@b; git config user.name t
mkdir -p docs/agents
echo "tracker: GitHub" > docs/agents/issue-tracker.md
{ printf '| r | l | s |\n|---|---|---|\n'
  for r in ready-for-agent ready-for-human in-review; do printf '| `%s` | `%s` | x |\n' "$r" "$r"; done
} > docs/agents/triage-labels.md
echo "# context" > CONTEXT.md
git add -A && git commit -qm init
git remote add origin "$T/origin.git"
git push -q origin master
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
# A blocker delivered by hand: branch pushed, PR open, ticket still open.
git checkout -qb feat/99 && echo 99 > from99.txt && git add -A && git commit -qm "feat(#99): by hand"
git push -q origin feat/99 && git checkout -q master && git branch -qD feat/99

# ─── Execution ────────────────────────────────────────────────────────────────
# AFK_HOME redirected: without it, every harness run would append its lines to the real
# repo's RUNS.md.
export HARNESS="$T" PATH="$T/bin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" AFK_HOME="$T"
export VERIFY_CMD='! test -f BROKEN' SETUP_CMD='' CI_TIMEOUT=1m CI_RETRY_WAIT=1
out=$(JOBS=3 bash "$AFK" 1 2 3 4 5 6 7 8 2>&1) || true
printf '%s\n' "$out" > "$T/run.log"

# ─── Assertions ───────────────────────────────────────────────────────────────
fail=0
want() {
  if grep -qE -- "$2" <<<"$out"; then printf '  ✓ %s\n' "$1"
  else printf '  ✗ %s\n     expected: /%s/\n' "$1" "$2"; fail=1; fi
}
dont() {
  if grep -qE -- "$2" <<<"$out"; then printf '  ✗ %s\n     unexpected: /%s/\n' "$1" "$2"; fail=1
  else printf '  ✓ %s\n' "$1"; fi
}

want "independents start together"                 '▸ #1 started.*origin/master'
want "PR stacked on its blocker"                   '▸ #3 started.*base feat/1'
want "topological base: feat/3 contains feat/1"    '▸ #4 started  \(base feat/3\)'
dont "an ancestor is not announced absorbed"       '#4 started.*absorbs'
want "PR targeted at the branch name"              'PR #91 on master$'
want "safety net -> draft"                         '#92 as DRAFT'
want "crashed session -> draft"                    '#96 as DRAFT'
want "open external blocker -> frozen"             '#5 frozen — blockers open outside the run: 99$'
want "failed blocker in run -> cascading freeze"   '#8 frozen — a blocker in this run was not delivered'
want "verification red -> gives up after 2"        '#7 frozen|gave up after 2 attempts'
want "CI phase over every PR"                      '═══ CI \(5 PR'
want "integration green"                           'integration: green'
want "drafts are not counted green"                'green  \(3\): 1 3 4'
want "the draft says WHY it is a draft"            'draft  \(2\): #2 \(not committed\) #6 \(abnormal\)'
want "1 red"                                       'red    \(1\): 7'
want "2 frozen"                                    'frozen \(2\): 5 8'
want "drafts excluded from the 1st attempt"        'green on 1st attempt: 3/6'
want "the base is gated, once"                     'Base \(origin/master\)'
want "base green: a ticket's red is its own"       '✓ green'
want "crashed session named, not a code"           'session ended abnormally \(error_during_execution\)'

grep -qE -- '--output-format json' "$T/args-1.txt" && grep -qE -- '--fallback-model sonnet' "$T/args-1.txt" &&
  echo "  ✓ session launched in JSON, with fallback" || { echo "  ✗ session flags missing"; fail=1; }

grep -qE '^\| #7 \| ko \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ summary written" || { echo "  ✗ summary missing or wrong"; fail=1; }
grep -qE '\| 0m[0-9]{2}s \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ durations recorded" || { echo "  ✗ durations missing"; fail=1; }
# A per-ticket duration does not say where it goes: install / session / gate, and the
# wait on a lock by subtraction (defect 43).
grep -qE '\| 0m[0-9]{2}s / 0m[0-9]{2}s / 0m[0-9]{2}s \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ the phases are broken out" ||
  { echo "  ✗ Phases column missing or empty"; grep -m1 '^| #1 ' "$T/repo/.afk/summary.md"; fail=1; }
# The log spans runs and projects: it is the only history that survives .afk/summary.md
# being overwritten. The project column is a digest, never the project's name.
grep -qE '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} \| project-[0-9a-f]{8} \| 8 \| 3 \| 0 \| 2 \| 1 \| 0 \| 2 \| 0 \| 3/6 \| sonnet-5 \| \$3\.50 \|' "$T/RUNS.md" &&
  echo "  ✓ the run is recorded in RUNS.md, project anonymised" ||
  { echo "  ✗ run missing from the log, or project not anonymised"; sed -n '$p' "$T/RUNS.md" 2>/dev/null; fail=1; }

[[ -d "$T/repo/.afk/wt/7" && ! -d "$T/repo/.afk/wt/1" ]] &&
  echo "  ✓ worktree kept on failure, dropped on success" ||
  { echo "  ✗ worktrees mishandled"; fail=1; }

# #4 starts from feat/3, which contains feat/1: it must inherit the ADRs of BOTH
# ancestors, and #1, which has no blocker, must not see the section at all.
grep -qE '^  - docs/adr/0001-x\.md$' "$T/prompt-4.txt" 2>/dev/null &&
  grep -qE '^  - docs/adr/0003-x\.md$' "$T/prompt-4.txt" &&
  echo "  ✓ the ancestors' decisions are in the prompt" ||
  { echo "  ✗ prompt without the inherited decisions"; fail=1; }
[[ -f "$T/prompt-1.txt" ]] && ! grep -q 'INHERITED' "$T/prompt-1.txt" &&
  echo "  ✓ no blocker, nothing inherited" ||
  { echo "  ✗ inherited section on a ticket without a blocker"; fail=1; }

# ─── Second run: absorbed, frozen by the session, Timeout:, in-review, "no commit" ───
# In series: the reaping order is then the only one possible, so assertable.

out2=$(JOBS=1 bash "$AFK" 9 10 11 12 13 25 2>&1) || true
printf '%s\n' "$out2" > "$T/run2.log"
want2() {
  if grep -qE -- "$2" <<<"$out2"; then printf '  ✓ %s\n' "$1"
  else printf '  ✗ %s\n     expected: /%s/\n' "$1" "$2"; fail=1; fi
}
echo
want2 "in-review dropped from the list"           '#11 is in-review — skipped'
want2 "ticket emptied by its predecessor"         '≡ absorbed'
want2 "absorbed counted separately"               'absorbed \(1\): 9'
want2 "absorbed does not freeze its dependant"    'PR #910 on master'
want2 "ticket Timeout: honoured"                  'budget      : 90m   \(ticket Timeout:\)'
want2 "ticket Model: honoured"                    'model       : sonnet'
want2 "ticket Effort: honoured"                   'effort      : high'
want2 "no commit + red base stays a failure"      'red    \(1\): 13'
want2 "absorbed out of the 1st-attempt green"     'green on 1st attempt: 2/3'
want2 "session saying it is blocked: frozen"      '⏸  frozen — the session says'
want2 "frozen by the session, counted with the frozen" 'frozen \(1\): 25'
grep -qE 'edit issue edit 25 ' "$T/gh.log" &&
  { echo "  ✗ a ticket frozen by its session must not change label"; fail=1; } ||
  echo "  ✓ frozen by its session: label unchanged"
grep -qE 'pr create .*--head feat/25( |$)' "$T/gh.log" &&
  { echo "  ✗ a frozen ticket must not open a PR"; fail=1; } ||
  echo "  ✓ no PR for a frozen ticket"

grep -qE 'edit issue edit 9 .*--add-label in-review' "$T/gh.log" &&
  echo "  ✓ absorbed labelled in-review" || { echo "  ✗ absorbed mislabelled"; fail=1; }
grep -qE 'edit issue edit 13 .*--add-label ready-for-human' "$T/gh.log" &&
  echo "  ✓ real failure handed back to a human" || { echo "  ✗ failure mislabelled"; fail=1; }
grep -qE 'pr create .*--head feat/9( |$)' "$T/gh.log" &&
  { echo "  ✗ an absorbed ticket must not open a PR"; fail=1; } ||
  echo "  ✓ no PR for an absorbed ticket"
[[ "$(grep -c '^| 20' "$T/RUNS.md")" == 2 ]] &&
  echo "  ✓ a second run appends to the log, it does not overwrite it" ||
  { echo "  ✗ log overwritten or not appended"; fail=1; }
grep -qE '^\| #9 \| absorbed \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ summary: absorbed" || { echo "  ✗ summary without absorbed"; fail=1; }
grep -qE '^\| #12 \|.*\| sonnet-5 \(\+2 subagents\) \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ summary: subagents counted with the model" ||
  { echo "  ✗ subagents missing from the Model column"; fail=1; }
grep -qE -- '--model sonnet' "$T/args-12.txt" && grep -qE -- '--effort high' "$T/args-12.txt" &&
  echo "  ✓ Model:/Effort: passed to claude" || { echo "  ✗ overrides not passed on"; fail=1; }
# Two attempts at 0.5: the cost is the TICKET's, not its last session's.
grep -qE '^\| #13 \|.*\| sonnet-5 \|.*\| \$1\.0000 \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ summary: real model and cumulated cost" || { echo "  ✗ model or cost missing from the summary"; fail=1; }
grep -qF 'claude --resume sess-13' "$T/repo/.afk/summary.md" &&
  echo "  ✓ a red ticket can be resumed by hand" || { echo "  ✗ no resume offered on a red"; fail=1; }
grep -qF 'claude --resume sess-12' "$T/repo/.afk/summary.md" &&
  { echo "  ✗ resume offered on a green (worktree dropped)"; fail=1; } ||
  echo "  ✓ no resume offered on a green"

# ─── Third run: interruption ──────────────────────────────────────────────────
# drop_worktree only ran inside reap: a killed orchestrator left behind both the
# worktree AND the claude session, orphaned and alive.

echo
( JOBS=1 bash "$AFK" 20 > "$T/run3.log" 2>&1 ) & afkpid=$!
for _ in $(seq 60); do pgrep -f 'sleep 987654' >/dev/null && break; sleep 0.5; done
if pgrep -f 'sleep 987654' >/dev/null; then
  kill -TERM "$afkpid" 2>/dev/null
  wait "$afkpid" 2>/dev/null
  for _ in $(seq 20); do pgrep -f 'sleep 987654' >/dev/null || break; sleep 0.5; done
  pgrep -f 'sleep 987654' >/dev/null &&
    { echo "  ✗ orphaned session survived"; pkill -f 'sleep 987654'; fail=1; } ||
    echo "  ✓ interruption: no orphaned session"
  grep -qE 'interrupted — 1 running session' "$T/run3.log" &&
    echo "  ✓ interruption announced" || { echo "  ✗ silent interruption"; fail=1; }
else
  echo "  ✗ the test session never started"; kill "$afkpid" 2>/dev/null; fail=1
fi

# ─── Fourth run: stacking on a blocker delivered outside the run ──────────────
# #99 is open and not in the run, but its branch is pushed and its PR open: freezing
# until it merges means refusing to stack on delivered work.

echo
out4=$(OPEN_PR=1 JOBS=1 bash "$AFK" 5 2>&1) || true
printf '%s\n' "$out4" > "$T/run4.log"
want4() {
  if grep -qE -- "$2" <<<"$out4"; then printf '  ✓ %s\n' "$1"
  else printf '  ✗ %s\n     expected: /%s/\n' "$1" "$2"; fail=1; fi
}
want4 "out-of-run blocker with an open PR: no freeze" '#5: blocker #99 delivered outside the run \(open PR\) → base origin/feat/99'
want4 "the dependant starts from its branch"          'PR #95 on feat/99'
grep -qE 'pr create .*--base feat/99' "$T/gh.log" &&
  echo "  ✓ PR targeted at the blocker's branch" ||
  { echo "  ✗ PR mistargeted"; fail=1; }
# The same batch in `-n`. The plan announced "frozen — undeliverable blocker" for what
# the run had just launched, and contradicted itself in its own output (defect 44). It is
# when resuming an interrupted run that it gets read, so exactly where it must tell the
# truth.
out4n=$(OPEN_PR=1 bash "$AFK" -n 5 2>&1) || true
printf '%s\n' "$out4n" > "$T/run4n.log"
grep -qE '#5 +base origin/feat/99' <<<"$out4n" &&
  echo "  ✓ plan: the dependant starts from the blocker's branch" ||
  { echo "  ✗ plan: wrong base"; printf '%s\n' "$out4n"; fail=1; }
grep -q 'frozen' <<<"$out4n" &&
  { echo "  ✗ plan: #5 frozen although the run launches it"; fail=1; } ||
  echo "  ✓ plan: no freeze, like the real run"

# ─── Fifth run: two independent direct blockers ──────────────────────────────
# The diamond of the first run always has a dominating branch, so `deepest_branch`
# finds a base that already contains the other and nothing gets merged on top. Here
# neither contains the other: it falls back to the last one, the other is absorbed by
# the worktree, and the dependant must inherit BOTH memories — not only its base's.
printf '## Blocked by\n\nNone\n'         > "$T/fix/14.body"
printf '## Blocked by\n\nNone\n'         > "$T/fix/15.body"
printf '## Blocked by\n\n- #14\n- #15\n' > "$T/fix/16.body"

echo
out5=$(JOBS=2 bash "$AFK" 14 15 16 2>&1) || true
printf '%s\n' "$out5" > "$T/run5.log"

grep -qE '▸ #16 started  \(base feat/15, absorbs feat/14\)' "$T/run5.log" &&
  echo "  ✓ independent siblings: one serves as base, the other is absorbed" ||
  { echo "  ✗ absorption of an independent sibling missed"; fail=1; }
grep -qE '^  - docs/adr/00014-x\.md$' "$T/prompt-16.txt" 2>/dev/null &&
  grep -qE '^  - docs/adr/00015-x\.md$' "$T/prompt-16.txt" &&
  echo "  ✓ both memories inherited, not only the base's" ||
  { echo "  ✗ only one blocker's memory inherited"; fail=1; }
grep -qE 'green  \(3\): 14 15 16' "$T/run5.log" &&
  echo "  ✓ all three green" || { echo "  ✗ the dependant did not start"; fail=1; }
# A stacked branch merged BEFORE its base conflicts by construction: integration merges
# in topological order, not in completion order.
[[ "$(grep -o 'merge feat/[0-9]*' "$T/run5.log" | tail -1)" == "merge feat/16" ]] &&
  echo "  ✓ the stacked one is merged after its base" ||
  { echo "  ✗ non-topological merge order"; fail=1; }

# ─── Sixth run: push refused, same path twice, stale reference, conflict ─────
# The remote refuses feat/17 the way GitHub refuses a branch touching .github/workflows/
# with a token lacking the `workflow` scope: the work is good, the transport breaks.
cat > "$T/origin.git/hooks/update" <<'X'
#!/bin/sh
[ "$1" = refs/heads/feat/17 ] &&
  { echo "refusing to allow an OAuth App to create or update workflow" >&2; exit 1; }
exit 0
X
chmod +x "$T/origin.git/hooks/update"

echo
out6=$(NO_CHECKS_ONCE=1 JOBS=1 bash "$AFK" 17 18 19 26 2>&1) || true
printf '%s\n' "$out6" > "$T/run6.log"
want6() {
  if grep -qE -- "$2" <<<"$out6"; then printf '  ✓ %s\n' "$1"
  else printf '  ✗ %s\n     expected: /%s/\n' "$1" "$2"; fail=1; fi
}
want6 "push refused: its own line"             'push refused \(1\): 17'
want6 "push refused: the remote's reason"      '#17: .*refusing to allow an OAuth App'
want6 "push refused is not a red"              'red    \(0\): —'
want6 "same path created by two branches"      'same path created by several branches'
want6 "the offending path is named"            'shared\.ts :.*feat/18.*feat/19|shared\.ts :.*feat/19.*feat/18'
want6 "ticket from the run cited in merged docs" 'docs/stale\.md:1:.*#19'
want6 "CI not registered yet: retried"         '✓ #18 \(PR #918\) CI green'
want6 "stacking conflict: the paths on screen" '#26: conflict between blockers.*shared\.ts'
grep -qE '^\| #26 \| conflict \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ summary: conflict, not frozen" ||
  { echo "  ✗ a stacking conflict is still filed as \"frozen\""; grep -m1 '^| #26 ' "$T/repo/.afk/summary.md"; fail=1; }
grep -qE -- '- #26: conflict stacking its blockers — shared\.ts' "$T/repo/.afk/summary.md" &&
  echo "  ✓ summary: the conflicting path, and the log that carries it" ||
  { echo "  ✗ summary: conflict without its paths"; fail=1; }
grep -qE '^\| #17 \| push refused \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ summary: push refused" || { echo "  ✗ summary without the refused push"; fail=1; }
grep -qE -- '- `feat/19`: shared\.ts' "$T/repo/.afk/summary.md" &&
  echo "  ✓ summary: the conflicting files, not just the branch" ||
  { echo "  ✗ conflicting files missing from the summary"; fail=1; }
grep -qE 'edit issue edit 17 .*ready-for-human' "$T/gh.log" &&
  { echo "  ✗ a refused push must not hand the ticket back to a human"; fail=1; } ||
  echo "  ✓ push refused: no label changed"
[[ "$(head -n 1 "$T/repo/.afk/18.status")" == "result_initial=ko" ]] &&
  echo "  ✓ .status: the first line no longer says \"ko\" on a green" ||
  { echo "  ✗ .status: result=ko at the top"; head -n 1 "$T/repo/.afk/18.status"; fail=1; }

# ─── Seventh run: repo without CI ────────────────────────────────────────────
# "No CI declared" is a property of the REPO: saying it ticket by ticket would mark the
# whole batch "unproven", and the real unproven would drown in it.
echo
out7=$(NO_CHECKS=1 JOBS=1 bash "$AFK" 21 2>&1) || true
printf '%s\n' "$out7" > "$T/run7.log"
grep -qE 'no CI on this repo.*REPLACED on 21' <<<"$out7" &&
  echo "  ✓ repo without CI: one line for the run, not one per ticket" ||
  { echo "  ✗ the absence of CI is reported ticket by ticket"; fail=1; }
# And the written summary goes down into summary.md: it is the only document the debrief
# opens, it must not point at a CI that does not exist (defect 36).
grep -q 'no CI on this repo' "$T/repo/.afk/summary.md" &&
  ! grep -q 'only their CI ran' "$T/repo/.afk/summary.md" &&
  echo "  ✓ summary: no pointer to a CI that does not exist" ||
  { echo "  ✗ summary.md still points at CI on a repo that has none"; fail=1; }
grep -qE 'green  \(1\): 21' <<<"$out7" &&
  echo "  ✓ and the ticket stays green" || { echo "  ✗ unproven green for nothing"; fail=1; }

# ─── Eighth run: reduced gate + CI that does not conclude ───────────────────
# Here it is a verdict that is MISSING: this ticket's only complete gate is the one that
# returned nothing. And its `Verify:` line is written in markdown, as in a real ticket.
echo
out8=$(HANG_CI=1 CI_TIMEOUT=2 JOBS=1 bash "$AFK" 22 2>&1) || true
printf '%s\n' "$out8" > "$T/run8.log"
grep -qE 'gate        : true   \(ticket Verify:\)' <<<"$out8" &&
  echo "  ✓ the gate is extracted from the span, not from the whole line" ||
  { echo "  ✗ the ticket's prose went to bash -c"; fail=1; }
grep -qE 'unproven green \(1\): 22' <<<"$out8" &&
  echo "  ✓ reduced gate + inconclusive CI = unproven green" ||
  { echo "  ✗ the unproven green is still counted green"; fail=1; }
grep -qE 'green  \(0\): —' <<<"$out8" &&
  echo "  ✓ and it leaves the \"green\" column" || { echo "  ✗ counted twice"; fail=1; }

# ─── Ninth run: the base is already red ──────────────────────────────────────
# Without this pass, the ticket carries the base's failure: `reason=verify`, an
# `<n>-fail.txt` naming a test outside its scope, and a human round trip.
echo
out9=$(VERIFY_CMD='test -f NOPE' NO_CHECKS=1 JOBS=1 bash "$AFK" 23 2>&1) || true
printf '%s\n' "$out9" > "$T/run9.log"
grep -qE 'RED BEFORE THE RUN' <<<"$out9" &&
  echo "  ✓ red base: said before the first worktree" ||
  { echo "  ✗ red base not detected"; fail=1; }
grep -qE 'base red BEFORE the run' <<<"$out9" &&
  echo "  ✓ and repeated in the summary, where the reds are read" ||
  { echo "  ✗ the summary blames the ticket for the base"; fail=1; }
grep -q 'was already red before the run' "$T/repo/.afk/summary.md" &&
  echo "  ✓ and in summary.md" || { echo "  ✗ missing from summary.md"; fail=1; }
[[ -s "$T/repo/.afk/base-verify.txt" ]] || [[ -f "$T/repo/.afk/base-verify.txt" ]] &&
  echo "  ✓ the gate's output on the base is kept" ||
  { echo "  ✗ base-verify.txt missing"; fail=1; }

echo
(( fail )) && { echo "FAILED — trace: $T/run.log"; trap - EXIT; exit 1; }
echo "ok"
