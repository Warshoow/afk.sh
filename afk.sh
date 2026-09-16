#!/usr/bin/env bash
# afk.sh — chains /implement over the ready-for-agent tickets.
#
# One ticket = one fresh Claude session = one worktree = one branch = one PR.
# The orchestrator holds no LLM: it orders, it launches, it verifies, it pushes,
# it labels. Zero human interaction by default.
#
# Assumes a repo configured by /setup-matt-pocock-skills (GitHub tracker) and
# tickets produced by /to-tickets — so carrying their "Blocked by".
#
# Usage:
#   ./afk.sh                       # every ready-for-agent ticket, in series
#   ./afk.sh 43 48 49 50           # these ones
#   ./afk.sh -j 3 43 48 49 50      # in parallel wherever the DAG allows it
#   ./afk.sh -n 43 48 49 50        # the plan: waves, bases, stacks, frozen
#
# In parallel: the Claude sessions run at the same time, verification runs one at
# a time (Postgres, ports and RAM are shared — see VERIFY_LOCK).

set -uo pipefail

# ─── Parsers ──────────────────────────────────────────────────────────────────
# Pure, up top: they are the ones deciding the schedule. Tested by check.sh.

# The repo's real triage vocabulary, from the plugin config.
label_for() {
  awk -F'|' -v role="$1" '$0 ~ "`"role"`" && NF>3 { gsub(/[ `]/,"",$3); print $3; exit }' \
    docs/agents/triage-labels.md 2>/dev/null
}

# Numbers cited in the "Blocked by" section of a ticket body, on stdin.
blocked_refs() {
  awk '/^#+ *Blocked by/{f=1;next} /^#+ /{f=0} f||/[Bb]locked by:/' |
    grep -o '#[0-9]\+' | tr -d '#' || true   # "no blocker" is not an error
}

# A ticket-level override: the first "<Field>: <value>" line of its body, on stdin.
# One parser for all four fields — they only differ by name and by what counts as a
# valid value.
#
# They all exist for the same reason: the global setting was cut for the average
# ticket, and whoever writes the ticket is the only one who knows, before it runs,
# that this one is not average.
#   Verify:  the gate. Without it, VERIFY_CMD. It is the only way for an app ticket
#            not to be guarded by a whole-monorepo typecheck, and for a cross-cutting
#            ticket to demand more than a compile.
#   Timeout: the time budget, in timeout(1) format. A rework (migration + formula +
#            guards + tests + docs) does not fit the average ticket's shape and gets
#            cut in the middle.
#   Model:   the model. A typo fix does not need the model of a rework.
#   Effort:  the thinking level, among those claude(1) accepts.
#
# A value that does not match its pattern is IGNORED rather than passed as-is to
# claude(1) or timeout(1), which would then refuse to start the session — a badly
# written ticket must not cost a run.
#
# The patterns live here, not at the call sites: check.sh sources this file and so
# tests the ones afk.sh actually uses. A pattern copied into the test would only
# verify itself.
RE_TIMEOUT='[0-9]+(\.[0-9]+)?[smhd]?'          # timeout(1)'s format
RE_MODEL='[A-Za-z0-9][A-Za-z0-9._-]*'          # not a list of known names: it would be
                                               # stale at the next model. It only rejects
                                               # what is not a name (spaces, metacharacters).
RE_EFFORT='(low|medium|high|xhigh|max)'        # the closed set claude(1) accepts
RE_VERIFY='[^`]*[^`:[:space:]]'                # a command does not end in ":" — that is
                                               # the shape of an introducing sentence, and
                                               # that is the one that ended up at `bash -c`.
                                               # And it keeps no backtick after cleanup:
                                               # what keeps one is prose that QUOTES
                                               # commands. Price paid: an old-style `cmd`
                                               # substitution is refused too. It has been
                                               # written $(cmd) for thirty years.

# Cleaning the value, before validation:
#   1. the bold that follows the ":" — `**Verify:** cmd` leaves its two asterisks AFTER
#      the colon, out of reach of the first sed;
#   2. if the value STARTS with a backtick span, keep only that span. A well written
#      ticket writes the command in `code` then, in prose, what it does not cover: the
#      prose is a note for the agent, not a gate. Without this the whole line went to
#      `bash -c`, where the `**` globbed over the cwd.
#   3. backticks are dropped ONLY when the value is the whole span. A gate that starts
#      in prose and quotes its commands mid-sentence ("by hand, `python -m app hub` +
#      `npm run dev`: …") escapes point 2 — there is nothing to keep, it does not start
#      with a span. Its leftover backtick is what makes `RE_VERIFY` reject it, and
#      erasing it blindly erased the only trace telling it apart from a command.
# The bare form (`Verify: pnpm test`) stays accepted as-is: it is the README's.
meta_line() {   # $1 = field name, $2 = validation pattern (default: anything)
  sed -n -E "s/^[[:space:]>*+-]*[\`*]*$1[\`*]*[[:space:]]*:[[:space:]]*//Ip" |
    sed -E 's/^[*_[:space:]]+//; s/^(`[^`]+`).*$/\1/; s/^`([^`]*)`$/\1/; s/[[:space:]]+$//' |
    awk 'NF{print; exit}' |
    grep -Ex -- "${2:-.+}" || true   # missing or malformed: not an error
}

# Base of a stacked PR: among the branches of the blockers already delivered, the one
# that already contains all the others. The API's listing order is not topological —
# taking the last one only worked by luck. If none dominates (independent siblings) or
# if a branch is missing, fall back to the last one.
# Candidates are no longer all local branches: a base can be a remote ref
# (origin/<base>, or the branch of a blocker delivered outside the run), hence the
# committish rather than refs/heads/.
deepest_branch() {
  local b o ok last="${!#}"
  for b in "$@"; do
    git rev-parse -q --verify "$b^{commit}" >/dev/null || { echo "$last"; return; }
  done
  for b in "$@"; do
    ok=1
    for o in "$@"; do
      [[ "$b" == "$o" ]] && continue
      git merge-base --is-ancestor "$o" "$b" || { ok=0; break; }
    done
    (( ok )) && { echo "$b"; return; }
  done
  echo "$last"
}

# Peak context reached by a session, from its JSONL transcript on stdin.
# A fresh session guarantees a clean start, not a clean finish: with a 1M window
# nothing compacts, and the session grows until the ticket is done.
# So it is the thermometer of the slicing — a ticket that brushes the window was too
# big, and it shows before quality degrades.
# A request's context = fresh + written to cache + read from cache; keep the max.
# Nothing to parse as JSON: the three keys are searched literally, the opening quote
# is enough to tell "input_tokens" from "cache_read_input_tokens".
peak_context() {
  awk '
    function num(line, re,   m) {
      if (match(line, re)) { m = substr(line, RSTART, RLENGTH); gsub(/[^0-9]/, "", m); return m + 0 }
      return 0
    }
    index($0, "\"usage\"") == 0 { next }
    {
      t = num($0, "\"input_tokens\":[0-9]+") \
        + num($0, "\"cache_creation_input_tokens\":[0-9]+") \
        + num($0, "\"cache_read_input_tokens\":[0-9]+")
      if (t > max) max = t
    }
    END { if (max) print max }
  '
}

# One field of the object returned by `claude -p --output-format json`, on stdin. No jq:
# a single key searched literally, like peak_context — and the session's error output
# lands in the same file, so a strict JSON parser would refuse to read it. The targeted
# keys (session_id, subtype, is_error, total_cost_usd) all precede the "result" field,
# which is free text: the first match is the right one.
jval() {   # key name
  grep -o "\"$1\":\"\?[^,\"}]*" | head -1 | cut -d: -f2- | tr -d '"'
}

# The models actually used by the session — one "canonicalModel" entry per model in
# modelUsage. This is what makes FALLBACK_MODEL visible: a fallback changes the model
# without saying so, and a whole night can swing onto the backup.
jmodels() {
  grep -o '"canonicalModel":"[^"]*"' | cut -d'"' -f4 | sed 's/^claude-//' | sort -u |
    paste -sd' ' -
}

# How many subagents the session spawned. This is what makes the "Model" column
# readable (defect 41): `modelUsage` aggregates the session AND its subagents, which
# carry the model of their definition (`.claude/agents/*.md`) and not the ticket's. A
# second model therefore read as a fallback, when it came from a review the session
# launched. `spawned_by_subagents` does not match: the pattern requires `":` after the
# name.
jspawned() {
  grep -o '"spawned":[0-9]*' | head -1 | cut -d: -f2
}

# Numbers taken twice. Receives paths on stdin (the files ADDED by a run's branches)
# and returns one line per clash: same directory, same leading numeric prefix, several
# different files.
#
# It looks like nothing and it is a whole blind spot: an ADR `0018-…`, a migration
# `1768621000034_…` — the number is a SHARED namespace, and each worktree starts from
# the base without seeing its neighbours, so each agent takes the free number it sees
# and is right. The file names differ → git sees no conflict; it compiles; the tests
# pass. No gate can say it, only the combination of the branches can.
clashing_numbers() {
  sort -u | awk '
    {
      n = split($0, p, "/"); file = p[n]
      dir = substr($0, 1, length($0) - length(file))
      if (match(file, /^[0-9]+/)) {
        key = dir "|" substr(file, RSTART, RLENGTH)
        if (!(key in g)) { g[key] = file; c[key] = 1 }
        else { g[key] = g[key] "  " file; c[key]++ }
      }
    }
    END {
      for (k in g) if (c[k] > 1) {
        split(k, kk, "|")
        printf "%s* in %s: %s\n", kk[2], (kk[1] == "" ? "./" : kk[1]), g[k]
      }
    }' | sort
}

[[ -n "${AFK_LIB:-}" ]] && return 0   # sourced by check.sh

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo"; exit 1; }

# ─── Arguments ────────────────────────────────────────────────────────────────

usage() {
  sed -n '3,18p' "$0" | sed 's/^# \?//'
}

ARGV=()
while (( $# )); do
  case "$1" in
    -j|--jobs)    JOBS="$2"; shift 2 ;;
    --jobs=*)     JOBS="${1#*=}"; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "unknown option: $1"; usage; exit 1 ;;
    *)            ARGV+=("$1"); shift ;;
  esac
done

# ─── Project config ───────────────────────────────────────────────────────────
# The defaults below are cut for a pnpm monorepo. A Python, PHP or Rust repo does not
# have the same definition of "done" — and even on an npm repo, `npm test` often opens
# a watcher that never returns (vitest without `run`): the ticket then dies on TIMEOUT,
# for a reason that has nothing to do with its content.
# So the project declares its own gate, in a versioned file next to its code — where
# the real definition of "done" lives, not on the command line.
# Sourced AFTER the arguments: the command line keeps the last word.
# Same trust surface as a ticket's "Verify:" lines: it is shell from the repo, executed
# as-is.
[[ -f .afk.env ]] && { echo "· project config: .afk.env"; source ./.afk.env; }

# ─── Config ───────────────────────────────────────────────────────────────────

