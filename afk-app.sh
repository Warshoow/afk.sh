#!/usr/bin/env bash
# afk-app.sh — construire une app entière, vague après vague, sans se réveiller.
#
#   ./afk-app.sh              # jusqu'à 8 vagues, 1 ticket à la fois
#   ./afk-app.sh -w 4 -j 3    # 4 vagues au plus, 3 tickets en parallèle
#
# Prérequis : `/afk-spec` est passé (docs/spec.md, tag afk-spec, branche dev, .afk.env).
#
# Une vague = trois choses, dans cet ordre :
#   /afk-wave   session Claude — ouvre les tickets des critères non cochés
#   afk.sh      l'orchestrateur, sans LLM dedans, comme d'habitude
#   /afk-merge  session Claude — fait atterrir sur dev et coche ce qui passe
#
# LE FLUX DE CONTRÔLE EST MÉCANIQUE. Ce script ne lit jamais ce qu'une session
# raconte pour décider de continuer : il compte les cases cochées dans docs/spec.md
# et les tickets ouverts sur GitHub. Une session qui se déclare victorieuse ne peut
# donc pas prolonger la boucle, ni l'arrêter.
#
# set -e est absent pour la même raison que dans afk.sh : une vague qui échoue est un
# résultat, pas une raison d'arrêter.
set -uo pipefail

WAVES=8; JOBS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--waves) WAVES="$2"; shift 2 ;;
    -j|--jobs)  JOBS="$2";  shift 2 ;;
    -h|--help)  sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "option inconnue : $1"; exit 2 ;;
  esac
done

AFK_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LOG_DIR=".afk/app"

# `jval` vient d'afk.sh : sourcé avec AFK_LIB=1, il ne rend que les parseurs purs.
# Pas de seconde copie d'un lecteur de JSON dans ce dépôt.
AFK_LIB=1 source "$AFK_HOME/afk.sh"

# Le spec est le seul juge de la boucle. Il est écrit une fois par /afk-spec et taggé ;
# à partir de là, seules les cases ont le droit de bouger. Sans cette garde, celui qui
# écrit les critères et celui qui les remplit sont le même modèle.
spec_ok() {
  git rev-parse -q --verify afk-spec >/dev/null || { echo "✗ pas de tag afk-spec — lance /afk-spec"; return 1; }
  # Les cases sont neutralisées DES DEUX CÔTÉS : la version taggée en contient déjà une
  # cochée (le squelette fait passer A0), et une garde qui n'en neutralise qu'un côté
  # refuse de tourner dès la première vague.
  diff <(git show afk-spec:docs/spec.md | sed 's/\[x\]/[ ]/g') \
       <(sed 's/\[x\]/[ ]/g' docs/spec.md) >/dev/null && return 0
  echo "✗ docs/spec.md a dérivé (autre chose que des cases) — la boucle n'a plus de juge"
  git --no-pager diff afk-spec -- docs/spec.md | head -20
  return 1
}

# `grep -c` imprime 0 ET sort en 1 quand il ne trouve rien : un `|| echo 0` derrière
# rendrait "0\n0", et l'arithmétique de la boucle avec.
done_n()  { local n; n=$(grep -c '^- \[x\]' docs/spec.md 2>/dev/null); echo "${n:-0}"; }
todo_n()  { local n; n=$(grep -c '^- \[ \]' docs/spec.md 2>/dev/null); echo "${n:-0}"; }
ready_n() { gh issue list --state open --label ready-for-agent --limit 200 --json number -q '. | length' 2>/dev/null || echo 0; }

# Une session de pilotage. Courte par nature — elle lit, elle ouvre des tickets ou elle
# merge. Le timeout n'est pas là pour la brider mais pour qu'une session muette ne mange
# pas la nuit des vagues suivantes.
pilot() {
  local skill="$1" out="$2" rc sub
  timeout 45m claude -p "/$skill" \
    --permission-mode bypassPermissions --output-format json > "$out" 2>&1
  rc=$?
  sub=$(jval subtype < "$out")
  (( rc == 124 )) && { echo "  ✗ /$skill coupée au timeout"; return 1; }
  [[ "$sub" == "success" ]] || { echo "  ✗ /$skill : ${sub:-sortie illisible} — $out"; return 1; }
  echo "  · /$skill ok ($(jval total_cost_usd < "$out") USD)"
}

# ─── Garde-fous ───────────────────────────────────────────────────────────────
[[ -f docs/spec.md ]] || { echo "✗ pas de docs/spec.md — lance /afk-spec"; exit 1; }
[[ -f .afk.env     ]] || { echo "✗ pas de .afk.env — lance /afk-setup"; exit 1; }
command -v gh >/dev/null || { echo "✗ gh absent"; exit 1; }
git fetch -q origin && git switch -q dev && git pull -q ||
  { echo "✗ dev inaccessible — /afk-spec la crée"; exit 1; }
spec_ok || exit 1
mkdir -p "$LOG_DIR"

echo "app : $(todo_n) critère(s) restant(s) sur $(( $(done_n) + $(todo_n) ))   vagues : ${WAVES}   parallèle : ${JOBS}"

# ─── La boucle ────────────────────────────────────────────────────────────────
stall=0; stop=""
for (( w=1; w<=WAVES; w++ )); do
  before=$(done_n)
  echo; echo "═══ vague ${w}/${WAVES} — $(date '+%H:%M') — ${before} critère(s) cochés"

  pilot afk-wave "$LOG_DIR/w${w}-plan.json" || { stop="la session de découpe a échoué"; break; }

  n=$(ready_n)
  if (( n == 0 )); then stop="plus rien à ouvrir"; break; fi
  echo "  · ${n} ticket(s) ready-for-agent"

  "$AFK_HOME/afk.sh" -j "$JOBS"
  cp .afk/summary.md "$LOG_DIR/w${w}-summary.md" 2>/dev/null   # écrasé par la vague suivante

  pilot afk-merge "$LOG_DIR/w${w}-merge.json" || { stop="la session d'atterrissage a échoué"; break; }

  git pull -q
  spec_ok || { stop="le spec a dérivé pendant la vague"; break; }

  after=$(done_n)
  echo "  → ${after} critère(s) cochés (+$(( after - before )))"

  if (( $(todo_n) == 0 )); then stop="tous les critères sont cochés"; break; fi

  # Deux vagues d'affilée sans qu'un seul critère atterrisse : la boucle n'avance plus.
  # Une vague rouge sur trois est le régime normal, deux vagues stériles ne le sont pas.
  if (( after == before )); then
    stall=$(( stall + 1 ))
    (( stall >= 2 )) && { stop="deux vagues sans qu'un critère se coche"; break; }
    echo "  ⚠  vague stérile (${stall}/2)"
  else
    stall=0
  fi
done
[[ -z "$stop" ]] && stop="budget de ${WAVES} vagues épuisé"

echo; echo "═══ arrêt : ${stop}"
echo "critères : $(done_n)/$(( $(done_n) + $(todo_n) ))"
grep '^- \[ \]' docs/spec.md | head -5
gh issue list --state open --label ready-for-human --json number,title \
  -q '.[] | "  rendu à un humain : #\(.number) \(.title)"' 2>/dev/null
echo "traces : ${LOG_DIR}/"
