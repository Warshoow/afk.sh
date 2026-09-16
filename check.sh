#!/usr/bin/env bash
# The parsers decide which ticket runs, under which label, against which gate and on
# which base. If they drift, the orchestrator launches tickets whose blockers are not
# lifted, or stacks a PR on the wrong branch. So: test them.
set -euo pipefail
cd "$(dirname "$0")"

bash -n afk.sh
AFK_LIB=1 source ./afk.sh

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/docs/agents"
cat > "$t/docs/agents/triage-labels.md" <<'EOF'
| Label in mattpocock/skills | Label in our tracker | Meaning |
| -------------------------- | -------------------- | ------- |
| `needs-triage`             | `triage`             | ...     |
| `ready-for-agent`          | `agent:go`           | ...     |
| `ready-for-human`          | `needs-human`        | ...     |
| `in-review`                | `under-review`       | ...     |
EOF

pushd "$t" >/dev/null
[[ "$(label_for ready-for-agent)" == "agent:go"     ]] || { echo "FAIL label_for agent"; exit 1; }
[[ "$(label_for ready-for-human)" == "needs-human"  ]] || { echo "FAIL label_for human"; exit 1; }
[[ "$(label_for in-review)"       == "under-review" ]] || { echo "FAIL label_for in-review"; exit 1; }
popd >/dev/null
[[ -z "$(label_for ready-for-agent)" ]] || { echo "FAIL label_for without config"; exit 1; }

# ─── blocked_refs ─────────────────────────────────────────────────────────────

got=$(blocked_refs <<'EOF' | tr '\n' ' '
## What to build

Nothing to see here, we mention #99 in passing.

## Blocked by

- #12
- #7

## Acceptance criteria

- [ ] not #42
EOF
)
[[ "$got" == "12 7 " ]] || { echo "FAIL Blocked by section: '$got'"; exit 1; }

got=$(blocked_refs <<<'Blocked by: #3, #4' | tr '\n' ' ')
[[ "$got" == "3 4 " ]] || { echo "FAIL inline Blocked by: '$got'"; exit 1; }