# The mattpocock skills must exist INSIDE the headless session: same config dir as
# your interactive session, otherwise /implement is not resolved. We take the first
# directory that really contains the plugin, instead of a hardcoded default: in a
# devcontainer, the container's HOME is not the one where the host config is mounted
# ($HOME=/home/node, config under /home/<user>/.claude).
CLAUDE_CONFIG_CANDIDATES=("$HOME"/.claude /home/*/.claude)
if [[ -z "${CLAUDE_CONFIG_DIR:-}" ]]; then
  for d in "${CLAUDE_CONFIG_CANDIDATES[@]}"; do
    [[ -d "$d/plugins/cache/mattpocock" ]] && { CLAUDE_CONFIG_DIR="$d"; break; }
  done
fi
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"        # 1 attempt + 1 retry, in a fresh session
TIMEOUT="${TIMEOUT:-45m}"                # guard rail: bounds a run (no --max-turns in 2.1.x)
                                         # overridable per ticket: "Timeout:" line of the body
CI_TIMEOUT="${CI_TIMEOUT:-15m}"          # how long we wait for CI; 0 = do not consult it
CI_RETRY_WAIT="${CI_RETRY_WAIT:-10}"     # seconds before retrying a "no checks" (see ci_phase)
INTEGRATION="${INTEGRATION:-1}"          # integration pass over the green branches at the end
CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-0}"  # 0 = never pause. This is an unattended tool.

# The sessions' model and thinking level. Empty = claude(1)'s defaults.
# Overridable per ticket: "Model:" and "Effort:" lines of the body.
MODEL="${MODEL:-}"
EFFORT="${EFFORT:-}"

# An AFK run has nobody in front of it. Without a fallback, a transient model outage
# errors the session out, the ticket burns both attempts in a few seconds and goes to
# ready-for-human — for a reason that has nothing to do with it, and the whole queue
# follows. --fallback-model only works with --print, so exactly here. The fallback is
# visible: the summary gives the model that actually ran, ticket by ticket. Empty = no
# fallback.
FALLBACK_MODEL="${FALLBACK_MODEL:-sonnet}"

# A blocker delivered by hand — PR open, not merged yet — is neither "in the run" nor
# "closed": it froze its dependants until it merged, although its branch is pushed and
# readable. We stack on it like on a blocker delivered by the run. The PR will target
# that branch, not BASE_BRANCH: that is the price, and it is the same as for any
# stacked PR.
STACK_ON_OPEN_PR="${STACK_ON_OPEN_PR:-1}"

# A ticket already in-review has its PR open: running it again would open a second one
# on the same branch. Listing by label cannot bring them back, an explicit list can.
ALLOW_REVIEW="${ALLOW_REVIEW:-0}"

# Parallelism. One ticket per worktree: two agents in the same working tree trample
# each other. The blocker DAG is respected — a stacked ticket waits for its own.
JOBS="${JOBS:-1}"
[[ "$JOBS" == "auto" ]] && { JOBS=$(( $(nproc 2>/dev/null || echo 4) / 4 )); (( JOBS < 1 )) && JOBS=1; (( JOBS > 4 )) && JOBS=4; }

# Verification holds resources that cannot be duplicated: the test Postgres, the ports,
# and the RAM of a turbo typecheck. The Claude sessions, on the other hand, share
# nothing. So: agents in parallel, verifications queued.
VERIFY_LOCK="${VERIFY_LOCK:-1}"

# Verification. External to the agent: you grade its work, it does not.
VERIFY_CMD="${VERIFY_CMD:-pnpm typecheck && pnpm test && pnpm lint}"

# The integration pass's gate. The same one by default, but separable — because it is
# the only verdict of the run that has to be trustworthy, and a build cache can make it
# hollow: a tool that hashes the files TRACKED BY GIT does not see generated, gitignored
# files, so a worktree that has not produced them yields the same fingerprint as the
# main tree that has → cache hit, logs replayed, nothing executed. The gate prints a ✓
# without compiling a line, and that false green travels from worktree to worktree when
# the cache is shared. So a project can ask here for the uncached form (`turbo … --force`,
# `pytest -p no:cacheprovider`, …), which we do not want to pay per ticket but do want
# once, on the combination.
INTEGRATION_VERIFY_CMD="${INTEGRATION_VERIFY_CMD:-$VERIFY_CMD}"

# Paths that count as "decision captured". A multi-context monorepo keeps its glossaries
# and ADRs per app, not only at the root.
MEMORY_RE="${MEMORY_RE:-^(CONTEXT(-MAP)?\.md|(apps|packages)/[^/]+/CONTEXT\.md|docs/adr/|(apps|packages)/[^/]+/docs/adr/)}"

REPO_ROOT="$PWD"
# afk's own repo, which is NOT the repo being worked on: the script is mounted into the
# devcontainers and launched from any project. `$PWD` is the project, `$AFK_HOME` is afk
# — the only place that survives from one project to the next, and so the only one where
# a log can accumulate. `readlink -f` because the script is often reached through a
# symlink. Overridable: harness.sh redirects it so it does not write into the real repo
# during its tests.
AFK_HOME="${AFK_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}"
AFK_DIR="$REPO_ROOT/.afk"                 # logs and worktrees, self-ignored
WORKTREE_DIR="${WORKTREE_DIR:-$AFK_DIR/wt}"
KEEP_WORKTREES="${KEEP_WORKTREES:-0}"    # failed tickets' worktrees are kept regardless
DRY_RUN="${DRY_RUN:-0}"

# A fresh worktree only contains tracked files. The .env files are gitignored and the
# backend does not start without them: without this seeding, verification fails in a
# worktree for a reason that has nothing to do with the ticket.
SEED_GLOBS="${SEED_GLOBS:-.env .env.local apps/*/.env apps/*/.env.local packages/*/.env}"

# Install the worktree's dependencies. "auto" = deduced from the lockfile.
SETUP_CMD="${SETUP_CMD:-auto}"
if [[ "$SETUP_CMD" == "auto" ]]; then
  if   [[ -f pnpm-lock.yaml   ]]; then SETUP_CMD="pnpm install --frozen-lockfile --prefer-offline"
  elif [[ -f package-lock.json ]]; then SETUP_CMD="npm ci"
  elif [[ -f yarn.lock        ]]; then SETUP_CMD="yarn install --frozen-lockfile"
  else SETUP_CMD=""; fi
fi

LABEL="${LABEL:-$(label_for ready-for-agent)}";  LABEL="${LABEL:-ready-for-agent}"
LABEL_KO="${LABEL_KO:-$(label_for ready-for-human)}"; LABEL_KO="${LABEL_KO:-ready-for-human}"
# Delivered, PR open, waiting for a human. Without this state, a ticket whose PR is
# rejected loses its label and is picked up by nobody.
LABEL_REVIEW="${LABEL_REVIEW:-$(label_for in-review)}"; LABEL_REVIEW="${LABEL_REVIEW:-in-review}"

BASE_BRANCH="${BASE_BRANCH:-$(git symbolic-ref -q --short refs/remotes/origin/HEAD | cut -d/ -f2-)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
# Worktrees start from the REMOTE ref, never from the local branch: the main tree is
# never checked out, pulled or reset. You can keep working in it, on whatever branch
# you like, while a run is going.
# BASE_BRANCH stays the branch name — it is the PRs' target.
BASE_REF="origin/${BASE_BRANCH}"

# ─── Guard rails ──────────────────────────────────────────────────────────────

for bin in claude gh git timeout; do
  command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }
done

[[ -f docs/agents/issue-tracker.md ]] || {
  echo "docs/agents/issue-tracker.md missing — run /setup-matt-pocock-skills first"; exit 1; }
grep -qi 'github' docs/agents/issue-tracker.md || {
  echo "non-GitHub tracker — this script speaks gh(1)"; exit 1; }
[[ -d "$CLAUDE_CONFIG_DIR/plugins/cache/mattpocock" ]] || {
  echo "mattpocock plugin not found in $CLAUDE_CONFIG_DIR — /implement will not resolve"
  echo "  looked in: ${CLAUDE_CONFIG_CANDIDATES[*]}"
  echo "  force it: CLAUDE_CONFIG_DIR=/path/to/.claude $0 …"; exit 1; }

# Project memory: single-context root, or map + per-app contexts.
memory_present() {
  [[ -f CONTEXT.md || -f CONTEXT-MAP.md || -d docs/adr ]] && return 0
  compgen -G '*/*/CONTEXT.md' >/dev/null
}
memory_present || echo "⚠  no CONTEXT.md, no CONTEXT-MAP.md, no docs/adr/ — the agents will have no project memory"

(( JOBS > 1 )) && [[ "$VERIFY_LOCK" == "1" ]] && ! command -v flock >/dev/null && {
  echo "⚠  flock missing: verifications will run in parallel (shared Postgres and ports)"; }

# ─── Utilities ────────────────────────────────────────────────────────────────

fmt_dur() { local n=${1:-0}; printf '%dm%02ds' $(( n / 60 )) $(( n % 60 )); }

# A ticket's status: the worker runs in a subshell, it cannot write anything into the
# parent's arrays. It drops key=value lines, the parent reads them back.
sget() { grep -E "^$2=" "$AFK_DIR/$1.status" 2>/dev/null | tail -1 | cut -d= -f2-; }

# Serialise a command behind a named lock, when running in parallel.
locked() {
  local name="$1"; shift
  if (( JOBS > 1 )) && [[ "$VERIFY_LOCK" == "1" ]] && command -v flock >/dev/null; then
    flock "$AFK_DIR/$name.lock" "$@"
  else
    "$@"
  fi
}

# ─── Git without a keyboard ───────────────────────────────────────────────────
# The remote is on SSH, the key has a passphrase, and no ssh-agent runs in the
# container: every pull and every push asked for the keyboard — in a tool that means
# to say "away from keyboard". Worse, detached, the push slept without printing
# anything, indistinguishable from a ticket taking its time.
# We rewrite github.com to HTTPS for the duration of the run and serve gh's token,
# already authenticated and passphrase-free, through its own credential helper.
# Nothing is written into .git/config: the token never touches the disk.
setup_git_auth() {
  gh auth token >/dev/null 2>&1 || {
    echo "⚠  no gh token (gh auth login) — git stays on SSH and may ask for a passphrase"
    return; }
  export GIT_TERMINAL_PROMPT=0
  export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"
  export GIT_CONFIG_COUNT=4
  export GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf' GIT_CONFIG_VALUE_0='git@github.com:'
  export GIT_CONFIG_KEY_1='url.https://github.com/.insteadOf' GIT_CONFIG_VALUE_1='ssh://git@github.com/'
  export GIT_CONFIG_KEY_2='credential.helper'                 GIT_CONFIG_VALUE_2=''
  export GIT_CONFIG_KEY_3='credential.https://github.com.helper' GIT_CONFIG_VALUE_3='!gh auth git-credential'
}

# ─── Labels ───────────────────────────────────────────────────────────────────
# A --add-label on a non-existent label fails. Swallowed, the error made an abandoned
# ticket lose ready-for-agent without giving it anything in exchange: invisible to the
# orchestrator's query AND to a human's.

ensure_label() {
  local name="$1" desc="$2"
  grep -qx -- "$name" <<<"$KNOWN_LABELS" && return 0
  if gh label create "$name" --description "$desc" >/dev/null 2>&1; then
    echo "  · label ${name} created"
    KNOWN_LABELS+=$'\n'"$name"
  else
    echo "⚠  label ${name} missing and not creatable — labelling will fail"
  fi
}

relabel() {   # ticket, label removed, label added
  local t="$1" old="$2" new="$3" err
  err=$(gh issue edit "$t" --remove-label "$old" --add-label "$new" 2>&1 >/dev/null) ||
    echo "  ⚠  labelling #${t} (${old} → ${new}) failed: ${err}"
}

# ─── The prompt ───────────────────────────────────────────────────────────────
# Short by construction. If a ticket needs more to be understood on its own, the
# slicing is wrong, not the prompt too thin.

