#!/usr/bin/env bash
# afk-app.sh — build a whole app, wave after wave, without waking up.
#
#   ./afk-app.sh              # up to 8 waves, 1 ticket at a time
#   ./afk-app.sh -w 4 -j 3    # 4 waves at most, 3 tickets in parallel
#
# Prerequisite: `/afk-spec` has run (docs/spec.md, afk-spec tag, dev branch, .afk.env).
#
# A wave is three things, in this order:
#   /afk-wave   Claude session — opens the tickets for the unchecked criteria
#   afk.sh      the orchestrator, with no LLM inside, as usual
#   /afk-merge  Claude session — lands on dev and checks off what passes
#
# THE CONTROL FLOW IS MECHANICAL. This script never reads what a session says to decide
# whether to continue: it counts the checked boxes in docs/spec.md and the open tickets
# on GitHub. A session that declares itself victorious therefore cannot extend the loop,
# nor stop it.
#
# set -e is absent for the same reason as in afk.sh: a failed wave is a result, not a
# reason to stop.
set -uo pipefail

WAVES=8; JOBS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--waves) WAVES="$2"; shift 2 ;;
    -j|--jobs)  JOBS="$2";  shift 2 ;;
    -h|--help)  sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

AFK_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LOG_DIR=".afk/app"

# `jval` comes from afk.sh: sourced with AFK_LIB=1, it only yields the pure parsers.
# No second copy of a JSON reader in this repo.
AFK_LIB=1 source "$AFK_HOME/afk.sh"

# The spec is the loop's only judge. It is written once by /afk-spec and tagged; from
# then on, only the boxes are allowed to move. Without this guard, whoever writes the
# criteria and whoever fills them are the same model.
spec_ok() {
  git rev-parse -q --verify afk-spec >/dev/null || { echo "✗ no afk-spec tag — run /afk-spec"; return 1; }
  # The boxes are neutralised ON BOTH SIDES: the tagged version already contains a
  # checked one (the skeleton makes A0 pass), and a guard neutralising only one side
  # refuses to run from the very first wave.
  diff <(git show afk-spec:docs/spec.md | sed 's/\[x\]/[ ]/g') \
       <(sed 's/\[x\]/[ ]/g' docs/spec.md) >/dev/null && return 0
  echo "✗ docs/spec.md has drifted (something other than boxes) — the loop has no judge left"
  git --no-pager diff afk-spec -- docs/spec.md | head -20
  return 1
}

# `grep -c` prints 0 AND exits 1 when it finds nothing: an `|| echo 0` behind it would
# yield "0\n0", and the loop's arithmetic with it.
done_n()  { local n; n=$(grep -c '^- \[x\]' docs/spec.md 2>/dev/null); echo "${n:-0}"; }
todo_n()  { local n; n=$(grep -c '^- \[ \]' docs/spec.md 2>/dev/null); echo "${n:-0}"; }
ready_n() { gh issue list --state open --label ready-for-agent --limit 200 --json number -q '. | length' 2>/dev/null || echo 0; }

# A steering session. Short by nature — it reads, it opens tickets or it merges. The
# timeout is not there to rein it in but so that a mute session does not eat the night
# of the waves that follow.
pilot() {
  local skill="$1" out="$2" rc sub
  timeout 45m claude -p "/$skill" \
    --permission-mode bypassPermissions --output-format json > "$out" 2>&1
  rc=$?
  sub=$(jval subtype < "$out")
  (( rc == 124 )) && { echo "  ✗ /$skill cut at the timeout"; return 1; }
  [[ "$sub" == "success" ]] || { echo "  ✗ /$skill: ${sub:-unreadable output} — $out"; return 1; }
  echo "  · /$skill ok ($(jval total_cost_usd < "$out") USD)"
}

# ─── Guard rails ──────────────────────────────────────────────────────────────
[[ -f docs/spec.md ]] || { echo "✗ no docs/spec.md — run /afk-spec"; exit 1; }
[[ -f .afk.env     ]] || { echo "✗ no .afk.env — run /afk-setup"; exit 1; }
command -v gh >/dev/null || { echo "✗ gh missing"; exit 1; }
git fetch -q origin && git switch -q dev && git pull -q ||
  { echo "✗ dev unreachable — /afk-spec creates it"; exit 1; }
spec_ok || exit 1
mkdir -p "$LOG_DIR"

echo "app: $(todo_n) criterion/criteria left out of $(( $(done_n) + $(todo_n) ))   waves: ${WAVES}   parallel: ${JOBS}"

# ─── The loop ─────────────────────────────────────────────────────────────────
stall=0; stop=""
for (( w=1; w<=WAVES; w++ )); do
  before=$(done_n)
  echo; echo "═══ wave ${w}/${WAVES} — $(date '+%H:%M') — ${before} criterion/criteria checked"

  pilot afk-wave "$LOG_DIR/w${w}-plan.json" || { stop="the slicing session failed"; break; }

  n=$(ready_n)
  if (( n == 0 )); then stop="nothing left to open"; break; fi
  echo "  · ${n} ready-for-agent ticket(s)"

  "$AFK_HOME/afk.sh" -j "$JOBS"
  cp .afk/summary.md "$LOG_DIR/w${w}-summary.md" 2>/dev/null   # overwritten by the next wave

  pilot afk-merge "$LOG_DIR/w${w}-merge.json" || { stop="the landing session failed"; break; }

  git pull -q
  spec_ok || { stop="the spec drifted during the wave"; break; }

  after=$(done_n)
  echo "  → ${after} criterion/criteria checked (+$(( after - before )))"

  if (( $(todo_n) == 0 )); then stop="every criterion is checked"; break; fi

  # Two waves in a row without a single criterion landing: the loop is not moving any
  # more. One red wave in three is the normal regime, two sterile waves are not.
  if (( after == before )); then
    stall=$(( stall + 1 ))
    (( stall >= 2 )) && { stop="two waves without a criterion being checked"; break; }
    echo "  ⚠  sterile wave (${stall}/2)"
  else
    stall=0
  fi
done
[[ -z "$stop" ]] && stop="budget of ${WAVES} waves exhausted"

echo; echo "═══ stop: ${stop}"
echo "criteria: $(done_n)/$(( $(done_n) + $(todo_n) ))"
grep '^- \[ \]' docs/spec.md | head -5
gh issue list --state open --label ready-for-human --json number,title \
  -q '.[] | "  handed back to a human: #\(.number) \(.title)"' 2>/dev/null
echo "traces: ${LOG_DIR}/"