got=$(blocked_refs <<<'## Blocked by

None — can start immediately' | tr '\n' ' ')
[[ -z "$got" ]] || { echo "FAIL 'None': '$got'"; exit 1; }

# ─── meta_line: Verify ────────────────────────────────────────────────────────
# A monorepo gate on an app ticket is a contradiction: the ticket must be able to
# restrict its own verification.

got=$(meta_line Verify <<'EOF'
## What to build

Verify: pnpm turbo typecheck --filter=@acme/backend

## Acceptance criteria
EOF
)
[[ "$got" == "pnpm turbo typecheck --filter=@acme/backend" ]] || { echo "FAIL Verify: plain: '$got'"; exit 1; }

got=$(meta_line Verify <<<'- `Verify`: pnpm lint')
[[ "$got" == "pnpm lint" ]] || { echo "FAIL Verify: bullet + backticks: '$got'"; exit 1; }

got=$(meta_line Verify <<<'verify:   npm test   ')
[[ "$got" == "npm test" ]] || { echo "FAIL Verify: case and spaces: '$got'"; exit 1; }

got=$(meta_line Verify <<<'Nothing to declare here.')
[[ -z "$got" ]] || { echo "FAIL Verify: absent: '$got'"; exit 1; }

got=$(meta_line Verify <<<'Verify:')
[[ -z "$got" ]] || { echo "FAIL Verify: empty: '$got'"; exit 1; }

# The shape of a well written ticket: the command in `code`, then in prose what it does
# not cover. The whole line went to `bash -c`, where the `**` globbed over the cwd and
# bash tried to execute the file it found — fifteen red tickets in a few seconds.
got=$(meta_line Verify "$RE_VERIFY" <<<'**Verify:** `ruff check app/ && python -m pytest tests/ -q`, plus one fresh test per point:')
[[ "$got" == "ruff check app/ && python -m pytest tests/ -q" ]] ||
  { echo "FAIL Verify: bold + span + prose: '$got'"; exit 1; }

got=$(meta_line Verify "$RE_VERIFY" <<<'**Verify:** ruff check')
[[ "$got" == "ruff check" ]] || { echo "FAIL Verify: closing bold after the colon: '$got'"; exit 1; }

# The gate that starts in prose and quotes its commands mid-sentence. It does not start
# with a span: there is nothing to keep, and it is its leftover backtick that makes it
# refused. Three tickets out of a batch of fifteen had this shape and would have gone
# whole to `bash -c`.
got=$(meta_line Verify "$RE_VERIFY" <<<'**Verify:** by hand, `python -m app hub` + `npm run dev`: the page renders /api/info. Plus `pytest -q` green.')
[[ -z "$got" ]] || { echo "FAIL Verify: prose quoting commands: '$got'"; exit 1; }

# A command does not end in ":" — that is the shape of an introducing sentence.
got=$(meta_line Verify "$RE_VERIFY" <<<'Verify: run the tests, then:')
[[ -z "$got" ]] || { echo "FAIL Verify: prose accepted: '$got'"; exit 1; }

# The bare form stays the README's: no backtick, no bold, nothing to clean.
got=$(meta_line Verify "$RE_VERIFY" <<<'Verify: pnpm test')
[[ "$got" == "pnpm test" ]] || { echo "FAIL Verify: bare form: '$got'"; exit 1; }

# ─── meta_line: Timeout ───────────────────────────────────────────────────────
# TIMEOUT is global, a ticket's size is not. A malformed value must be ignored rather
# than passed on: timeout(1) would refuse to start the session, and a badly written
# ticket would cost a whole run.

got=$(meta_line Timeout "$RE_TIMEOUT" <<'EOF'
## What to build

Timeout: 90m

## Acceptance criteria
EOF
)
[[ "$got" == "90m" ]] || { echo "FAIL Timeout: plain: '$got'"; exit 1; }

got=$(meta_line Timeout "$RE_TIMEOUT" <<<'- `Timeout`: 2h')
[[ "$got" == "2h" ]] || { echo "FAIL Timeout: bullet + backticks: '$got'"; exit 1; }

got=$(meta_line Timeout "$RE_TIMEOUT" <<<'timeout:   3600   ')
[[ "$got" == "3600" ]] || { echo "FAIL Timeout: case and spaces: '$got'"; exit 1; }

got=$(meta_line Timeout "$RE_TIMEOUT" <<<'Nothing to declare here.')
[[ -z "$got" ]] || { echo "FAIL Timeout: absent: '$got'"; exit 1; }

got=$(meta_line Timeout "$RE_TIMEOUT" <<<'Timeout: when it is done')
[[ -z "$got" ]] || { echo "FAIL Timeout: malformed must be ignored: '$got'"; exit 1; }

got=$(meta_line Timeout "$RE_TIMEOUT" <<<'Timeout: 90m if all goes well')
[[ -z "$got" ]] || { echo "FAIL Timeout: duration buried in a sentence: '$got'"; exit 1; }

# gh renders ticket bodies in CRLF: without stripping, the duration would come out with
# a \r and timeout(1) would refuse to start.
got=$(printf 'Timeout: 90m\r\n' | meta_line Timeout "$RE_TIMEOUT")
[[ "$got" == "90m" ]] || { echo "FAIL Timeout: CRLF: '$got'"; exit 1; }
got=$(printf 'Verify: pnpm lint\r\n' | meta_line Verify)
[[ "$got" == "pnpm lint" ]] || { echo "FAIL Verify: CRLF: '$got'"; exit 1; }

# ─── meta_line: Model and Effort ──────────────────────────────────────────────
# Same rules, narrower patterns: what goes as an argument to claude(1) must never be
# anything other than a model name or one of the known effort levels.

got=$(meta_line Model "$RE_MODEL" <<<'Model: sonnet')
[[ "$got" == "sonnet" ]] || { echo "FAIL Model: alias: '$got'"; exit 1; }

got=$(meta_line Model "$RE_MODEL" <<<'- `Model`: claude-opus-5')
[[ "$got" == "claude-opus-5" ]] || { echo "FAIL Model: full name: '$got'"; exit 1; }

got=$(meta_line Model "$RE_MODEL" <<<'Model: sonnet ; rm -rf /')
[[ -z "$got" ]] || { echo "FAIL Model: value that is not a name: '$got'"; exit 1; }

got=$(meta_line Effort "$RE_EFFORT" <<<'> **Effort**: high')
[[ "$got" == "high" ]] || { echo "FAIL Effort: bold inside a quote: '$got'"; exit 1; }

got=$(meta_line Effort "$RE_EFFORT" <<<'Effort: a lot')
[[ -z "$got" ]] || { echo "FAIL Effort: outside the known set: '$got'"; exit 1; }

# ─── jval / jmodels ───────────────────────────────────────────────────────────
# What the session says about itself, read without jq in a file that also contains its
# error output. The trap: "result" is free text written by the agent, it can contain any
# key — the targeted keys all precede it, the first match is the right one.
j='{"session_id":"42ce-8d","total_cost_usd":0.233,"is_error":false,"subtype":"error_during_execution",'
j+='"modelUsage":{"claude-opus-5[1m]":{"canonicalModel":"claude-opus-5"},"x":{"canonicalModel":"claude-sonnet-5"}},'
j+='"result":"im done, \"is_error\":true"}'

[[ "$(jval session_id     <<<"$j")" == "42ce-8d"                 ]] || { echo "FAIL jval session_id"; exit 1; }
[[ "$(jval total_cost_usd <<<"$j")" == "0.233"                   ]] || { echo "FAIL jval cost"; exit 1; }
[[ "$(jval is_error       <<<"$j")" == "false"                   ]] || { echo "FAIL jval is_error swallowed by result"; exit 1; }
[[ "$(jval subtype        <<<"$j")" == "error_during_execution"  ]] || { echo "FAIL jval subtype"; exit 1; }
[[ -z "$(jval missing     <<<"$j")"                              ]] || { echo "FAIL jval missing key"; exit 1; }
[[ "$(jmodels <<<"$j")" == "opus-5 sonnet-5" ]] || { echo "FAIL jmodels: '$(jmodels <<<"$j")'"; exit 1; }
[[ -z "$(jmodels <<<'session killed before the end')" ]] || { echo "FAIL jmodels on truncated output"; exit 1; }

# Subagents: `spawned_by_subagents` is a decoy, it must not be read in its place.
k='{"subagent_stats":{"spawned":2,"spawned_by_subagents":0,"by_type":{"reviewer":2}},"result":"done"}'
[[ "$(jspawned <<<"$k")" == "2" ]] || { echo "FAIL jspawned: '$(jspawned <<<"$k")'"; exit 1; }
[[ "$(jspawned <<<'{"subagent_stats":{"spawned":0,"spawned_by_subagents":0}}')" == "0" ]] ||
  { echo "FAIL jspawned at zero"; exit 1; }
[[ -z "$(jspawned <<<'session killed before the end')" ]] || { echo "FAIL jspawned on truncated output"; exit 1; }

# ─── deepest_branch ───────────────────────────────────────────────────────────
# The base of a stacked PR must be the topologically deepest blocker. The API's listing
# order is not: taking the last one only worked because our edges happened to have been
# created in order.

r="$t/repo"; mkdir -p "$r"
pushd "$r" >/dev/null
git init -qb main .
git -c user.email=a@b -c user.name=c commit -q --allow-empty -m base
git checkout -qb B; git -c user.email=a@b -c user.name=c commit -q --allow-empty -m b
git checkout -qb C; git -c user.email=a@b -c user.name=c commit -q --allow-empty -m c
git checkout -q main
git checkout -qb D; git -c user.email=a@b -c user.name=c commit -q --allow-empty -m d

[[ "$(deepest_branch B C)" == "C" ]] || { echo "FAIL deepest B C"; exit 1; }
[[ "$(deepest_branch C B)" == "C" ]] || { echo "FAIL deepest C B — order must not matter"; exit 1; }
[[ "$(deepest_branch B)"   == "B" ]] || { echo "FAIL deepest singleton"; exit 1; }
# Independent siblings: none dominates, fall back to the last one listed.
[[ "$(deepest_branch C D)" == "D" ]] || { echo "FAIL deepest siblings"; exit 1; }
# Missing branch (dry run: nothing is created): same fallback, without crashing.
[[ "$(deepest_branch B missing)" == "missing" ]] || { echo "FAIL deepest missing ref"; exit 1; }
# A base is not necessarily a local branch: origin/<x> for a blocker delivered outside
# the run. With refs/heads/ only, it looked absent and triggered the fallback.
git update-ref refs/remotes/origin/main refs/heads/main
[[ "$(deepest_branch B origin/main)" == "B" ]] || { echo "FAIL deepest remote ref"; exit 1; }
popd >/dev/null

# ── peak_context ──────────────────────────────────────────────────────────────
# A request's context = fresh + written to cache + read from cache; we keep the max over
# the session. Two traps make this test worth it: "input_tokens" must not be counted
# inside "cache_read_input_tokens" (the opening quote separates them), and a regex
# passed as an argument to an awk function evaluates as a boolean — the parser returned
# 3 instead of 139988 before we passed it as a string.
ctx_fixture() {
  cat <<'EOF'
{"type":"user","message":{"role":"user","content":"go"}}
{"message":{"role":"assistant","usage":{"input_tokens":4,"cache_creation_input_tokens":20000,"cache_read_input_tokens":0,"output_tokens":120}}}
{"message":{"role":"assistant","usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":98000,"output_tokens":300}}}
{"message":{"role":"assistant","usage":{"input_tokens":1,"cache_creation_input_tokens":500,"cache_read_input_tokens":50000,"output_tokens":80}}}
EOF
}
got=$(ctx_fixture | peak_context)
[[ "$got" == "99002" ]] || { echo "FAIL peak_context: '$got' instead of 99002"; exit 1; }
# The peak is not the last turn: a session can come back down after a compaction.
[[ "$(ctx_fixture | tail -1 | peak_context)" == "50501" ]] || { echo "FAIL peak_context single turn"; exit 1; }
# A transcript with no usage (session dead before the first answer) returns nothing, and
# above all not 0: the summary column must show "—", not "0k".
[[ -z "$(printf '{"type":"user"}\n' | peak_context)" ]] || { echo "FAIL peak_context empty"; exit 1; }
[[ -z "$(printf '' | peak_context)" ]] || { echo "FAIL peak_context empty stdin"; exit 1; }