# What the blockers already delivered. The worktree starts from THEIR branch (see
# launch), so their work is already on disk here — but nothing tells the agent, and it
# starts in a fresh session. Two kinds of damage, both seen in the wild: it redoes work
# already done (the "absorbed" ticket burns both attempts rediscovering it alone), and
# it renames on the way a typed contract it just inherited, because it did not read the
# ADR its predecessor had just written for it.
# No file to produce, no format to impose on the agent: the predecessor already commits
# its decisions (see the CONTEXT.md/ADR instruction below), and the DAG acts as a
# filter — the base only contains this ticket's ancestors, nothing else from the run.
# The argument is the HEAD from BEFORE the session: on attempt 2, HEAD already carries
# the agent's own work, which it has nothing to learn from.
inherited_note() {   # inherited committish
  local files mem n
  files=$(git diff --name-only "$BASE_REF...$1" 2>/dev/null)
  [[ -z "$files" ]] && return 0
  n=$(wc -l <<<"$files")

  printf '\n--- INHERITED FROM YOUR BLOCKERS ---\n'
  printf 'Your base already carries their work (%d file(s)). If one of your ticket'"'"'s\n' "$n"
  printf 'criteria is already satisfied there, say so and do not rewrite it.\n'
  mem=$(grep -E "$MEMORY_RE" <<<"$files")
  [[ -n "$mem" ]] &&
    printf '\nTheir decisions, to read BEFORE coding:\n%s\n' "$(sed 's|^|  - |' <<<"$mem")"
  printf '\nFiles already touched:\n%s\n' "$(head -n 30 <<<"$files" | sed 's|^|  - |')"
  (( n > 30 )) &&
    printf '  … and %d more: git diff --name-only %s...%s\n' "$(( n - 30 ))" "$BASE_REF" "$1"
  return 0
}