# ─── clashing_numbers ─────────────────────────────────────────────────────────
# The real case that motivated the parser: on a batch of 8 tickets, three had taken
# `docs/adr/0018-…` and two the migration `…034_…`. No git conflict, it compiled, the
# tests passed.
clash_fixture() {
  cat <<'EOF'
docs/adr/0018-a-range-marker-is-measured-in-metres.md
docs/adr/0018-an-earned-badge-tier-is-never-revoked.md
docs/adr/0018-reviews-leave-the-detail-by-their-own-route.md
docs/adr/0017-map-objects-become-data.md
apps/backend/database/migrations/1768621000034_official_replaces_featured.ts
apps/backend/database/migrations/1768621000034_badge_tiers_land_on_1_5_25_50.ts
apps/backend/database/migrations/1768621000033_create_map_objects_table.ts
apps/backend/resources/map-objects/plot/center.png
apps/mobile/components/ui/PagedFooter.tsx
EOF
}
got=$(clash_fixture | clashing_numbers)
[[ $(wc -l <<<"$got") == 2 ]] || { echo "FAIL clashing_numbers: 2 clashes expected"; printf '%s\n' "$got"; exit 1; }
grep -q '^0018\* in docs/adr/: ' <<<"$got" || { echo "FAIL clashing_numbers ADR"; exit 1; }
grep -q '^1768621000034\* in apps/backend/database/migrations/: ' <<<"$got" || { echo "FAIL clashing_numbers migration"; exit 1; }
# A free number is not flagged, and a file without a numeric prefix does not enter.
grep -q '0017' <<<"$got" && { echo "FAIL clashing_numbers false positive 0017"; exit 1; }
grep -qi 'pagedfooter\|center.png' <<<"$got" && { echo "FAIL clashing_numbers without prefix"; exit 1; }
# The same path listed twice (two branches adding the SAME file) is not a clash: it is a
# merge, and it resolves by itself.
[[ -z "$(printf 'docs/adr/0018-a.md\ndocs/adr/0018-a.md\n' | clashing_numbers)" ]] ||
  { echo "FAIL clashing_numbers strict duplicate"; exit 1; }
# Repo root: no directory, the line must stay readable.
printf '0001-x.md\n0001-y.md\n' | clashing_numbers | grep -q 'in \./' ||
  { echo "FAIL clashing_numbers root"; exit 1; }
[[ -z "$(printf '' | clashing_numbers)" ]] || { echo "FAIL clashing_numbers empty stdin"; exit 1; }

echo "ok"