build_prompt() {
  local ticket="$1" attempt="$2" verify="$3" inherited="$4"

  cat <<EOF
/implement GitHub ticket #${ticket}.

Fresh session, no history.

- Read the ticket: gh issue view ${ticket} --comments. It is authoritative — you do
  not change its acceptance criteria to make them pass.
- The repo is configured by /setup-matt-pocock-skills: CLAUDE.md, docs/agents/*.md,
  CONTEXT-MAP.md, each context's CONTEXT.md and the ADRs (docs/adr/ and
  <context>/docs/adr/) are the project's memory. You conform to them.
- You stay within the ticket's scope. No off-topic files.
- Done = this command goes green: ${verify}
- If holding the scope makes that command unreachable (a typed contract crossing the
  apps, for instance), do the strict minimum outside the scope to make it green and
  say so in an ADR: it is the ticket's slicing that was wrong, not you.
- Every non-trivial decision taken on the way (architecture, convention, constraint
  discovered, debt accepted) goes into a CONTEXT.md or an ADR, BEFORE you finish.
  The next session will know nothing of this run.
- You commit on the current branch, already created. You do not push, you do not open
  a PR, you do not touch the labels: that is the orchestrator's job.
- If you commit NOTHING, your last line says which of the two cases it is, verbatim:
  "AFK: ALREADY DONE" — the ticket's criteria are already satisfied in this base,
  there is nothing to write; or "AFK: BLOCKED <what is missing>" — it is too early, a
  prerequisite is not in this base. Without that line the orchestrator decides alone,
  with the only thing it knows how to do — run the gate on the base — and concludes
  "already done".
- You do not run the verification yourself: the orchestrator runs it after you.
  Running it means running it twice — and a session that yields its turn waiting for
  it finishes without having committed.
- Other tickets may be running in parallel in other worktrees. You only look here, you
  touch no other branch.
EOF

  inherited_note "$inherited"

  if [[ "$attempt" -gt 1 ]]; then
    cat <<EOF

--- RETRY (attempt ${attempt}) ---
A previous attempt failed verification. Output of the failure:

$(tail -n 60 "${AFK_DIR}/${ticket}-fail.txt" 2>/dev/null || echo "(unavailable)")

Its code is already committed on the branch. Fix it.
EOF
  fi
}

# ─── Plan ─────────────────────────────────────────────────────────────────────
# One reading pass before any launch: metadata cached (the worker no longer needs the
# API), blockers sorted into "in this run" and "outside and open".

declare -A DEPS=() EXT=() TITLE=() VERIFY=() TMO=() MDL=() EFF=()
EXT_FETCH=(); DROPPED=()

in_run() { local n="$1" t; for t in "${TICKETS[@]}"; do [[ "$t" == "$n" ]] && return 0; done; return 1; }

# Branch of an open PR delivering this ticket, if there is one. We first look for the
# convention the orchestrator imposes itself (feat/<n>), then, for a branch named
# otherwise, an open PR whose body closes this ticket.
open_pr_branch() {
  local b="$1" br
  [[ "$STACK_ON_OPEN_PR" == "1" ]] || return 0
  # `-q '.[0].x'` on an empty list prints "null": without the `// empty`, a blocker
  # with no PR would give the base "origin/null".
  br=$(gh pr list --state open --head "feat/$b" --json headRefName \
         --jq '.[0].headRefName // empty' 2>/dev/null)
  [[ "$br" == "null" ]] && br=""
  [[ -z "$br" ]] && br=$(gh pr list --state open --limit 100 --json headRefName,body \
      --jq '.[] | [.headRefName, ((.body // "") | gsub("\n"; " "))] | @tsv' 2>/dev/null |
    grep -iE "$(printf '\t.*(clos|fix|resolv)e?[sd]? +#%s([^0-9]|$)' "$b")" |
    head -1 | cut -f1)
  printf '%s' "$br"
}

plan_run() {
  local t body deps ext b pb
  for t in "${TICKETS[@]}"; do
    body=$(gh issue view "$t" --json body -q .body 2>/dev/null) || { echo "✗ #${t} not found"; exit 1; }
    TITLE[$t]=$(gh issue view "$t" --json title -q .title 2>/dev/null)
    printf '%s' "$body"          > "$AFK_DIR/$t.body"
    printf '%s' "${TITLE[$t]}"   > "$AFK_DIR/$t.title"
    gh issue view "$t" --json labels -q '.labels[].name' 2>/dev/null | tr '\n' ' ' > "$AFK_DIR/$t.labels"

    VERIFY[$t]=$(meta_line Verify "$RE_VERIFY" <<<"$body"); VERIFY[$t]="${VERIFY[$t]:-$VERIFY_CMD}"
    printf '%s' "${VERIFY[$t]}"  > "$AFK_DIR/$t.verify"
    TMO[$t]=$(meta_line Timeout "$RE_TIMEOUT" <<<"$body"); TMO[$t]="${TMO[$t]:-$TIMEOUT}"
    printf '%s' "${TMO[$t]}"     > "$AFK_DIR/$t.timeout"
    # A well-formed but wrong model name fails the session immediately, just like a
    # "Verify:" line that does not compile: same trust surface.
    MDL[$t]=$(meta_line Model "$RE_MODEL" <<<"$body"); MDL[$t]="${MDL[$t]:-$MODEL}"
    printf '%s' "${MDL[$t]}"     > "$AFK_DIR/$t.model"
    EFF[$t]=$(meta_line Effort "$RE_EFFORT" <<<"$body"); EFF[$t]="${EFF[$t]:-$EFFORT}"
    printf '%s' "${EFF[$t]}"     > "$AFK_DIR/$t.effort"

    # Already delivered, PR open: running it again would open a second PR on the same
    # branch. Dropping it from the list beats discovering it at gh pr create.
    if [[ "$ALLOW_REVIEW" != "1" && " $(cat "$AFK_DIR/$t.labels") " == *" $LABEL_REVIEW "* ]]; then
      echo "  ⏭  #${t} is ${LABEL_REVIEW} — skipped (ALLOW_REVIEW=1 to force)"
      DROPPED+=("$t"); continue
    fi

    # Native GitHub dependencies first; otherwise the body's "Blocked by" section.
    local raw
    raw=$(gh api "repos/{owner}/{repo}/issues/$t/dependencies/blocked_by" --jq '.[].number' 2>/dev/null)
    [[ -z "$raw" ]] && raw=$(blocked_refs <<<"$body")

    deps=""; ext=""
    for b in $raw; do
      if in_run "$b"; then deps+="$b "; continue; fi
      [[ "$(gh issue view "$b" --json state -q .state 2>/dev/null)" == "OPEN" ]] || continue
      # Open and outside the run. If it has a PR, its branch is a valid base: freezing
      # until it merges means refusing to stack on work already pushed.
      pb=$(open_pr_branch "$b")
      if [[ -n "$pb" ]]; then
        deps+="$b "; BRANCH_OF[$b]="origin/$pb"; EXT_FETCH+=("$pb")
        echo "  · #${t}: blocker #${b} delivered outside the run (open PR) → base origin/${pb}"
      else
        ext+="$b "
      fi
    done
    DEPS[$t]="$deps"; EXT[$t]="$ext"

    # A branch can only be checked out in one worktree. If you happen to be working on
    # feat/<t>, the ticket's worktree is impossible: better to learn it now than on a
    # git error in the middle of the run.
    local held
    held=$(git worktree list --porcelain |
      awk -v b="refs/heads/feat/$t" '$1=="worktree"{p=$2} $1=="branch"&&$2==b{print p}')
    [[ -n "$held" && "$held" != "$WORKTREE_DIR/$t" ]] &&
      echo "  ⚠  #${t}: feat/${t} is already checked out in ${held} — free the branch, or this ticket will fail"
  done
}

# ─── Worktree ─────────────────────────────────────────────────────────────────
# One ticket = one worktree. That is what makes parallelism possible without two
# agents trampling each other, and it frees the main tree: no more git reset --hard
# between two tickets, no more contamination.

seed_worktree() {
  local wt="$1" f n=0
  for f in $SEED_GLOBS; do
    [[ -f "$f" ]] || continue
    mkdir -p "$wt/$(dirname "$f")" && cp -p "$f" "$wt/$f" && n=$(( n + 1 ))
  done
  echo "$n"
}

make_worktree() {   # ticket, base, branches to absorb… → path on stdout
  local ticket="$1" base="$2"; shift 2
  local wt="$WORKTREE_DIR/$ticket" branch="feat/$ticket" extra

  git worktree remove --force "$wt" 2>/dev/null
  git worktree prune
  rm -rf "$wt"
  git worktree add -q -B "$branch" "$wt" "$base" 2>"$AFK_DIR/$ticket-wt.err" || return 1
  for extra in "$@"; do
    # `-q` does NOT silence the merge engine's "Auto-merging <file>", and they go to
    # stdout — the very one the caller reads the worktree path from. Without this
    # redirection, `wt=$(make_worktree …)` yields "Auto-merging x\n/path" and the `cd`
    # fails: any ticket absorbing a branch dies in 0s (defect 35).
    git -C "$wt" merge -q --no-edit "$extra" >>"$AFK_DIR/$ticket-wt.err" 2>&1 \
      || { git -C "$wt" merge --abort; return 2; }
  done
  seed_worktree "$wt" > "$AFK_DIR/$ticket-seed.n"
  echo "$wt"
}

drop_worktree() {
  local ticket="$1"
  [[ "$KEEP_WORKTREES" == "1" ]] && return 0
  git worktree remove --force "$WORKTREE_DIR/$ticket" 2>/dev/null
  rm -rf "$WORKTREE_DIR/$ticket"
}

# ─── Exit ─────────────────────────────────────────────────────────────────────
# drop_worktree only ran inside reap, so inside the orchestrator's loop: killing it
# between a worker's exit and its reaping left the worktree in place, with feat/<n>
# checked out in it. A tool that runs for hours gets interrupted.
# Here we kill the descendants (the worker is a subshell, claude and pnpm are under it:
# killing the subshell alone leaves them orphaned and alive), then we collect the
# worktrees of the tickets that have nothing left to say.

kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null
}

FINISHED=0
finish() {
  local rc=$? t res
  (( FINISHED )) && return; FINISHED=1
  trap - EXIT INT TERM

  if (( ${#PID[@]} )); then
    echo; echo "⚠  interrupted — ${#PID[@]} running session(s) killed: ${!PID[*]}"
    for t in "${!PID[@]}"; do kill_tree "${PID[$t]}"; done
    sleep 1
    for t in "${!PID[@]}"; do kill -KILL "${PID[$t]}" 2>/dev/null; done
  fi

  # A green (or absorbed) ticket no longer needs its worktree; a red one keeps it,
  # that is where we go to read what happened. An interrupted ticket counts as red.
  if (( ${#TICKETS[@]} )); then
    for t in "${TICKETS[@]}"; do
      res=$(sget "$t" result)
      [[ "$res" == "ok" || "$res" == "absorbed" ]] && drop_worktree "$t"
    done
  fi
  git worktree prune 2>/dev/null
  exit $rc
}

# ─── One ticket ───────────────────────────────────────────────────────────────
# Runs in a subshell, cwd = its worktree. Writes its verdict into
# $AFK_DIR/<t>.status; never writes into the parent's arrays.

worker() {
  local ticket="$1" base="$2" wt="$3"
  local branch="feat/$ticket" sf="$AFK_DIR/$ticket.status"
  local title labels verify tmo mdl eff head0 rc crashed netted attempt
  local out sid why c cost=0 cut=0 blocked
  # The summary only timed the ticket: "it is slow" without knowing whether the time
  # goes into SETUP_CMD, into the session or into the gate — and three of the four
  # phases are tunable (JOBS, TIMEOUT, VERIFY_CMD, SETUP_CMD). Serialising the gate has
  # no effect where it lasts a minute; knowing that meant opening the .json files one
  # by one (defect 43). The fourth phase, waiting on a lock, is deduced: dur minus the
  # sum.
  local s0 vrc t_setup=0 t_session=0 t_verify=0
  local -a copts
  local suspect pr_url pr_num pr_body

  st() { printf '%s\n' "$*" >> "$sf"; }
  : > "$sf"

  title=$(cat "$AFK_DIR/$ticket.title")
  labels=$(cat "$AFK_DIR/$ticket.labels")
  verify=$(cat "$AFK_DIR/$ticket.verify")
  tmo=$(cat "$AFK_DIR/$ticket.timeout" 2>/dev/null); tmo="${tmo:-$TIMEOUT}"
  mdl=$(cat "$AFK_DIR/$ticket.model" 2>/dev/null)
  eff=$(cat "$AFK_DIR/$ticket.effort" 2>/dev/null)
  # `result_initial`, not `result`: the file is append-only and `sget` reads the LAST
  # line, but a human running `cat` or `grep result=` on a green ticket used to read
  # `result=ko` at the top. Missing = red anyway (see `reap`).
  st "result_initial=ko"; st "branch=$branch"; st "base=$base"

  # The session's flags. --output-format json because the return code does not say WHY
  # a session stopped, and because the summary needs the cost, the model actually used
  # and the session id so a red ticket can be resumed by hand (claude --resume) instead
  # of being reread in a log.
  copts=(--permission-mode bypassPermissions --output-format json)
  [[ -n "$mdl" ]] && copts+=(--model "$mdl")
  [[ -n "$eff" ]] && copts+=(--effort "$eff")
  [[ -n "$FALLBACK_MODEL" ]] && copts+=(--fallback-model "$FALLBACK_MODEL")

  echo "  worktree    : ${wt#$REPO_ROOT/}"
  echo "  base        : ${base}"
  [[ "$verify" != "$VERIFY_CMD" ]] && echo "  gate        : ${verify}   (ticket Verify:)"
  [[ "$tmo" != "$TIMEOUT" ]] && echo "  budget      : ${tmo}   (ticket Timeout:)"
  [[ -n "$mdl" ]] && echo "  model       : ${mdl}"
  [[ -n "$eff" ]] && echo "  effort      : ${eff}"
  local seeded; seeded=$(cat "$AFK_DIR/$ticket-seed.n" 2>/dev/null || echo 0)
  (( seeded )) && echo "  seeded      : ${seeded} ignored file(s) copied from the main tree"

  cd "$wt" || { echo "  ✗ worktree unreachable"; return; }

  if [[ -n "$SETUP_CMD" ]]; then
    echo "  → dependencies (${SETUP_CMD})"
    # `AFK_TICKET` / `AFK_WORKTREE` are exported so `SETUP_CMD` can ISOLATE this
    # worktree from its neighbours. The need came from real damage (defect 17,
    # docs/defects*.md): several worktrees shared a test database hardcoded in a
    # versioned `.env.test`, so every neighbour's `migrate()`/`rollback()` broke the
    # suite here — and the current ticket was marked red for someone else's migration.
    #
    # It is the project that knows what it must isolate (a database, a port, a bucket),
    # not afk: it chains its own script in front of `SETUP_CMD` in its `.afk.env` and
    # reads these two variables. `SETUP_CMD` already runs in the worktree and under the
    # `install` lock, so serialised — two database creations do not cross.
    s0=$SECONDS
    AFK_TICKET="$ticket" AFK_WORKTREE="$wt" \
      locked install bash -c "$SETUP_CMD" > "$AFK_DIR/$ticket-setup.log" 2>&1; vrc=$?
    t_setup=$(( SECONDS - s0 )); st "t_setup=$t_setup"
    if (( vrc )); then
      echo "  ✗ dependency install failed — ${AFK_DIR##*/}/${ticket}-setup.log"
      st "result=ko"; st "reason=setup"; return
    fi
  fi

  head0=$(git rev-parse HEAD)

  for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
    echo "  → run ${attempt}/${MAX_ATTEMPTS} (fresh session)"
    st "attempt=$attempt"

    # Never --resume: resuming a session that just failed means restarting from the
    # polluted context that failed.
    out="$AFK_DIR/$ticket-$attempt.json"
    s0=$SECONDS
    timeout "$tmo" claude -p "$(build_prompt "$ticket" "$attempt" "$verify" "$head0")" \
      "${copts[@]}" > "$out" 2>&1
    rc=$?; crashed=0; netted=0; cut=0
    # Cumulative over the attempts, like the cost. And measured by afk, so background
    # subagents included — the session's own duration_ms only covers its main loop and
    # misses the 18 minutes of a review launched alongside.
    t_session=$(( t_session + SECONDS - s0 )); st "t_session=$t_session"

    # What the session says about itself. `subtype` NAMES the failure
    # (error_during_execution, error_max_turns…) where the return code gives only a
    # number; `session_id` makes it resumable by hand; the cost adds up over the
    # attempts, the model is the last one's — it is the one that produced the branch.
    sid=$(jval session_id < "$out"); why=$(jval subtype < "$out")
    st "session=$sid"; st "model=$(jmodels < "$out")"; st "subagents=$(jspawned < "$out")"
    # Nothing read = nothing to say: a session killed before writing its object must
    # leave the cost EMPTY in the summary, not a "$0.0000" that would read as a free
    # session.
    c=$(jval total_cost_usd < "$out")
    [[ -n "$c" ]] && { cost=$(awk -v a="$cost" -v b="$c" 'BEGIN{printf "%.4f", a+b}'); st "cost=$cost"; }

    (( rc == 124 )) && { echo "  ⚠  timeout ${tmo} — the ticket can carry its own \"Timeout:\" line"; crashed=1; cut=1; }
    (( rc != 0 && rc != 124 )) && {
      echo "  ⚠  session ended abnormally (${why:-code ${rc}}) — ${AFK_DIR##*/}/${ticket}-${attempt}.json"
      crashed=1; }

    # Safety net: /implement is supposed to commit, but we do not lose the work if it
    # forgets. The message comes from the ticket, not from a generic "wip": it is the
    # one the base would keep when the net produces the batch's only commit.
    [[ -n "$(git status --porcelain)" ]] && {
      echo "  ⚠  agent did not commit — committing for it"
      local type=feat; grep -qw bug <<<"$labels" && type=fix
      git add -A && git commit -qm "${type}(#${ticket}): ${title}"
      netted=1; }

    if [[ "$(git rev-parse HEAD)" == "$head0" ]]; then
      # Defect 40: the gate on the base says nothing about the ticket's CONTENT — it is
      # green because the repo compiles, not because the requested deletion happened. A
      # ticket the agent judges too early therefore came out "absorbed", so in-review
      # with a comment inviting closure: it disappeared from the next batch without
      # anything having been done. The only witness to the difference is the session,
      # which says it — the prompt asks it to say it verbatim. It is the same fact as an
      # unlifted blocker, so the same verdict: frozen, label unchanged, it comes back on
      # the next run. A second attempt would be the same session on the same base, with
      # the same conclusion.
      if grep -q 'AFK: BLOCKED' "$out"; then
        blocked=$(grep -o 'AFK: BLOCKED[^"\\]*' "$out" | head -1)
        echo "  ⏸  frozen — the session says a prerequisite is missing from this base: ${blocked#AFK: BLOCKED }"
        st "result=frozen"; st "reason=blocked"
        gh issue comment "$ticket" --body "$(printf '> *Generated by an AFK agent session.*\n\nSession exited without a single commit, saying that the base `%s` does not carry a prerequisite yet: *"%s"*. Nothing to review, nothing to close — the ticket keeps its label and comes back on the next run, once what it is missing has merged.' \
          "${base#origin/}" "${blocked#AFK: BLOCKED }")" >/dev/null 2>&1
        return
      fi
      # "The agent failed" and "there was nothing left to do" both came out as "no
      # commit": a ticket emptied by its predecessor burned both attempts then went to
      # ready-for-human, for a false reason. The base is already here and the gate
      # already runs — we run it on the base, and it decides between the two.
      echo "  · no commit — running the gate on the base to decide"
      s0=$SECONDS
      locked verify bash -c "$verify" > "$AFK_DIR/$ticket-verify.txt" 2>&1; vrc=$?
      t_verify=$(( t_verify + SECONDS - s0 )); st "t_verify=$t_verify"
      if (( vrc == 0 )); then
        echo "  ≡ absorbed — nothing to do and the base is green: already delivered by a predecessor"
        st "result=absorbed"; st "base_ref=$base"
        relabel "$ticket" "$LABEL" "$LABEL_REVIEW"
        gh issue comment "$ticket" --body "$(printf '> *Generated by an AFK agent session.*\n\nSession exited without a single commit, **and** the gate (`%s`) is already green on `%s`: the content of this ticket seems to have been delivered by a predecessor. No PR opened, nothing to review — check then close.' \
          "$verify" "${base#origin/}")" >/dev/null 2>&1
        return
      fi
      echo "  ✗ no commit — the agent produced nothing (and the base is not green)"
      { printf 'no commit produced (rc=%s). Gate on the base:\n\n' "$rc"
        tail -n 40 "$AFK_DIR/$ticket-verify.txt"; } > "$AFK_DIR/$ticket-fail.txt"
      continue
    fi

    echo "  → verification"
    s0=$SECONDS
    locked verify bash -c "$verify" > "$AFK_DIR/$ticket-verify.txt" 2>&1; vrc=$?
    t_verify=$(( t_verify + SECONDS - s0 )); st "t_verify=$t_verify"
    if (( vrc == 0 )); then
      git diff --name-only "$head0" | grep -qE "$MEMORY_RE" ||
        echo "  ⚠  no CONTEXT.md or ADR touched — decisions not captured, read closely"

      # A crashed session passes verification exactly like a healthy one: typecheck and
      # lint do not know what is missing. The work is not thrown away, but it comes out
      # as a draft and does not count as a green on the first attempt.
      suspect=$(( crashed || netted ))
      pr_body="Closes #${ticket}"$'\n\n'"Verified locally by afk: \`${verify}\`"
      # A ticket's scope is a PREDICTION: a ticket labelled on one app may well touch
      # two (a shared key drags along everything indexing on it), and its `Verify:` line
      # was cut before we knew. When the local gate is replaced, CI is the only complete
      # gate — the reviewer must read that on the PR, not deduce it from the ticket body.
      [[ "$verify" != "$VERIFY_CMD" ]] && pr_body+=$'\n\n'"> ⚠ **Local gate replaced** by the ticket's \`Verify:\` line. The repo's complete gate is \`${VERIFY_CMD}\`: what it covers and this line does not was verified ONLY by this PR's CI."
      # A session CUT at the timeout may have been cut in the middle of a file; a
      # session that yielded its turn stopped between two actions. The gate says neither
      # — it says that what exists compiles. That is not the same review.
      if (( cut )); then
        pr_body+=$'\n\n'"> ⚠ **The agent session was CUT** after \`${tmo}\` (ticket's \`Timeout:\` line). It may have been cut in the middle of a file: the gate says that what exists compiles, not that the work is complete. Session: \`.afk/${ticket}-${attempt}.json\`."
      elif (( crashed )); then
        pr_body+=$'\n\n'"> ⚠ **The agent session ended abnormally** (${why:-code ${rc}}). The work present passes verification, but nothing guarantees it is complete — hence the draft. Session: \`.afk/${ticket}-${attempt}.json\`."
      fi
      (( netted ))  && pr_body+=$'\n\n'"> ⚠ The agent did not commit by itself: the orchestrator caught up the working tree."

      # The branch is complete, green and committed: what failed is the transport (token
      # without the `workflow` scope, branch already on the remote), not the work. A
      # second attempt would fail identically, and filing it with the reds makes it start
      # over from scratch on the next run. It gets its own line in the summary, and its
      # worktree is kept like a red one's.
      if ! git push -qu origin "$branch" 2>"$AFK_DIR/$ticket-push.txt"; then
        echo "  ✗ push refused — ${AFK_DIR##*/}/${ticket}-push.txt"
        sed 's/^/     /' "$AFK_DIR/$ticket-push.txt" | head -n 5
        cp "$AFK_DIR/$ticket-push.txt" "$AFK_DIR/$ticket-fail.txt"
        st "result=ko"; st "reason=push"; return
      fi

      local draft=(); (( suspect )) && draft=(--draft)
      pr_url=$(gh pr create --base "${base#origin/}" --head "$branch" "${draft[@]}" \
        --title "$title" --body "$pr_body") || { echo "  ✗ gh pr create failed"; st "result=ko"; st "reason=pr"; return; }
      pr_num="${pr_url##*/}"
      relabel "$ticket" "$LABEL" "$LABEL_REVIEW"

      local dwhy=""
      (( cut )) && dwhy="cut"; (( crashed && ! cut )) && dwhy="abnormal"
      (( netted )) && dwhy="${dwhy:+$dwhy, }not committed"
      st "result=ok"; st "pr=$pr_num"; st "draft=$suspect"; st "draft_why=$dwhy"
      if (( suspect )); then
        echo "  ✓ green (attempt ${attempt}) — PR #${pr_num} as DRAFT on ${base#origin/}"
        echo "     ⚠  ${dwhy}: read it before leaving draft"
      else
        echo "  ✓ green (attempt ${attempt}) — PR #${pr_num} on ${base#origin/}"
      fi
      return
    fi

    cp "$AFK_DIR/$ticket-verify.txt" "$AFK_DIR/$ticket-fail.txt"
    echo "  ✗ red"
    tail -n 8 "$AFK_DIR/$ticket-fail.txt" | sed 's/^/     /'
  done

  echo "  ✗ gave up after ${MAX_ATTEMPTS} attempts → ${AFK_DIR##*/}/${ticket}-fail.txt"
  st "result=ko"; st "reason=verify"
  relabel "$ticket" "$LABEL" "$LABEL_KO"
  gh issue comment "$ticket" --body "$(printf '> *Generated by an AFK agent session.*\n\n%d attempts, verification still red (`%s`). Branch `%s` (not pushed). Last output:\n\n```\n%s\n```' \
    "$MAX_ATTEMPTS" "$verify" "$branch" "$(tail -n 40 "$AFK_DIR/$ticket-fail.txt")")" >/dev/null 2>&1
}

# ─── Scheduler ────────────────────────────────────────────────────────────────
# Launches up to JOBS tickets at a time, in the given order, only starting those whose
# blockers in this run are already green. A red blocker freezes its dependants: their
# base does not exist.

declare -A BRANCH_OF=() PID=() START=() WT=() CONFLICT_FILES=()
OK=(); KO=(); SKIP=(); DRAFT=(); ABSORBED=(); PUSH_KO=(); CONFLICT=(); FIRST_TRY=0

deps_state() {   # 0 = ready, 1 = wait, 2 = frozen
  local t="$1" b state=0
  [[ -n "${EXT[$t]}" ]] && return 2
  for b in ${DEPS[$t]}; do
    if   [[ -n "${BRANCH_OF[$b]:-}" ]]; then continue
    elif [[ " ${KO[*]} ${SKIP[*]} ${PUSH_KO[*]} " == *" $b "* ]]; then return 2
    else state=1; fi
  done
  return $state
}

launch() {
  local t="$1" base="$BASE_REF" stack=() b rest=() wt rc
  for b in ${DEPS[$t]}; do stack+=("${BRANCH_OF[$b]}"); done
  if (( ${#stack[@]} )); then
    base=$(deepest_branch "${stack[@]}")
    for b in "${stack[@]}"; do
      [[ "$b" == "$base" ]] && continue
      git merge-base --is-ancestor "$b" "$base" 2>/dev/null && continue  # already in
      rest+=("$b")
    done
    stack=("${rest[@]}")
  fi

  wt=$(make_worktree "$t" "$base" "${stack[@]}"); rc=$?
  if (( rc == 2 )); then
    # It stays in SKIP — its dependants freeze the same — but the summary no longer says
    # "frozen", which is the word for a blocker NEVER delivered. Here it is the opposite:
    # they are all there and do not hold together. The paths are in <n>-wt.err, the only
    # file of the run the legend did not cite; read without it, the summary sends you
    # looking for a missing blocker that does not exist (defect 45).
    CONFLICT_FILES[$t]=$(sed -n 's/^CONFLICT ([^)]*): \(Merge conflict in \)\?//p' \
      "$AFK_DIR/$t-wt.err" 2>/dev/null | sort -u | paste -sd' ' -)
    echo "  ⏸  #${t}: conflict between blockers — to be done by hand${CONFLICT_FILES[$t]:+ : ${CONFLICT_FILES[$t]}}"
    CONFLICT+=("$t"); SKIP+=("$t"); return
  elif (( rc != 0 )); then
    echo "  ✗ #${t}: worktree impossible — $(cat "$AFK_DIR/$t-wt.err" 2>/dev/null | head -1)"
    KO+=("$t"); return
  fi

  WT[$t]="$wt"; START[$t]=$SECONDS
  if (( JOBS == 1 )); then
    echo; echo "═══ #${t} — ${TITLE[$t]} ═══"
    ( worker "$t" "$base" "$wt" 2>&1 | tee "$AFK_DIR/$t.out" ) &
  else
    echo "  ▸ #${t} started  (base ${base}$( (( ${#stack[@]} )) && echo ", absorbs ${stack[*]}" ))"
    ( worker "$t" "$base" "$wt" > "$AFK_DIR/$t.out" 2>&1 ) &
  fi
  PID[$t]=$!
}

reap() {   # collects the finished tickets; returns 0 if at least one finished
  local t got=1
  for t in "${TICKETS[@]}"; do
    [[ -n "${PID[$t]:-}" ]] || continue
    kill -0 "${PID[$t]}" 2>/dev/null && continue
    wait "${PID[$t]}" 2>/dev/null
    local dur=$(( SECONDS - START[$t] )) res; res=$(sget "$t" result)
    printf 'dur=%s\n' "$dur" >> "$AFK_DIR/$t.status"
    unset 'PID[$t]'; got=0

    if (( JOBS > 1 )); then
      echo; echo "═══ #${t} — ${TITLE[$t]}  ($(fmt_dur "$dur")) ═══"
      sed 's/^/  /' "$AFK_DIR/$t.out" 2>/dev/null
      # The dump's last line is the project test runner's, with its own measurement
      # ("Time: 2m3.821s" in Japa): it times the GATE, not the ticket, and that is the
      # one the eye reads at the bottom of thirty lines. We repeat ours after it
      # (defect 37) — the header has already scrolled off the screen.
      echo "  ⏱  #${t}: $(fmt_dur "$dur") in total (the durations above are the gate's)"
    else
      echo "  ⏱  $(fmt_dur "$dur") in total"
    fi

    if [[ "$res" == "ok" ]]; then
      OK+=("$t"); BRANCH_OF[$t]=$(sget "$t" branch)
      if [[ "$(sget "$t" draft)" == "1" ]]; then DRAFT+=("$t")
      elif [[ "$(sget "$t" attempt)" == "1" ]]; then FIRST_TRY=$(( FIRST_TRY + 1 )); fi
      drop_worktree "$t"
    elif [[ "$res" == "absorbed" ]]; then
      # Nothing to deliver, so no branch of its own: its dependants stack on the base it
      # used itself, otherwise they would freeze behind a false failure.
      ABSORBED+=("$t"); BRANCH_OF[$t]=$(sget "$t" base_ref)
      drop_worktree "$t"; git branch -qD "feat/$t" 2>/dev/null
    elif [[ "$res" == "frozen" ]]; then
      # Same list as the tickets frozen by an unlifted blocker: it is the same thing,
      # said by the session instead of the scheduler. No branch to keep — it is empty —
      # and no dependant to let go: what is missing here is missing for them too.
      SKIP+=("$t"); drop_worktree "$t"; git branch -qD "feat/$t" 2>/dev/null
    elif [[ "$(sget "$t" reason)" == "push" ]]; then
      PUSH_KO+=("$t")   # branch green and committed locally, only not pushed
    else
      KO+=("$t")   # worktree kept: that is where we go to read what happened
    fi
  done
  return $got
}

schedule() {
  local todo=("${TICKETS[@]}") i t hb=0
  while (( ${#todo[@]} || ${#PID[@]} )); do
    local progress=0
    for i in "${!todo[@]}"; do
      (( ${#PID[@]} >= JOBS )) && break
      t="${todo[$i]}"
      deps_state "$t"
      case $? in
        0) unset 'todo[$i]'; launch "$t"; progress=1 ;;
        2) unset 'todo[$i]'
           if [[ -n "${EXT[$t]}" ]]; then
             echo "  ⏸  #${t} frozen — blockers open outside the run: ${EXT[$t]% }"
           else
             echo "  ⏸  #${t} frozen — a blocker in this run was not delivered"
           fi
           SKIP+=("$t"); progress=1 ;;
      esac
    done
    todo=("${todo[@]}")   # recompact

    if (( ${#PID[@]} == 0 )); then
      (( progress )) && continue
      for t in "${todo[@]}"; do
        echo "  ⏸  #${t} frozen — dependency cycle or undeliverable blocker"
        SKIP+=("$t")
      done
      break
    fi

    until reap; do
      sleep 3
      hb=$(( hb + 3 ))
      if (( JOBS > 1 && hb >= 120 && ${#PID[@]} )); then
        hb=0; local line=""
        for t in "${!PID[@]}"; do line+="#${t} ($(fmt_dur $(( SECONDS - START[$t] )))) "; done
        echo "  …  running: ${line}"
      fi
    done
  done
}

# ─── The repo's CI ────────────────────────────────────────────────────────────
# VERIFY_CMD runs locally. Without this guard rail, a ticket can be delivered, labelled
# and merged although the repo's CI never ran on it — and that happened on five tickets
# in a row, runner stuck, with nothing flagging it.
# At the end of the run, not in the worker: waiting 15 minutes of CI would tie up a
# parallelism slot for polling.

# "No CI declared" and "CI still running" came out in the same bucket. It is not the
# same information: the second is a verdict that is missing, the first is a property of
# the REPO, true for every ticket of every run. Conflated, they marked "unproven green"
# the fifteen tickets of a batch on a repo without a workflow.
CI_RED=(); CI_UNKNOWN=(); CI_NONE=()

ci_phase() {
  (( ${#OK[@]} )) || return 0
  [[ "$CI_TIMEOUT" == "0" ]] && return 0
  echo; echo "═══ CI (${#OK[@]} PR, timeout ${CI_TIMEOUT}) ═══"

  local t pr pids=()
  for t in "${OK[@]}"; do
    pr=$(sget "$t" pr)
    # `--watch` only watches check runs ALREADY registered: with zero of them, it does
    # not wait, it exits immediately. But GitHub takes a few seconds to register the run
    # after `gh pr create` (measured: ~4 s), which exposes the last PR created.
    # "The repo has no CI" and "CI is not registered yet" therefore produced the same
    # sentence, although the second is fixed by retrying.
    ( local crc; for _ in 1 2 3 4; do
        timeout "$CI_TIMEOUT" gh pr checks "$pr" --watch $CI_FAILFAST > "$AFK_DIR/$t-ci.txt" 2>&1
        crc=$?
        grep -qi 'no checks' "$AFK_DIR/$t-ci.txt" || break
        sleep "$CI_RETRY_WAIT"
      done
      echo "$crc" > "$AFK_DIR/$t-ci.rc" ) &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null

  for t in "${OK[@]}"; do
    pr=$(sget "$t" pr); local rc; rc=$(cat "$AFK_DIR/$t-ci.rc" 2>/dev/null || echo 1)
    case "$rc" in
      0)   echo "  ✓ #${t} (PR #${pr}) CI green" ;;
      124) echo "  ⚠  #${t} (PR #${pr}) CI still running after ${CI_TIMEOUT} — inconclusive"
           CI_UNKNOWN+=("$t") ;;
      *)   if grep -qi 'no checks' "$AFK_DIR/$t-ci.txt" 2>/dev/null; then
             echo "  ⚠  #${t} (PR #${pr}) no CI declared"; CI_NONE+=("$t")
           else
             echo "  ✗ #${t} (PR #${pr}) CI red"
             grep -iE 'fail|error' "$AFK_DIR/$t-ci.txt" 2>/dev/null | head -n 3 | sed 's/^/       /'
             CI_RED+=("$t")
             relabel "$t" "$LABEL_REVIEW" "$LABEL_KO"
             gh issue comment "$t" --body "$(printf '> *Generated by an AFK agent session.*\n\nPR #%s opened and local verification green, but **the repo CI is red**. Moved back to `%s`.\n\n```\n%s\n```' \
               "$pr" "$LABEL_KO" "$(tail -n 30 "$AFK_DIR/$t-ci.txt")")" >/dev/null 2>&1
           fi ;;
    esac
  done
}

# ─── Integration ──────────────────────────────────────────────────────────────
# Each ticket is verified on its branch alone. Two batches green in isolation can
# produce a red base — or refuse to merge, over a CLAUDE.md and a component neither of
# them announced. We merge everything into a throwaway worktree and run the gate again.
# We touch no PR: we report.

INTEG_CONFLICTS=(); INTEG_MERGED=(); INTEG_VERDICT="—"
declare -A INTEG_FILES=()   # branch → conflicting files, for the summary
INTEG_NOTES=""              # duplicate numbers, paths created twice, stale references

# The files added by each green branch, one "<branch> <path>" line.
# Against ITS base, not against BASE_REF: a stacked branch carries its blocker's
# commits, so it also "adds" that one's files.
added_files() {
  local t b
  for t in "${OK[@]}"; do
    b=$(sget "$t" base); b="${b:-$BASE_REF}"
    git diff --name-only --diff-filter=A "$b...${BRANCH_OF[$t]}" 2>/dev/null |
      sed "s|^|${BRANCH_OF[$t]} |"
  done
}

numbering_clashes() { added_files | cut -d' ' -f2- | clashing_numbers; }

# Two branches that CREATE the same path are each green on their own — the file answers
# the same need seen from both ends, with two different APIs and both of them right. No
# gate can see it. Neither can `clashing_numbers`: its input `sort -u` crushes exactly
# the two identical lines we are looking for, and its awk only looks at names starting
# with a digit.
same_path_adds() {
  added_files | sort -u |
    awk '{ b[$2] = b[$2] " " $1; n[$2]++ } END { for (p in n) if (n[p] > 1) printf "%s :%s\n", p, b[p] }' |
    sort
}

# Merging a stacked branch BEFORE its base is a conflict by construction, and it reads
# like a real overlap. The green list is filled in COMPLETION order; we re-sort it by
# number of commits since the common base — a stacked branch has strictly more than its
# own, so it comes after.
merge_order() {
  local t
  for t in "${OK[@]}"; do
    printf '%s %s\n' "$(git rev-list --count "$BASE_REF..${BRANCH_OF[$t]}" 2>/dev/null || echo 0)" "$t"
  done | sort -n | cut -d' ' -f2
}

# One branch writes "#116 is the one that will open this list"; #116 delivers in the
# same run; nobody rewrites the sentence — neither the branch that wrote it (it is
# finished), nor #116 (it does not know it is quoted). Both sides agree, git merges in
# silence, and the docs state in the future tense what has been delivered for ten
# minutes. We do not judge the sentence, we show where it is. `git grep`: tracked files
# only.
stale_refs() {   # $1 = integration worktree
  local nums; nums=$(IFS='|'; echo "${OK[*]}")
  git -C "$1" grep -nE "#(${nums})([^0-9]|$)" -- '*.md' ':!CHANGELOG.md' ':!RUNS.md' 2>/dev/null |
    head -n 20
}

integration_check() {
  { (( ${#OK[@]} < 2 )) || [[ "$INTEGRATION" != "1" ]]; } && return 0
  echo; echo "═══ Integration (${#OK[@]} green branches) ═══"

  local wt="$WORKTREE_DIR/_integration" t b clashes
  git worktree remove --force "$wt" 2>/dev/null; git worktree prune; rm -rf "$wt"
  git worktree add -q -B afk-integration "$wt" "$BASE_REF" || {
    echo "  ✗ integration worktree impossible"; return 0; }
  seed_worktree "$wt" >/dev/null

  for t in $(merge_order); do
    b="${BRANCH_OF[$t]}"
    if git -C "$wt" merge -q --no-edit "$b" 2>"$AFK_DIR/integration-merge.err"; then
      echo "  merge ${b} ✓"
      INTEG_MERGED+=("$b")
    else
      local files; files=$(git -C "$wt" diff --name-only --diff-filter=U | tr '\n' ' ')
      git -C "$wt" merge --abort 2>/dev/null
      # With no conflicting file, the merge was REFUSED (dirty tree, missing base) —
      # that is not the same information as a real overlap, and writing it "CONFLICT"
      # sends you looking in the wrong place.
      if [[ -n "$files" ]]; then
        echo "  merge ${b} ✗ CONFLICT — ${files}"
      else
        files="REFUSED — $(head -n 1 "$AFK_DIR/integration-merge.err")"
        echo "  merge ${b} ✗ ${files}"
      fi
      # Written, not just printed: it is the data the review needs first — it says which
      # of the conflicts are docs and which are code, so how much resolving will cost.
      # The terminal, on the other hand, gets closed.
      INTEG_FILES[$b]="$files"
      INTEG_CONFLICTS+=("$b")
    fi
  done

  # Number clashes and paths created twice are read on the branches, not on the merged
  # tree: two files with different names coexist there without saying anything, and a
  # resolved `add/add` keeps only one.
  clashes=$(numbering_clashes)
  if [[ -n "$clashes" ]]; then
    echo "  ⚠  numbers taken twice (no gate will see it):"
    sed 's/^/       /' <<<"$clashes"
    INTEG_NOTES+=$'\n'"- numbers taken twice:"$'\n'"$(sed 's/^/  - /' <<<"$clashes")"
  fi
  local dupes; dupes=$(same_path_adds)
  if [[ -n "$dupes" ]]; then
    echo "  ⚠  same path created by several branches:"
    sed 's/^/       /' <<<"$dupes"
    INTEG_NOTES+=$'\n'"- same path created by several branches:"$'\n'"$(sed 's/^/  - /' <<<"$dupes")"
  fi

  local stale; stale=$(stale_refs "$wt")
  if [[ -n "$stale" ]]; then
    echo "  ⚠  tickets from this run cited in the merged docs — read them, the sentence may be in the future tense:"
    sed 's/^/       /' <<<"$stale"
    INTEG_NOTES+=$'\n'"- tickets from this run cited in the merged docs (future tense?):"$'\n'"$(sed 's/^/  - /' <<<"$stale")"
  fi

  # `_integration` as a ticket number: the pass replays the gate, so it migrates like a
  # worker and must isolate itself the same way (see `AFK_TICKET` in the worker).
  [[ -n "$SETUP_CMD" ]] && ( cd "$wt" && AFK_TICKET=_integration AFK_WORKTREE="$wt" \
    locked install bash -c "$SETUP_CMD" ) > "$AFK_DIR/integration-setup.log" 2>&1

  echo "  → verifying the whole"
  [[ "$INTEGRATION_VERIFY_CMD" != "$VERIFY_CMD" ]] &&
    echo "     integration gate: ${INTEGRATION_VERIFY_CMD}"
  local ok=0
  ( cd "$wt" && locked verify bash -c "$INTEGRATION_VERIFY_CMD" ) \
    > "$AFK_DIR/integration-verify.txt" 2>&1 && ok=1

  # The verdict CARRIES ITS SCOPE. "The whole compiles" after a branch was set aside at
  # merge reads in the summary as "all the branches combine", which is precisely the
  # question the pass exists to answer.
  local scope="" n=${#INTEG_MERGED[@]} m=${#OK[@]}
  (( ${#INTEG_CONFLICTS[@]} )) && scope=" — PARTIAL: ${n}/${m} branches, without ${INTEG_CONFLICTS[*]}"
  if (( ok )); then
    INTEG_VERDICT="green"; echo "  ✓ the whole compiles${scope}"
  else
    INTEG_VERDICT="red"; echo "  ✗ red at integration${scope} — .afk/integration-verify.txt"
    tail -n 10 "$AFK_DIR/integration-verify.txt" | sed 's/^/     /'
  fi
  (( ${#INTEG_CONFLICTS[@]} )) && INTEG_VERDICT="$INTEG_VERDICT (partial: ${n}/${m})"
  [[ -n "$clashes" ]] && INTEG_VERDICT="$INTEG_VERDICT + duplicate numbers"
  [[ -n "$dupes"   ]] && INTEG_VERDICT="$INTEG_VERDICT + duplicate paths"

  if [[ "$KEEP_WORKTREES" != "1" && "$ok" == "1" && ${#INTEG_CONFLICTS[@]} -eq 0 && -z "$clashes" && -z "$dupes" ]]; then
    git worktree remove --force "$wt" 2>/dev/null; rm -rf "$wt"
    git branch -qD afk-integration 2>/dev/null
  else
    echo "  · worktree kept for inspection: .afk/wt/_integration"
  fi
}

# ─── Summary ──────────────────────────────────────────────────────────────────

# This run's transcripts for a ticket. Claude Code files them under
# $CLAUDE_CONFIG_DIR/projects/<the session's cwd, / and . replaced by ->.
ctx_of() {
  local t="$1" d
  d="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$WORKTREE_DIR/$t" | sed 's#[/._]#-#g')"
  [[ -d "$d" ]] || return 0
  find "$d" -maxdepth 1 -name '*.jsonl' -newer "$RUN_MARKER" -exec cat {} + 2>/dev/null |
    peak_context
}

# One line per run in afk's own repo. `.afk/summary.md` is OVERWRITTEN on the next run:
# without this log, no history exists anywhere, and a night's green rate compares to
# nothing. It travels across projects, this repo being mounted in each of them.
# No LLM: these are facts, not a judgement — the judgement is in /afk-debrief, which
# writes afk's own defects into docs/defects.md (fixed ones: defects-fixed.md).
append_run_log() {
  local f="$AFK_HOME/RUNS.md" t models total project
  # Repo mounted read-only: we do not log, it is not a run error.
  [[ -w "$AFK_HOME" ]] || return 0

  models=$(for t in "${TICKETS[@]}"; do sget "$t" model; done | tr ' ' '\n' | awk 'NF' |
    sort -u | paste -sd' ' -)
  total=$(for t in "${TICKETS[@]}"; do sget "$t" cost; done | awk '{s+=$1} END{if(s) printf "$%.2f", s}')
  # The project is not named here: this log lives in afk's repo, which is public and
  # read out of context. A stable digest keeps one project's rows grouped — which is the
  # only thing the column is read for — without disclosing which project it is.
  project="project-$(printf '%s' "${REPO_ROOT##*/}" | sha1sum | cut -c1-8)"

  [[ -f "$f" ]] || {
    printf '# Run log\n\n'
    printf "One line per \`afk.sh\` run, appended automatically at the end. \`.afk/summary.md\`\n"
    printf "is overwritten on the next run: here, and only here, is where the history survives —\n"
    printf "and it spans projects, this repo being mounted in each of them.\n\n"
    printf "Facts only. Anything needing judgement goes into\n"
    printf '[docs/defects.md](docs/defects.md), written by `/afk-debrief`.\n\n'
    printf 'The project column is a stable digest of the repo directory name, not its name:\n'
    printf 'the same project always yields the same value, and nothing else is disclosed.\n\n'
    printf '| Date | Project | Tickets | Green | Unproven | Draft | Red | Push refused | Frozen | Absorbed | 1st try | Model | Cost | Duration | Integration |\n'
    printf '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n'
  } > "$f"

  # A single printf, a single short line: two runs launched from two projects can append
  # at the same time without stepping on each other.
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$(date +%Y-%m-%d\ %H:%M)" "$project" "${#TICKETS[@]}" \
    "${#GREEN[@]}" "${#UNPROVEN[@]}" "${#DRAFT[@]}" "${#KO[@]}" "${#PUSH_KO[@]}" \
    "${#SKIP[@]}" "${#ABSORBED[@]}" \
    "${FIRST_TRY}/$(( ${#OK[@]} + ${#KO[@]} ))" "${models:-—}" "${total:-—}" \
    "$(fmt_dur $SECONDS)" "$INTEG_VERDICT" >> "$f"
}

write_summary() {
  local f="$AFK_DIR/summary.md" t b
  {
    printf '# afk run — %s tickets, %s\n\n' "${#TICKETS[@]}" "$(fmt_dur $SECONDS)"
    printf '| Ticket | Result | PR | Attempt | Model | Context | Cost | Duration | Phases | Title |\n'
    printf '|---|---|---|---|---|---|---|---|---|---|\n'
    for t in "${TICKETS[@]}"; do
      local res pr att d ctx mdl cost sa ph
      res=$(sget "$t" result); pr=$(sget "$t" pr); att=$(sget "$t" attempt)
      d=$(sget "$t" dur); d=${d:+$(fmt_dur "$d")}; d=${d:-—}
      ctx=$(ctx_of "$t"); ctx=${ctx:+$(( ctx / 1000 ))k}; ctx=${ctx:-—}
      mdl=$(sget "$t" model); mdl=${mdl:-—}
      # The number of subagents goes with the models, not in its own column: it is what
      # says whether a second model is a fallback or a review, and it explains part of
      # the cost at the same time.
      sa=$(sget "$t" subagents); (( ${sa:-0} > 0 )) && mdl+=" (+${sa} subagents)"
      cost=$(sget "$t" cost); cost=${cost:+\$$cost}; cost=${cost:-—}
      # A per-ticket duration does not say where it goes. The three measurable phases cut
      # it up, the fourth (waiting on a lock) is what is left (defect 43).
      local tse; tse=$(sget "$t" t_session)
      if [[ -n "$tse" ]]; then
        ph="$(fmt_dur "$(sget "$t" t_setup)") / $(fmt_dur "$tse") / $(fmt_dur "$(sget "$t" t_verify)")"
      else ph="—"; fi
      [[ " ${SKIP[*]} " == *" $t "* ]] && res="frozen"
      [[ " ${CONFLICT[*]} " == *" $t "* ]] && res="conflict"
      [[ " ${DRAFT[*]} " == *" $t "* ]] && res="draft"
      [[ " ${ABSORBED[*]} " == *" $t "* ]] && res="absorbed"
      [[ " ${UNPROVEN[*]} " == *" $t "* ]] && res="unproven green"
      [[ " ${PUSH_KO[*]} " == *" $t "* ]] && res="push refused"
      [[ " ${CI_RED[*]} " == *" $t "* ]] && res="$res / CI red"
      [[ -n "${VERIFY[$t]:-}" && "${VERIFY[$t]}" != "$VERIFY_CMD" ]] && res="$res ⚠"
      printf '| #%s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$t" "${res:-—}" "${pr:+#$pr}" "${att:-—}" "$mdl" "$ctx" "$cost" "$d" "$ph" "${TITLE[$t]:-}"
    done
    printf -- '\n- integration: %s%s\n' "$INTEG_VERDICT" \
      "$( (( ${#INTEG_CONFLICTS[@]} )) && echo " — set aside at merge: ${INTEG_CONFLICTS[*]} ; merged: ${INTEG_MERGED[*]}" )"
    # The ON WHAT, not just the WHO: `integration-merge.err` is overwritten at each
    # branch and git reports the CONFLICTs on stdout, so without this the file list gets
    # rebuilt with `git merge-tree` while guessing the original merge order.
    for b in "${INTEG_CONFLICTS[@]}"; do
      printf -- '  - `%s`: %s\n' "$b" "${INTEG_FILES[$b]:-—}"
    done
    # The ON WHAT holds for a ticket's stacking as much as for the integration merge:
    # "conflict" without the paths still points at a file the legend did not name.
    for b in "${CONFLICT[@]}"; do
      printf -- '- #%s: conflict stacking its blockers — %s (`.afk/%s-wt.err`)\n' \
        "$b" "${CONFLICT_FILES[$b]:-paths in the log}" "$b"
    done
    [[ -n "$INTEG_NOTES" ]] && printf -- '%s\n' "$INTEG_NOTES"
    (( BASE_RED )) && printf -- '- **the base (`%s`) was already red before the run** (`.afk/base-verify.txt`): a red ticket whose failure also appears there is not its own.\n' "$BASE_REF"
    printf -- '- gate: %s%s\n' "$VERIFY_CMD" \
      "$( [[ "$INTEGRATION_VERIFY_CMD" != "$VERIFY_CMD" ]] && echo " · integration: $INTEGRATION_VERIFY_CMD" )"
    # The same sentence as the summary, not its opposite (defect 36): on a repo without a
    # workflow, pointing the reviewer at "their CI" sends them looking for a verdict that
    # does not exist — and this is the file they open first.
    if (( ${#CI_NONE[@]} == ${#OK[@]} && ${#OK[@]} )); then
      printf -- '- no CI on this repo: the local gate is the only one that ran, including for the tickets marked ⚠ (gate REPLACED by their `Verify:` line).\n'
    else
      printf -- '- the tickets marked ⚠ had a local gate REPLACED by their `Verify:` line: only their CI ran the repo'"'"'s complete gate.\n'
    fi
    printf -- '- green on 1st attempt: %s/%s\n' "$FIRST_TRY" "$(( ${#OK[@]} + ${#KO[@]} ))"
    printf -- '- context: the session peak. It measures the SIZE of the work, not its quality —\n'
    printf -- '  a high peak on a well-scoped ticket stays green. To be read with the scope delivered.\n'
    printf -- '- model: the ones that actually ran. Several models WITHOUT a subagent = a fallback\n'
    printf -- '  (`FALLBACK_MODEL=%s`) kicked in, the wanted model was unavailable. With subagents,\n' "${FALLBACK_MODEL:-none}"
    printf -- '  they carry the model of their definition (`.claude/agents/*.md`) and not the ticket'"'"'s:\n'
    printf -- '  one extra model comes from them, and part of the cost too (defect 41).\n'
    printf -- '- cost: list price, cumulated over the ticket'"'"'s attempts, as reported by the session.\n'
    printf -- '- phases: install / session / gate, cumulated over the attempts. What "duration"\n'
    printf -- '  carries on top is the wait on a lock (`JOBS=%s`). The session is timed by afk,\n' "$JOBS"
    printf -- '  background subagents included — its own `duration_ms` misses them (defect 43).\n'

    # A ticket handed back to a human is reread today in a file. The session that
    # produced it still exists and its worktree is kept: we give what it takes to GET
    # BACK IN, and ask it what a log will never say — why it took that path.
    # Reds only: `claude --resume` looks for the session in the directory where it ran,
    # and a green ticket's worktree is thrown away.
    local sid resumable=0
    for t in "${TICKETS[@]}"; do
      [[ " ${KO[*]} ${PUSH_KO[*]} " == *" $t "* ]] || continue
      sid=$(sget "$t" session); [[ -n "$sid" ]] || continue
      (( resumable++ == 0 )) && printf '\nResume a session by hand:\n\n'
      printf -- '- #%s: `(cd %s/%s && claude --resume %s)`\n' \
        "$t" "${WORKTREE_DIR#$REPO_ROOT/}" "$t" "$sid"
    done

    printf '\nPer-ticket logs: `.afk/<n>.out` (orchestrator), `.afk/<n>-<attempt>.json` (session),\n'
    printf '`.afk/<n>-verify.txt` (gate), `.afk/<n>-ci.txt` (CI), `.afk/<n>-wt.err` (stacking of\n'
    printf 'its blockers'"'"' branches — the only log of a ticket that came out "conflict").\n'
  } > "$f"
  echo "  summary: .afk/summary.md"
}

# ─── The loop ─────────────────────────────────────────────────────────────────

if (( ${#ARGV[@]} )); then
  TICKETS=("${ARGV[@]}")
else
  # Explicit --limit: `gh issue list` caps at 30 WITHOUT saying so, and returns the most
  # RECENT ones. On a repo with more than 30 open tickets, the run therefore started on
  # an arbitrary slice, and the tickets that fell outside it showed up as "blockers open
  # outside the run" — a silent freeze, not an error.
  mapfile -t TICKETS < <(gh issue list --label "$LABEL" --state open --limit 500 \
    --json number -q '.[].number' | sort -n)
fi

(( ${#TICKETS[@]} == 0 )) && { echo "no ${LABEL} ticket."; exit 0; }

CI_FAILFAST=""; KNOWN_LABELS=""
mkdir -p "$AFK_DIR"; printf '*\n' > "$AFK_DIR/.gitignore"
# Transcripts pile up from one run to the next in the same folder: this marker is what
# limits the reading to this run's.
RUN_MARKER="$AFK_DIR/.runstart"; : > "$RUN_MARKER"

echo "${#TICKETS[@]} ticket(s): ${TICKETS[*]}"
echo "base: ${BASE_REF} → PR onto ${BASE_BRANCH}   labels: ${LABEL} → ${LABEL_REVIEW} / ${LABEL_KO}"
echo "verification: ${VERIFY_CMD}"
echo "model: ${MODEL:-claude default}${EFFORT:+ · effort ${EFFORT}}${FALLBACK_MODEL:+ · fallback ${FALLBACK_MODEL}}"
[[ "$INTEGRATION_VERIFY_CMD" != "$VERIFY_CMD" ]] &&
  echo "  · integration: ${INTEGRATION_VERIFY_CMD}"
echo -n "parallelism: ${JOBS} session(s)"
(( JOBS > 1 )) && [[ "$VERIFY_LOCK" == "1" ]] && echo -n "   verifications serialised (shared resources)"
echo
[[ "$CI_TIMEOUT" == "0" ]] && echo "CI: not consulted" || echo "CI: awaited at the end of the run (${CI_TIMEOUT})"

echo; echo "→ reading the ${#TICKETS[@]} tickets…"
plan_run

if (( ${#DROPPED[@]} )); then
  keep=()
  for t in "${TICKETS[@]}"; do
    [[ " ${DROPPED[*]} " == *" $t "* ]] || keep+=("$t")
  done
  TICKETS=(${keep[@]+"${keep[@]}"})
  (( ${#TICKETS[@]} == 0 )) && { echo; echo "nothing left to do."; exit 0; }
fi

if [[ "$DRY_RUN" == "1" ]]; then
  # The plan, without launching anything. The waves show exactly where parallelism is
  # possible and where the DAG forbids it.
  echo; echo "═══ Plan ═══"
  declare -A DELIVERED=()
  # Same question as deps_state: a blocker outside the run that already carries a branch
  # (open PR) is deliverable, we stack on it. Without this priming the plan announced
  # "frozen — undeliverable blocker" for what the run launches without blinking, and it
  # contradicted itself in the same output: it had just printed "blocker #N delivered
  # outside the run (open PR)". It is exactly when resuming an interrupted run — batch
  # half delivered — that the plan is read before relaunching (defect 44).
  for b in "${!BRANCH_OF[@]}"; do DELIVERED[$b]=1; done
  local_wave=1; remaining=("${TICKETS[@]}")
  while (( ${#remaining[@]} )); do
    wave=(); frozen=(); next=()
    for t in "${remaining[@]}"; do
      ready=1; froze=0
      [[ -n "${EXT[$t]}" ]] && froze=1
      for b in ${DEPS[$t]}; do [[ -n "${DELIVERED[$b]:-}" ]] || ready=0; done
      if   (( froze )); then frozen+=("$t")
      elif (( ready )); then wave+=("$t")
      else next+=("$t"); fi
    done
    for t in "${frozen[@]}"; do echo "  ⏸  #${t} frozen — blockers open outside the run: ${EXT[$t]}"; done
    (( ${#wave[@]} == 0 )) && { for t in "${next[@]}"; do echo "  ⏸  #${t} frozen — undeliverable blocker"; done; break; }
    echo "  wave ${local_wave} ($( (( ${#wave[@]} > 1 && JOBS > 1 )) && echo "parallel, ${JOBS} at a time" || echo "sequential" )):"
    for t in "${wave[@]}"; do
      # Same computation as launch(): the base, then what is left to merge on top.
      # The run's branches do not exist yet, so deepest_branch falls back to the last
      # one listed — that is the worst case, and the one to show.
      stack=(); for b in ${DEPS[$t]}; do stack+=("${BRANCH_OF[$b]:-feat/$b}"); done
      base="$BASE_REF"; absorb=()
      if (( ${#stack[@]} )); then
        base=$(deepest_branch "${stack[@]}")
        for b in "${stack[@]}"; do
          [[ "$b" == "$base" ]] && continue
          git merge-base --is-ancestor "$b" "$base" 2>/dev/null && continue
          absorb+=("$b")
        done
      fi
      printf '    #%-4s base %-14s %s\n' "$t" "$base" "${TITLE[$t]}"
      (( ${#absorb[@]} )) && printf '          absorbs: %s\n' "${absorb[*]}"
      [[ "${VERIFY[$t]}" != "$VERIFY_CMD" ]] && printf '          Verify: %s\n' "${VERIFY[$t]}"
      [[ "${TMO[$t]}"    != "$TIMEOUT"    ]] && printf '          Timeout: %s\n' "${TMO[$t]}"
      [[ "${MDL[$t]}"    != "$MODEL"      ]] && printf '          Model: %s\n' "${MDL[$t]}"
      [[ "${EFF[$t]}"    != "$EFFORT"     ]] && printf '          Effort: %s\n' "${EFF[$t]}"
      DELIVERED[$t]=1
    done
    remaining=("${next[@]}"); local_wave=$(( local_wave + 1 ))
  done
  echo; echo "(dry run — nothing launched)"
  exit 0
fi

setup_git_auth
git fetch -q origin "$BASE_BRANCH" || { echo "✗ cannot fetch origin/${BASE_BRANCH}"; exit 1; }
# The branches of blockers delivered outside the run: without this fetch, origin/<branch>
# may be absent or stale, and the worktree would start from a state that no longer exists.
(( ${#EXT_FETCH[@]} )) && { git fetch -q origin "${EXT_FETCH[@]}" ||
  echo "⚠  fetch of the out-of-run branches (${EXT_FETCH[*]}) incomplete — their dependants may fail"; }
[[ -n "$(git status --porcelain)" ]] &&
  echo "· main tree dirty — no effect: the script works in .afk/wt/, it does not touch it"
gh pr checks --help 2>&1 | grep -q -- '--fail-fast' && CI_FAILFAST="--fail-fast"

KNOWN_LABELS=$(gh label list --limit 200 --json name -q '.[].name' 2>/dev/null)
ensure_label "$LABEL_REVIEW" "Delivered by an agent, PR open, awaiting human review"
ensure_label "$LABEL_KO"     "Handed back to a human: the agent did not get there"

mkdir -p "$WORKTREE_DIR"
trap finish EXIT INT TERM

# ─── The base, once ───────────────────────────────────────────────────────────
# The gate only ever judges "base + ticket", and nothing separates the two terms: a red
# test pushed straight onto the base (so no PR, so no CI) fails the whole batch, each at
# its own expense. Eleven tickets diagnosed it eleven times, six burned a full second
# attempt, seven fixed the same file on their own side with seven different messages
# (defect 38). The gate already ran on the base — but only in the case where the session
# committed nothing. So we move it to the start of the run: it is the execution the
# integration pass already does at the end.
# A red does not stop the run: whoever launched it has gone. It is said in the header,
# in the summary and in `summary.md`, and a ticket red with a failure that also appears
# in `base-verify.txt` is not the ticket's fault.
BASE_RED=0
base_check() {
  local wt="$WORKTREE_DIR/_base"
  echo; echo "═══ Base (${BASE_REF}) ═══"
  git worktree remove --force "$wt" 2>/dev/null; git worktree prune; rm -rf "$wt"
  # Detached: no branch to clean up behind, we commit nothing here.
  git worktree add -q --detach "$wt" "$BASE_REF" 2>"$AFK_DIR/base-wt.err" || {
    echo "  ⚠  worktree impossible — base not verified: $(head -1 "$AFK_DIR/base-wt.err")"
    return 0; }
  seed_worktree "$wt" >/dev/null
  # `_base` as a ticket number: the base migrates like a worker, it must isolate itself
  # the same way (see `AFK_TICKET` in the worker).
  [[ -n "$SETUP_CMD" ]] && ( cd "$wt" && AFK_TICKET=_base AFK_WORKTREE="$wt" \
    locked install bash -c "$SETUP_CMD" ) > "$AFK_DIR/base-setup.log" 2>&1
  if ( cd "$wt" && locked verify bash -c "$VERIFY_CMD" ) > "$AFK_DIR/base-verify.txt" 2>&1; then
    echo "  ✓ green — a red ticket will really be its own"
  else
    BASE_RED=1
    echo "  ✗ RED BEFORE THE RUN — .afk/base-verify.txt"
    tail -n 10 "$AFK_DIR/base-verify.txt" | sed 's/^/     /'
    echo "  · the run continues anyway: every ticket is going to hit this failure, and"
    echo "    fixing the base is outside its scope. A red may not be its own."
  fi
  git worktree remove --force "$wt" 2>/dev/null; git worktree prune; rm -rf "$wt"
}
base_check

schedule
ci_phase
integration_check

# A ticket with a replaced local gate whose CI did not conclude was seen by NO complete
# gate, and a draft PR does not get merged. Both facts were printed, three lines apart,
# without ever being crossed: it was up to the reader to match two lists of numbers to
# notice that a "green" was not one.
GREEN=(); UNPROVEN=(); REDUCED=()
for t in "${OK[@]}"; do
  [[ "${VERIFY[$t]:-}" != "$VERIFY_CMD" ]] && REDUCED+=("$t")
  if   [[ " ${DRAFT[*]} " == *" $t "* ]]; then continue
  elif [[ " ${CI_UNKNOWN[*]} " == *" $t "* && "${VERIFY[$t]:-}" != "$VERIFY_CMD" ]]; then UNPROVEN+=("$t")
  else GREEN+=("$t"); fi
done

echo
echo "═══ Summary  ($(fmt_dur $SECONDS)) ═══"
(( BASE_RED )) &&
  echo "  base red BEFORE the run: a red ticket may not be its own — compare .afk/<n>-fail.txt with .afk/base-verify.txt"
echo "  green  (${#GREEN[@]}): ${GREEN[*]:-—}"
(( ${#UNPROVEN[@]} )) &&
  echo "  unproven green (${#UNPROVEN[@]}): ${UNPROVEN[*]}  → local gate replaced AND CI inconclusive: nothing ran the complete gate"
(( ${#DRAFT[@]} )) &&
  echo "  draft  (${#DRAFT[@]}): $(for t in "${DRAFT[@]}"; do printf '#%s (%s) ' "$t" "$(sget "$t" draft_why)"; done) → read before leaving draft"
(( ${#ABSORBED[@]} )) &&
  echo "  absorbed (${#ABSORBED[@]}): ${ABSORBED[*]}  → nothing to do, base already green: delivered by a predecessor, to close"
echo "  red    (${#KO[@]}): ${KO[*]:-—}  → moved to ${LABEL_KO}, worktrees kept in .afk/wt/"
(( ${#PUSH_KO[@]} )) && {
  echo "  push refused (${#PUSH_KO[@]}): ${PUSH_KO[*]}  → branch green and committed locally, no label changed:"
  for t in "${PUSH_KO[@]}"; do
    echo "     #${t}: $(head -n 3 "$AFK_DIR/$t-push.txt" 2>/dev/null | tr '\n' ' ')"
  done; }
echo "  frozen (${#SKIP[@]}): ${SKIP[*]:-—}  → blockers not lifted, relaunch after merge"
(( ${#CI_RED[@]} )) &&
  echo "  CI red (${#CI_RED[@]}): ${CI_RED[*]}  → moved back to ${LABEL_KO}"
(( ${#CI_UNKNOWN[@]} )) &&
  echo "  CI inconclusive (${#CI_UNKNOWN[@]}): ${CI_UNKNOWN[*]}"
# A single line for the whole run: on a repo without a workflow, saying it ticket by
# ticket teaches the fifteenth nothing the first did not.
(( ${#CI_NONE[@]} == ${#OK[@]} && ${#OK[@]} )) &&
  echo "  no CI on this repo: the local gate is the only one that ran$( (( ${#REDUCED[@]} )) && echo " — and it was REPLACED on ${REDUCED[*]}" )"
# A single "integration" line: the verdict already carries its scope, a second line of
# the same name right above read as two contradictory verdicts.
[[ "$INTEG_VERDICT" != "—" ]] &&
  echo "  integration: ${INTEG_VERDICT}$( (( ${#INTEG_CONFLICTS[@]} )) && echo "  → conflict on ${INTEG_CONFLICTS[*]}, to resolve by hand before merging" )"
(( ${#OK[@]} + ${#KO[@]} > 0 )) &&
  echo "  green on 1st attempt: ${FIRST_TRY}/$(( ${#OK[@]} + ${#KO[@]} ))"
write_summary
append_run_log

echo
echo "Below ~50% green on the first attempt, the problem is in /to-tickets, not here."
echo "100% green is no better if the gate verifies nothing: \"green\" means"
echo "\"it compiles\" until a ticket has its own Verify: line."
