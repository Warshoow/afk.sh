#!/usr/bin/env bash
# afk.sh — enchaîne /implement sur les tickets ready-for-agent.
#
# Un ticket = une session Claude neuve = un worktree = une branche = une PR.
# L'orchestrateur ne contient aucun LLM : il ordonne, il lance, il vérifie, il
# pousse, il étiquette. Zéro interaction humaine par défaut.
#
# Suppose un repo configuré par /setup-matt-pocock-skills (tracker GitHub) et des
# tickets produits par /to-tickets — donc porteurs de leurs "Blocked by".
#
# Usage :
#   ./afk.sh                       # tous les tickets ready-for-agent, en série
#   ./afk.sh 43 48 49 50           # ceux-là
#   ./afk.sh -j 3 43 48 49 50      # en parallèle partout où le DAG le permet
#   ./afk.sh -n 43 48 49 50        # le plan : vagues, bases, piles, gelés
#
# En parallèle : les sessions Claude tournent en même temps, la vérification passe
# une par une (Postgres, ports et RAM sont partagés — voir VERIFY_LOCK).

set -uo pipefail

# ─── Parseurs ─────────────────────────────────────────────────────────────────
# Purs, en tête : ce sont eux qui décident de l'ordonnancement. Testés par check.sh.

# Vocabulaire de triage réel du repo, depuis la config du plugin.
label_for() {
  awk -F'|' -v role="$1" '$0 ~ "`"role"`" && NF>3 { gsub(/[ `]/,"",$3); print $3; exit }' \
    docs/agents/triage-labels.md 2>/dev/null
}

# Numéros cités dans la section "Blocked by" d'un corps de ticket, sur stdin.
blocked_refs() {
  awk '/^#+ *Blocked by/{f=1;next} /^#+ /{f=0} f||/[Bb]locked by:/' |
    grep -o '#[0-9]\+' | tr -d '#' || true   # "aucun bloqueur" n'est pas une erreur
}

# Vérification propre à un ticket : une ligne "Verify: <cmd>" dans son corps, sur
# stdin. Sans elle, la porte globale VERIFY_CMD s'applique. C'est la seule façon
# pour un ticket d'app de ne pas être gardé par un typecheck de monorepo entier,
# et pour un ticket d'aspect d'exiger autre chose qu'une compilation.
verify_override() {
  sed -n -E 's/^[[:space:]>*+-]*`?[Vv]erify`?[[:space:]]*:[[:space:]]*//p' |
    sed -E 's/`//g; s/[[:space:]]+$//' | awk 'NF{print; exit}'
}

# Budget de temps propre à un ticket : une ligne "Timeout: <durée>" dans son corps,
# sur stdin. Symétrique de "Verify:", et pour la même raison : TIMEOUT est global
# alors que la taille d'un ticket ne l'est pas — une refonte (migration + formule +
# gardes + tests + docs) ne rentre pas dans le gabarit d'un ticket moyen, et celui
# qui écrit le ticket est le seul à le savoir avant qu'il ne tourne.
# Format = celui de timeout(1) : un nombre, suffixe s/m/h/d optionnel. Une valeur
# d'une autre forme est ignorée plutôt que passée à timeout(1), qui refuserait alors
# de lancer la session — un ticket mal rédigé ne doit pas coûter un run.
timeout_override() {
  sed -n -E 's/^[[:space:]>*+-]*`?[Tt]imeout`?[[:space:]]*:[[:space:]]*//p' |
    sed -E 's/`//g; s/[[:space:]]+$//' | awk 'NF{print; exit}' |
    grep -Ex '[0-9]+(\.[0-9]+)?[smhd]?' || true   # absent ou mal formé : pas une erreur
}

# Base d'une PR empilée : parmi les branches des bloqueurs déjà livrés, celle qui
# contient déjà toutes les autres. L'ordre de listage de l'API n'est pas topologique
# — prendre la dernière ne marchait que par chance. Si aucune ne domine (frères
# indépendants) ou si une branche manque, on retombe sur la dernière.
# Les candidats ne sont plus tous des branches locales : une base peut être un ref
# distant (origin/<base>, ou la branche d'un bloqueur livré hors run), d'où le
# committish plutôt que refs/heads/.
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

# Contexte maximal atteint par une session, depuis son transcript JSONL sur stdin.
# Une session neuve garantit un départ propre, pas une arrivée propre : avec une
# fenêtre de 1M rien ne compacte, et la session grossit jusqu'à finir le ticket.
# C'est donc le thermomètre du découpage — un ticket qui frôle la fenêtre était trop
# gros, et ça se voit avant que la qualité ne se dégrade.
# Le contexte d'une requête = frais + écrit au cache + lu au cache ; on garde le max.
# Rien à parser en JSON : les trois clés sont cherchées telles quelles, le guillemet
# ouvrant suffit à distinguer "input_tokens" de "cache_read_input_tokens".
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

# Numéros pris deux fois. Reçoit des chemins sur stdin (les fichiers AJOUTÉS par les
# branches d'un run) et rend une ligne par collision : même répertoire, même préfixe
# numérique de tête, plusieurs fichiers différents.
#
# Ça n'a l'air de rien et c'est un angle mort entier : un ADR `0018-…`, une migration
# `1768621000034_…` — le numéro est un espace de noms PARTAGÉ, et chaque worktree part de
# la base sans voir ses voisins, donc chaque agent prend le numéro libre qu'il voit et il
# a raison. Les noms de fichiers diffèrent → git ne voit aucun conflit ; ça compile ; les
# tests passent. Aucune porte ne peut le dire, seule la combinaison des branches peut.
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
        printf "%s* dans %s : %s\n", kk[2], (kk[1] == "" ? "./" : kk[1]), g[k]
      }
    }' | sort
}

[[ -n "${AFK_LIB:-}" ]] && return 0   # sourcé par check.sh

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "pas un repo git"; exit 1; }

# ─── Arguments ────────────────────────────────────────────────────────────────

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \?//'
}

ARGV=()
while (( $# )); do
  case "$1" in
    -j|--jobs)    JOBS="$2"; shift 2 ;;
    --jobs=*)     JOBS="${1#*=}"; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "option inconnue : $1"; usage; exit 1 ;;
    *)            ARGV+=("$1"); shift ;;
  esac
done

# ─── Config du projet ─────────────────────────────────────────────────────────
# Les défauts ci-dessous sont taillés pour un monorepo pnpm. Un repo Python, PHP ou
# Rust n'a pas la même définition de "fini" — et même sur un repo npm, `npm test`
# ouvre souvent un watcher qui ne rend jamais la main (vitest sans `run`) : le ticket
# meurt alors sur TIMEOUT, pour une raison qui n'a rien à voir avec son contenu.
# Le projet déclare donc lui-même sa porte, dans un fichier versionné à côté de son
# code — là où vit la vraie définition de "fini", pas dans la ligne de commande.
# Sourcé APRÈS les arguments : la ligne de commande garde le dernier mot.
# Même surface de confiance que les lignes "Verify:" d'un ticket : c'est du shell du
# repo, exécuté tel quel.
[[ -f .afk.env ]] && { echo "· config du projet : .afk.env"; source ./.afk.env; }

# ─── Config ───────────────────────────────────────────────────────────────────

# Les skills mattpocock doivent exister DANS la session headless : même config dir
# que ta session interactive, sinon /implement n'est pas résolu. On prend le premier
# répertoire qui contient réellement le plugin, au lieu d'un défaut en dur : dans un
# devcontainer, le HOME du conteneur n'est pas celui où la config de l'hôte est montée
# ($HOME=/home/node, config sur /home/<user>/.claude-pro).
CLAUDE_CONFIG_CANDIDATES=("$HOME"/.claude-perso "$HOME"/.claude-pro "$HOME"/.claude /home/*/.claude-p*)
if [[ -z "${CLAUDE_CONFIG_DIR:-}" ]]; then
  for d in "${CLAUDE_CONFIG_CANDIDATES[@]}"; do
    [[ -d "$d/plugins/cache/mattpocock" ]] && { CLAUDE_CONFIG_DIR="$d"; break; }
  done
fi
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude-perso}"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"        # 1 essai + 1 reprise, en session neuve
TIMEOUT="${TIMEOUT:-45m}"                # garde-fou : borne un run (pas de --max-turns en 2.1.x)
                                         # surchargeable par ticket : ligne "Timeout:" du corps
CI_TIMEOUT="${CI_TIMEOUT:-15m}"          # attente de la CI ; 0 = ne pas consulter
INTEGRATION="${INTEGRATION:-1}"          # passe d'intégration des branches vertes en fin de run
CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-0}"  # 0 = jamais de pause. C'est un outil non surveillé.

# Un bloqueur livré à la main — PR ouverte, pas encore mergée — n'est ni "dans le run"
# ni "fermé" : il gelait ses dépendants jusqu'à son merge, alors que sa branche est
# poussée et lisible. On empile dessus comme sur un bloqueur livré par le run. La PR
# ciblera cette branche, pas BASE_BRANCH : c'est le prix, et c'est le même que pour
# n'importe quelle PR empilée.
STACK_ON_OPEN_PR="${STACK_ON_OPEN_PR:-1}"

# Un ticket déjà in-review a sa PR ouverte : le relancer en ouvrirait une seconde sur
# la même branche. Le listing par label ne peut pas les ramener, une liste explicite si.
ALLOW_REVIEW="${ALLOW_REVIEW:-0}"

# Parallélisme. Un ticket par worktree : deux agents dans le même arbre de travail
# se piétinent. Le DAG des bloqueurs est respecté — un ticket empilé attend le sien.
JOBS="${JOBS:-1}"
[[ "$JOBS" == "auto" ]] && { JOBS=$(( $(nproc 2>/dev/null || echo 4) / 4 )); (( JOBS < 1 )) && JOBS=1; (( JOBS > 4 )) && JOBS=4; }

# La vérification tient des ressources qu'on ne peut pas dupliquer : le Postgres de
# test, les ports, et la RAM d'un turbo typecheck. Les sessions Claude, elles, ne
# partagent rien. Donc : agents en parallèle, vérifications en file d'attente.
VERIFY_LOCK="${VERIFY_LOCK:-1}"

# La vérification. Externe à l'agent : c'est toi qui notes sa copie, pas lui.
VERIFY_CMD="${VERIFY_CMD:-pnpm typecheck && pnpm test && pnpm lint}"

# La porte de la passe d'intégration. Par défaut la même, mais séparable — parce que c'est
# le seul verdict du run qui doit être digne de confiance, et qu'un cache de build peut le
# rendre creux : un outil qui hache les fichiers SUIVIS PAR GIT ne voit pas les fichiers
# générés et gitignorés, donc un worktree qui ne les a pas produit la même empreinte que
# l'arbre principal qui les a → cache hit, logs rejoués, rien d'exécuté. La porte affiche
# un ✓ sans avoir compilé une ligne, et ce faux vert voyage d'un worktree à l'autre quand
# le cache est partagé. Un projet peut donc demander ici la forme non cachée
# (`turbo … --force`, `pytest -p no:cacheprovider`, …), qu'on ne veut pas payer à chaque
# ticket mais qu'on veut une fois, sur la combinaison.
INTEGRATION_VERIFY_CMD="${INTEGRATION_VERIFY_CMD:-$VERIFY_CMD}"

# Chemins qui comptent comme "décision capturée". Un monorepo multi-contextes range
# ses glossaires et ses ADR par app, pas seulement à la racine.
MEMORY_RE="${MEMORY_RE:-^(CONTEXT(-MAP)?\.md|(apps|packages)/[^/]+/CONTEXT\.md|docs/adr/|(apps|packages)/[^/]+/docs/adr/)}"

REPO_ROOT="$PWD"
AFK_DIR="$REPO_ROOT/.afk"                 # logs et worktrees, auto-ignorés
WORKTREE_DIR="${WORKTREE_DIR:-$AFK_DIR/wt}"
KEEP_WORKTREES="${KEEP_WORKTREES:-0}"    # les worktrees des échecs sont gardés d'office
DRY_RUN="${DRY_RUN:-0}"

# Un worktree neuf ne contient que les fichiers suivis. Les .env sont gitignorés et
# le backend ne démarre pas sans : sans ce semis, la vérification échoue dans un
# worktree pour une raison qui n'a rien à voir avec le ticket.
SEED_GLOBS="${SEED_GLOBS:-.env .env.local apps/*/.env apps/*/.env.local packages/*/.env}"

# Installer les dépendances du worktree. "auto" = déduit du lockfile.
SETUP_CMD="${SETUP_CMD:-auto}"
if [[ "$SETUP_CMD" == "auto" ]]; then
  if   [[ -f pnpm-lock.yaml   ]]; then SETUP_CMD="pnpm install --frozen-lockfile --prefer-offline"
  elif [[ -f package-lock.json ]]; then SETUP_CMD="npm ci"
  elif [[ -f yarn.lock        ]]; then SETUP_CMD="yarn install --frozen-lockfile"
  else SETUP_CMD=""; fi
fi

LABEL="${LABEL:-$(label_for ready-for-agent)}";  LABEL="${LABEL:-ready-for-agent}"
LABEL_KO="${LABEL_KO:-$(label_for ready-for-human)}"; LABEL_KO="${LABEL_KO:-ready-for-human}"
# Livré, PR ouverte, en attente d'un humain. Sans cet état, un ticket dont la PR est
# refusée perd son label et n'est plus repris par personne.
LABEL_REVIEW="${LABEL_REVIEW:-$(label_for in-review)}"; LABEL_REVIEW="${LABEL_REVIEW:-in-review}"

BASE_BRANCH="${BASE_BRANCH:-$(git symbolic-ref -q --short refs/remotes/origin/HEAD | cut -d/ -f2-)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
# Les worktrees partent du ref DISTANT, jamais de la branche locale : l'arbre
# principal n'est ni checkout, ni pull, ni reset. Tu peux continuer à bosser
# dedans, sur la branche que tu veux, pendant qu'un run tourne.
# BASE_BRANCH reste le nom de branche — c'est la cible des PR.
BASE_REF="origin/${BASE_BRANCH}"

# ─── Garde-fous ───────────────────────────────────────────────────────────────

for bin in claude gh git timeout; do
  command -v "$bin" >/dev/null || { echo "manque : $bin"; exit 1; }
done

[[ -f docs/agents/issue-tracker.md ]] || {
  echo "docs/agents/issue-tracker.md absent — lance /setup-matt-pocock-skills d'abord"; exit 1; }
grep -qi 'github' docs/agents/issue-tracker.md || {
  echo "tracker non-GitHub — ce script parle gh(1)"; exit 1; }
[[ -d "$CLAUDE_CONFIG_DIR/plugins/cache/mattpocock" ]] || {
  echo "plugin mattpocock introuvable dans $CLAUDE_CONFIG_DIR — /implement ne sera pas résolu"
  echo "  cherché dans : ${CLAUDE_CONFIG_CANDIDATES[*]}"
  echo "  force-le : CLAUDE_CONFIG_DIR=/chemin/vers/.claude-xxx $0 …"; exit 1; }

# Mémoire de projet : racine mono-contexte, ou carte + contextes par app.
memory_present() {
  [[ -f CONTEXT.md || -f CONTEXT-MAP.md || -d docs/adr ]] && return 0
  compgen -G '*/*/CONTEXT.md' >/dev/null
}
memory_present || echo "⚠  ni CONTEXT.md, ni CONTEXT-MAP.md, ni docs/adr/ — les agents n'auront aucune mémoire de projet"

(( JOBS > 1 )) && [[ "$VERIFY_LOCK" == "1" ]] && ! command -v flock >/dev/null && {
  echo "⚠  flock absent : les vérifications tourneront en parallèle (Postgres et ports partagés)"; }

# ─── Utilitaires ──────────────────────────────────────────────────────────────

fmt_dur() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

# Statut d'un ticket : le worker tourne dans un sous-shell, il ne peut rien écrire
# dans les tableaux du parent. Il dépose des lignes clé=valeur, le parent les relit.
sget() { grep -E "^$2=" "$AFK_DIR/$1.status" 2>/dev/null | tail -1 | cut -d= -f2-; }

# Sérialise une commande derrière un verrou nommé, si on est en parallèle.
locked() {
  local name="$1"; shift
  if (( JOBS > 1 )) && [[ "$VERIFY_LOCK" == "1" ]] && command -v flock >/dev/null; then
    flock "$AFK_DIR/$name.lock" "$@"
  else
    "$@"
  fi
}

# ─── Git sans clavier ─────────────────────────────────────────────────────────
# Le remote est en SSH, la clé porte une passphrase, et aucun ssh-agent ne tourne
# dans le conteneur : chaque pull et chaque push réclamaient le clavier — dans un
# outil qui veut dire "away from keyboard". Pire, en détaché le push dormait sans
# rien afficher, indiscernable d'un ticket qui prend du temps.
# On réécrit github.com en HTTPS pour la durée du run et on sert le token gh, déjà
# authentifié et sans passphrase, via son propre credential helper. Rien n'est écrit
# dans .git/config : le token ne touche jamais le disque.
setup_git_auth() {
  gh auth token >/dev/null 2>&1 || {
    echo "⚠  pas de token gh (gh auth login) — git restera en SSH et pourra réclamer une passphrase"
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
# Un --add-label sur un label inexistant échoue. Avalée, l'erreur faisait perdre
# ready-for-agent à un ticket abandonné sans rien lui donner en échange : invisible
# de la requête de l'orchestrateur ET de celle d'un humain.

ensure_label() {
  local name="$1" desc="$2"
  grep -qx -- "$name" <<<"$KNOWN_LABELS" && return 0
  if gh label create "$name" --description "$desc" >/dev/null 2>&1; then
    echo "  · label ${name} créé"
    KNOWN_LABELS+=$'\n'"$name"
  else
    echo "⚠  label ${name} absent et non créable — l'étiquetage échouera"
  fi
}

relabel() {   # ticket, label retiré, label ajouté
  local t="$1" old="$2" new="$3" err
  err=$(gh issue edit "$t" --remove-label "$old" --add-label "$new" 2>&1 >/dev/null) ||
    echo "  ⚠  étiquetage #${t} (${old} → ${new}) a échoué : ${err}"
}

# ─── Le prompt ────────────────────────────────────────────────────────────────
# Court par construction. Si un ticket a besoin de plus pour être compris seul,
# c'est le découpage qui est mauvais, pas le prompt qui est trop maigre.

build_prompt() {
  local ticket="$1" attempt="$2" verify="$3"

  cat <<EOF
/implement le ticket GitHub #${ticket}.

Session neuve, aucun historique.

- Lis le ticket : gh issue view ${ticket} --comments. Il fait autorité — tu ne
  modifies pas ses critères d'acceptation pour les faire passer.
- Le repo est configuré par /setup-matt-pocock-skills : CLAUDE.md, docs/agents/*.md,
  CONTEXT-MAP.md, les CONTEXT.md de chaque contexte et les ADR (docs/adr/ et
  <contexte>/docs/adr/) sont la mémoire du projet. Tu t'y conformes.
- Tu restes dans le périmètre du ticket. Aucun fichier hors sujet.
- Fini = cette commande passe au vert : ${verify}
- Si tenir le périmètre rend cette commande inatteignable (contrat typé qui traverse
  les apps, par exemple), fais le strict minimum hors périmètre pour la rendre verte
  et dis-le dans une ADR : c'est le découpage du ticket qui était faux, pas toi.
- Toute décision non triviale prise en route (architecture, convention, contrainte
  découverte, dette assumée) va dans un CONTEXT.md ou une ADR, AVANT de sortir.
  La session suivante ne saura rien de ce run.
- Tu commit sur la branche courante, déjà créée. Tu ne push pas, tu n'ouvres pas
  de PR, tu ne touches pas aux labels : c'est le job de l'orchestrateur.
- D'autres tickets tournent peut-être en parallèle dans d'autres worktrees. Tu ne
  regardes qu'ici, tu ne touches à aucune autre branche.
EOF

  if [[ "$attempt" -gt 1 ]]; then
    cat <<EOF

--- REPRISE (essai ${attempt}) ---
Une tentative précédente a échoué à la vérification. Sortie de l'échec :

$(tail -n 60 "${AFK_DIR}/${ticket}-fail.txt" 2>/dev/null || echo "(indisponible)")

Son code est déjà commité sur la branche. Corrige-le.
EOF
  fi
}

# ─── Plan ─────────────────────────────────────────────────────────────────────
# Une passe de lecture avant tout lancement : métadonnées en cache (le worker n'a
# plus besoin de l'API), bloqueurs classés en "dans ce run" et "dehors et ouvert".

declare -A DEPS=() EXT=() TITLE=() VERIFY=() TMO=()
EXT_FETCH=(); DROPPED=()

in_run() { local n="$1" t; for t in "${TICKETS[@]}"; do [[ "$t" == "$n" ]] && return 0; done; return 1; }

# Branche d'une PR ouverte qui livre ce ticket, si elle existe. On cherche d'abord
# la convention que l'orchestrateur impose lui-même (feat/<n>), puis, pour une
# branche nommée autrement, une PR ouverte dont le corps ferme ce ticket.
open_pr_branch() {
  local b="$1" br
  [[ "$STACK_ON_OPEN_PR" == "1" ]] || return 0
  # `-q '.[0].x'` sur une liste vide imprime "null" : sans le `// empty`, un bloqueur
  # sans PR donnerait la base "origin/null".
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
    body=$(gh issue view "$t" --json body -q .body 2>/dev/null) || { echo "✗ #${t} introuvable"; exit 1; }
    TITLE[$t]=$(gh issue view "$t" --json title -q .title 2>/dev/null)
    printf '%s' "$body"          > "$AFK_DIR/$t.body"
    printf '%s' "${TITLE[$t]}"   > "$AFK_DIR/$t.title"
    gh issue view "$t" --json labels -q '.labels[].name' 2>/dev/null | tr '\n' ' ' > "$AFK_DIR/$t.labels"

    VERIFY[$t]=$(verify_override <<<"$body"); VERIFY[$t]="${VERIFY[$t]:-$VERIFY_CMD}"
    printf '%s' "${VERIFY[$t]}"  > "$AFK_DIR/$t.verify"
    TMO[$t]=$(timeout_override <<<"$body"); TMO[$t]="${TMO[$t]:-$TIMEOUT}"
    printf '%s' "${TMO[$t]}"     > "$AFK_DIR/$t.timeout"

    # Déjà livré, PR ouverte : le relancer ouvrirait une seconde PR sur la même
    # branche. Le retirer de la liste vaut mieux que de le découvrir au gh pr create.
    if [[ "$ALLOW_REVIEW" != "1" && " $(cat "$AFK_DIR/$t.labels") " == *" $LABEL_REVIEW "* ]]; then
      echo "  ⏭  #${t} est ${LABEL_REVIEW} — ignoré (ALLOW_REVIEW=1 pour forcer)"
      DROPPED+=("$t"); continue
    fi

    # Dépendances natives GitHub d'abord ; sinon la section "Blocked by" du corps.
    local raw
    raw=$(gh api "repos/{owner}/{repo}/issues/$t/dependencies/blocked_by" --jq '.[].number' 2>/dev/null)
    [[ -z "$raw" ]] && raw=$(blocked_refs <<<"$body")

    deps=""; ext=""
    for b in $raw; do
      if in_run "$b"; then deps+="$b "; continue; fi
      [[ "$(gh issue view "$b" --json state -q .state 2>/dev/null)" == "OPEN" ]] || continue
      # Ouvert et hors run. S'il a une PR, sa branche est une base valable : le geler
      # jusqu'au merge, c'est refuser d'empiler sur du travail déjà poussé.
      pb=$(open_pr_branch "$b")
      if [[ -n "$pb" ]]; then
        deps+="$b "; BRANCH_OF[$b]="origin/$pb"; EXT_FETCH+=("$pb")
        echo "  · #${t} : bloqueur #${b} livré hors run (PR ouverte) → base origin/${pb}"
      else
        ext+="$b "
      fi
    done
    DEPS[$t]="$deps"; EXT[$t]="$ext"

    # Une branche ne peut être checkout que dans un seul worktree. Si tu bosses
    # justement sur feat/<t>, le worktree du ticket est impossible : mieux vaut
    # l'apprendre maintenant que sur une erreur de git au milieu du run.
    local held
    held=$(git worktree list --porcelain |
      awk -v b="refs/heads/feat/$t" '$1=="worktree"{p=$2} $1=="branch"&&$2==b{print p}')
    [[ -n "$held" && "$held" != "$WORKTREE_DIR/$t" ]] &&
      echo "  ⚠  #${t} : feat/${t} est déjà checkout dans ${held} — libère la branche, sinon ce ticket échouera"
  done
}

# ─── Worktree ─────────────────────────────────────────────────────────────────
# Un ticket = un worktree. C'est ce qui rend le parallèle possible sans que deux
# agents se piétinent, et ça libère l'arbre principal : plus de git reset --hard
# entre deux tickets, plus de contamination.

seed_worktree() {
  local wt="$1" f n=0
  for f in $SEED_GLOBS; do
    [[ -f "$f" ]] || continue
    mkdir -p "$wt/$(dirname "$f")" && cp -p "$f" "$wt/$f" && n=$(( n + 1 ))
  done
  echo "$n"
}

make_worktree() {   # ticket, base, branches à absorber… → chemin sur stdout
  local ticket="$1" base="$2"; shift 2
  local wt="$WORKTREE_DIR/$ticket" branch="feat/$ticket" extra

  git worktree remove --force "$wt" 2>/dev/null
  git worktree prune
  rm -rf "$wt"
  git worktree add -q -B "$branch" "$wt" "$base" 2>"$AFK_DIR/$ticket-wt.err" || return 1
  for extra in "$@"; do
    git -C "$wt" merge -q --no-edit "$extra" || { git -C "$wt" merge --abort; return 2; }
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

# ─── Sortie ───────────────────────────────────────────────────────────────────
# drop_worktree ne tournait que dans reap, donc dans la boucle de l'orchestrateur :
# tuer celui-ci entre la sortie d'un worker et sa récolte laissait le worktree en
# place, feat/<n> checkout dedans. Un outil qui tourne des heures se fait interrompre.
# Ici on tue la descendance (le worker est un sous-shell, claude et pnpm sont
# dessous : tuer le sous-shell seul les laisse orphelins et vivants), puis on récolte
# les worktrees des tickets qui n'ont plus rien à raconter.

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
    echo; echo "⚠  interruption — ${#PID[@]} session(s) en cours tuée(s) : ${!PID[*]}"
    for t in "${!PID[@]}"; do kill_tree "${PID[$t]}"; done
    sleep 1
    for t in "${!PID[@]}"; do kill -KILL "${PID[$t]}" 2>/dev/null; done
  fi

  # Un ticket vert (ou absorbé) n'a plus besoin de son worktree ; un rouge le garde,
  # c'est là qu'on va lire ce qui s'est passé. Un ticket interrompu compte comme rouge.
  if (( ${#TICKETS[@]} )); then
    for t in "${TICKETS[@]}"; do
      res=$(sget "$t" result)
      [[ "$res" == "ok" || "$res" == "absorbed" ]] && drop_worktree "$t"
    done
  fi
  git worktree prune 2>/dev/null
  exit $rc
}

# ─── Un ticket ────────────────────────────────────────────────────────────────
# Tourne dans un sous-shell, cwd = son worktree. Écrit son verdict dans
# $AFK_DIR/<t>.status ; n'écrit jamais dans les tableaux du parent.

worker() {
  local ticket="$1" base="$2" wt="$3"
  local branch="feat/$ticket" sf="$AFK_DIR/$ticket.status"
  local title labels verify tmo head0 rc crashed netted attempt
  local suspect pr_url pr_num pr_body

  st() { printf '%s\n' "$*" >> "$sf"; }
  : > "$sf"

  title=$(cat "$AFK_DIR/$ticket.title")
  labels=$(cat "$AFK_DIR/$ticket.labels")
  verify=$(cat "$AFK_DIR/$ticket.verify")
  tmo=$(cat "$AFK_DIR/$ticket.timeout" 2>/dev/null); tmo="${tmo:-$TIMEOUT}"
  st "result=ko"; st "branch=$branch"; st "base=$base"

  echo "  worktree    : ${wt#$REPO_ROOT/}"
  echo "  base        : ${base}"
  [[ "$verify" != "$VERIFY_CMD" ]] && echo "  vérification: ${verify}   (Verify: du ticket)"
  [[ "$tmo" != "$TIMEOUT" ]] && echo "  budget      : ${tmo}   (Timeout: du ticket)"
  local seeded; seeded=$(cat "$AFK_DIR/$ticket-seed.n" 2>/dev/null || echo 0)
  (( seeded )) && echo "  semé        : ${seeded} fichier(s) ignoré(s) recopié(s) depuis l'arbre principal"

  cd "$wt" || { echo "  ✗ worktree inaccessible"; return; }

  if [[ -n "$SETUP_CMD" ]]; then
    echo "  → dépendances (${SETUP_CMD})"
    # `AFK_TICKET` / `AFK_WORKTREE` sont exportés pour que `SETUP_CMD` puisse ISOLER ce
    # worktree de ses voisins. Le besoin est venu d'un vrai dégât (défaut 17) : plusieurs
    # worktrees partageaient une base de test fixée en dur dans un `.env.test` versionné,
    # donc chaque `migrate()`/`rollback()` d'un voisin cassait la suite d'ici — et le ticket
    # courant était noté rouge pour la migration d'un autre.
    #
    # C'est le projet qui sait de quoi il doit s'isoler (une base, un port, un bucket), pas
    # afk : il enchaîne son propre script devant `SETUP_CMD` dans son `.afk.env` et lit ces
    # deux variables. `SETUP_CMD` tourne déjà dans le worktree et sous le verrou `install`,
    # donc sérialisé — deux créations de base ne se croisent pas.
    if ! AFK_TICKET="$ticket" AFK_WORKTREE="$wt" \
         locked install bash -c "$SETUP_CMD" > "$AFK_DIR/$ticket-setup.log" 2>&1; then
      echo "  ✗ installation des dépendances échouée — ${AFK_DIR##*/}/${ticket}-setup.log"
      st "result=ko"; st "reason=setup"; return
    fi
  fi

  head0=$(git rev-parse HEAD)

  for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
    echo "  → run ${attempt}/${MAX_ATTEMPTS} (session neuve)"
    st "attempt=$attempt"

    # Jamais --resume : reprendre une session qui vient d'échouer, c'est repartir
    # du contexte pollué qui a échoué.
    timeout "$tmo" claude -p "$(build_prompt "$ticket" "$attempt" "$verify")" \
      --permission-mode bypassPermissions \
      > "$AFK_DIR/$ticket-$attempt.log" 2>&1
    rc=$?; crashed=0; netted=0
    (( rc == 124 )) && { echo "  ⚠  timeout ${tmo} — le ticket peut porter sa propre ligne \"Timeout:\""; crashed=1; }
    (( rc != 0 && rc != 124 )) && {
      echo "  ⚠  claude a rendu ${rc} — session terminée anormalement, voir ${AFK_DIR##*/}/${ticket}-${attempt}.log"
      crashed=1; }

    # Filet : /implement doit commiter, mais on ne perd pas le travail s'il oublie.
    # Le message vient du ticket, pas d'un "wip" générique : c'est lui que la base
    # garderait quand le filet produit le seul commit du lot.
    [[ -n "$(git status --porcelain)" ]] && {
      echo "  ⚠  agent n'a pas commité — je commit"
      local type=feat; grep -qw bug <<<"$labels" && type=fix
      git add -A && git commit -qm "${type}(#${ticket}): ${title}"
      netted=1; }

    if [[ "$(git rev-parse HEAD)" == "$head0" ]]; then
      # "L'agent a échoué" et "il n'y avait plus rien à faire" sortaient tous les deux
      # en "aucun commit" : un ticket vidé par son prédécesseur brûlait ses deux essais
      # puis partait en ready-for-human, pour une raison fausse. La base est déjà là et
      # la porte tourne déjà — on la passe sur la base, et elle tranche entre les deux.
      echo "  · aucun commit — je passe la porte sur la base pour trancher"
      if locked verify bash -c "$verify" > "$AFK_DIR/$ticket-verify.txt" 2>&1; then
        echo "  ≡ absorbé — rien à faire et la base est verte : déjà livré par un prédécesseur"
        st "result=absorbed"; st "base_ref=$base"
        relabel "$ticket" "$LABEL" "$LABEL_REVIEW"
        gh issue comment "$ticket" --body "$(printf '> *Généré par une session agent AFK.*\n\nSession sortie sans aucun commit, **et** la porte (`%s`) est déjà verte sur `%s` : le contenu de ce ticket semble avoir été livré par un prédécesseur. Aucune PR ouverte, rien à revoir — vérifier puis fermer.' \
          "$verify" "${base#origin/}")" >/dev/null 2>&1
        return
      fi
      echo "  ✗ aucun commit — l'agent n'a rien produit (et la base n'est pas verte)"
      { printf 'aucun commit produit (rc=%s). Porte sur la base :\n\n' "$rc"
        tail -n 40 "$AFK_DIR/$ticket-verify.txt"; } > "$AFK_DIR/$ticket-fail.txt"
      continue
    fi

    echo "  → vérification"
    if locked verify bash -c "$verify" > "$AFK_DIR/$ticket-verify.txt" 2>&1; then
      git diff --name-only "$head0" | grep -qE "$MEMORY_RE" ||
        echo "  ⚠  aucun CONTEXT.md ni ADR touché — décisions non capturées, relire de près"

      # Une session plantée passe la vérification exactement comme une session saine :
      # typecheck et lint ne savent pas ce qui manque. Le travail n'est pas jeté, mais
      # il sort en draft et ne compte pas comme un vert au premier essai.
      suspect=$(( crashed || netted ))
      pr_body="Closes #${ticket}"$'\n\n'"Vérifié localement par afk : \`${verify}\`"
      # Le périmètre d'un ticket est une PRÉDICTION : un ticket étiqueté sur une app peut
      # très bien en toucher deux (une clé partagée emporte tout ce qui indexe dessus), et
      # sa ligne `Verify:` a été taillée avant qu'on le sache. Quand la porte locale est
      # réduite, c'est la CI qui est la seule porte complète — le relecteur doit le lire
      # sur la PR, pas le déduire du corps du ticket.
      [[ "$verify" != "$VERIFY_CMD" ]] && pr_body+=$'\n\n'"> ⚠ **Porte locale réduite** par la ligne \`Verify:\` du ticket. La porte complète du dépôt est \`${VERIFY_CMD}\` : ce qu'elle couvre en plus n'a été vérifié QUE par la CI de cette PR." 
      (( crashed )) && pr_body+=$'\n\n'"> ⚠ **La session agent s'est terminée anormalement** (code ${rc}). Le travail présent passe la vérification, mais rien ne garantit qu'il soit complet — d'où le draft. Log : \`.afk/${ticket}-${attempt}.log\`."
      (( netted ))  && pr_body+=$'\n\n'"> ⚠ L'agent n'a pas commité lui-même : l'orchestrateur a rattrapé l'arbre de travail."

      if ! git push -qu origin "$branch" 2>"$AFK_DIR/$ticket-push.txt"; then
        echo "  ✗ push refusé — ${AFK_DIR##*/}/${ticket}-push.txt"
        sed 's/^/     /' "$AFK_DIR/$ticket-push.txt" | head -n 5
        cp "$AFK_DIR/$ticket-push.txt" "$AFK_DIR/$ticket-fail.txt"
        st "result=ko"; st "reason=push"; return
      fi

      local draft=(); (( suspect )) && draft=(--draft)
      pr_url=$(gh pr create --base "${base#origin/}" --head "$branch" "${draft[@]}" \
        --title "$title" --body "$pr_body") || { echo "  ✗ gh pr create a échoué"; st "result=ko"; st "reason=pr"; return; }
      pr_num="${pr_url##*/}"
      relabel "$ticket" "$LABEL" "$LABEL_REVIEW"

      st "result=ok"; st "pr=$pr_num"; st "draft=$suspect"
      if (( suspect )); then
        echo "  ✓ vert (essai ${attempt}) — PR #${pr_num} en DRAFT sur ${base#origin/}"
        echo "     ⚠  session anormale : relire avant de sortir du draft"
      else
        echo "  ✓ vert (essai ${attempt}) — PR #${pr_num} sur ${base#origin/}"
      fi
      return
    fi

    cp "$AFK_DIR/$ticket-verify.txt" "$AFK_DIR/$ticket-fail.txt"
    echo "  ✗ rouge"
    tail -n 8 "$AFK_DIR/$ticket-fail.txt" | sed 's/^/     /'
  done

  echo "  ✗ abandonné après ${MAX_ATTEMPTS} essais → ${AFK_DIR##*/}/${ticket}-fail.txt"
  st "result=ko"; st "reason=verify"
  relabel "$ticket" "$LABEL" "$LABEL_KO"
  gh issue comment "$ticket" --body "$(printf '> *Généré par une session agent AFK.*\n\n%d tentatives, vérification toujours rouge (`%s`). Branche `%s` (non poussée). Dernière sortie :\n\n```\n%s\n```' \
    "$MAX_ATTEMPTS" "$verify" "$branch" "$(tail -n 40 "$AFK_DIR/$ticket-fail.txt")")" >/dev/null 2>&1
}

# ─── Ordonnanceur ─────────────────────────────────────────────────────────────
# Lance jusqu'à JOBS tickets à la fois, dans l'ordre donné, en ne démarrant que
# ceux dont tous les bloqueurs de ce run sont déjà verts. Un bloqueur rouge gèle
# ses dépendants : leur base n'existe pas.

declare -A BRANCH_OF=() PID=() START=() WT=()
OK=(); KO=(); SKIP=(); DRAFT=(); ABSORBED=(); FIRST_TRY=0

deps_state() {   # 0 = prêt, 1 = attendre, 2 = gelé
  local t="$1" b state=0
  [[ -n "${EXT[$t]}" ]] && return 2
  for b in ${DEPS[$t]}; do
    if   [[ -n "${BRANCH_OF[$b]:-}" ]]; then continue
    elif [[ " ${KO[*]} ${SKIP[*]} " == *" $b "* ]]; then return 2
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
      git merge-base --is-ancestor "$b" "$base" 2>/dev/null && continue  # déjà dedans
      rest+=("$b")
    done
    stack=("${rest[@]}")
  fi

  wt=$(make_worktree "$t" "$base" "${stack[@]}"); rc=$?
  if (( rc == 2 )); then
    echo "  ⏸  #${t} : conflit entre bloqueurs — à faire à la main"
    SKIP+=("$t"); return
  elif (( rc != 0 )); then
    echo "  ✗ #${t} : worktree impossible — $(cat "$AFK_DIR/$t-wt.err" 2>/dev/null | head -1)"
    KO+=("$t"); return
  fi

  WT[$t]="$wt"; START[$t]=$SECONDS
  if (( JOBS == 1 )); then
    echo; echo "═══ #${t} — ${TITLE[$t]} ═══"
    ( worker "$t" "$base" "$wt" 2>&1 | tee "$AFK_DIR/$t.out" ) &
  else
    echo "  ▸ #${t} démarré  (base ${base}$( (( ${#stack[@]} )) && echo ", absorbe ${stack[*]}" ))"
    ( worker "$t" "$base" "$wt" > "$AFK_DIR/$t.out" 2>&1 ) &
  fi
  PID[$t]=$!
}

reap() {   # récolte les tickets finis ; renvoie 0 si au moins un a fini
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
    else
      echo "  ⏱  $(fmt_dur "$dur")"
    fi

    if [[ "$res" == "ok" ]]; then
      OK+=("$t"); BRANCH_OF[$t]=$(sget "$t" branch)
      if [[ "$(sget "$t" draft)" == "1" ]]; then DRAFT+=("$t")
      elif [[ "$(sget "$t" attempt)" == "1" ]]; then FIRST_TRY=$(( FIRST_TRY + 1 )); fi
      drop_worktree "$t"
    elif [[ "$res" == "absorbed" ]]; then
      # Rien à livrer, donc pas de branche à lui : ses dépendants s'empilent sur la
      # base qu'il a lui-même utilisée, sinon ils gèleraient derrière un faux échec.
      ABSORBED+=("$t"); BRANCH_OF[$t]=$(sget "$t" base_ref)
      drop_worktree "$t"; git branch -qD "feat/$t" 2>/dev/null
    else
      KO+=("$t")   # worktree gardé : c'est là qu'on va lire ce qui s'est passé
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
             echo "  ⏸  #${t} gelé — bloqueurs ouverts hors run : ${EXT[$t]% }"
           else
             echo "  ⏸  #${t} gelé — un bloqueur du run n'a pas été livré"
           fi
           SKIP+=("$t"); progress=1 ;;
      esac
    done
    todo=("${todo[@]}")   # recompacte

    if (( ${#PID[@]} == 0 )); then
      (( progress )) && continue
      for t in "${todo[@]}"; do
        echo "  ⏸  #${t} gelé — cycle de dépendances ou bloqueur non livrable"
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
        echo "  …  en cours : ${line}"
      fi
    done
  done
}

# ─── CI du repo ───────────────────────────────────────────────────────────────
# VERIFY_CMD tourne en local. Sans ce garde-fou, un ticket peut être livré, étiqueté
# et mergé alors que la CI du repo n'a jamais passé dessus — et c'est arrivé sur cinq
# tickets d'affilée, runner bloqué, sans que rien ne le signale.
# En fin de run, pas dans le worker : attendre 15 minutes de CI immobiliserait un
# slot de parallélisme pour du polling.

CI_RED=(); CI_UNKNOWN=()

ci_phase() {
  (( ${#OK[@]} )) || return 0
  [[ "$CI_TIMEOUT" == "0" ]] && return 0
  echo; echo "═══ CI (${#OK[@]} PR, timeout ${CI_TIMEOUT}) ═══"

  local t pr pids=()
  for t in "${OK[@]}"; do
    pr=$(sget "$t" pr)
    ( timeout "$CI_TIMEOUT" gh pr checks "$pr" --watch $CI_FAILFAST > "$AFK_DIR/$t-ci.txt" 2>&1
      echo "$?" > "$AFK_DIR/$t-ci.rc" ) &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null

  for t in "${OK[@]}"; do
    pr=$(sget "$t" pr); local rc; rc=$(cat "$AFK_DIR/$t-ci.rc" 2>/dev/null || echo 1)
    case "$rc" in
      0)   echo "  ✓ #${t} (PR #${pr}) CI verte" ;;
      124) echo "  ⚠  #${t} (PR #${pr}) CI toujours en cours après ${CI_TIMEOUT} — non concluant"
           CI_UNKNOWN+=("$t") ;;
      *)   if grep -qi 'no checks' "$AFK_DIR/$t-ci.txt" 2>/dev/null; then
             echo "  ⚠  #${t} (PR #${pr}) aucune CI déclarée"; CI_UNKNOWN+=("$t")
           else
             echo "  ✗ #${t} (PR #${pr}) CI rouge"
             grep -iE 'fail|error' "$AFK_DIR/$t-ci.txt" 2>/dev/null | head -n 3 | sed 's/^/       /'
             CI_RED+=("$t")
             relabel "$t" "$LABEL_REVIEW" "$LABEL_KO"
             gh issue comment "$t" --body "$(printf '> *Généré par une session agent AFK.*\n\nPR #%s ouverte et vérification locale verte, mais **la CI du repo est rouge**. Repassé en `%s`.\n\n```\n%s\n```' \
               "$pr" "$LABEL_KO" "$(tail -n 30 "$AFK_DIR/$t-ci.txt")")" >/dev/null 2>&1
           fi ;;
    esac
  done
}

# ─── Intégration ──────────────────────────────────────────────────────────────
# Chaque ticket est vérifié sur sa branche seule. Deux lots verts isolément peuvent
# produire une base rouge — ou refuser de merger, sur un CLAUDE.md et un composant
# que ni l'un ni l'autre n'annonçait. On merge tout dans un worktree jetable et on
# repasse la porte. On ne touche à aucune PR : on rapporte.

INTEG_CONFLICTS=(); INTEG_MERGED=(); INTEG_VERDICT="—"

# Les fichiers ajoutés par les branches du run, passés au parseur `clashing_numbers`.
numbering_clashes() {
  local t
  for t in "${OK[@]}"; do
    git diff --name-only --diff-filter=A "$BASE_REF...${BRANCH_OF[$t]}" 2>/dev/null
  done | clashing_numbers
}

integration_check() {
  { (( ${#OK[@]} < 2 )) || [[ "$INTEGRATION" != "1" ]]; } && return 0
  echo; echo "═══ Intégration (${#OK[@]} branches vertes) ═══"

  local wt="$WORKTREE_DIR/_integration" t b clashes
  git worktree remove --force "$wt" 2>/dev/null; git worktree prune; rm -rf "$wt"
  git worktree add -q -B afk-integration "$wt" "$BASE_REF" || {
    echo "  ✗ worktree d'intégration impossible"; return 0; }
  seed_worktree "$wt" >/dev/null

  for t in "${OK[@]}"; do
    b="${BRANCH_OF[$t]}"
    if git -C "$wt" merge -q --no-edit "$b" 2>"$AFK_DIR/integration-merge.err"; then
      echo "  merge ${b} ✓"
      INTEG_MERGED+=("$b")
    else
      local files; files=$(git -C "$wt" diff --name-only --diff-filter=U | tr '\n' ' ')
      git -C "$wt" merge --abort 2>/dev/null
      # Sans fichier en conflit, le merge a été REFUSÉ (arbre sale, base absente) — ce
      # n'est pas la même information qu'un vrai recouvrement, et l'écrire « CONFLIT »
      # envoie chercher au mauvais endroit.
      if [[ -n "$files" ]]; then
        echo "  merge ${b} ✗ CONFLIT — ${files}"
      else
        echo "  merge ${b} ✗ REFUSÉ — $(head -n 1 "$AFK_DIR/integration-merge.err")"
      fi
      INTEG_CONFLICTS+=("$b")
    fi
  done

  # Les collisions de numéro se lisent sur les branches, pas sur l'arbre mergé : deux
  # fichiers de noms différents y coexistent sans rien dire.
  clashes=$(numbering_clashes)
  if [[ -n "$clashes" ]]; then
    echo "  ⚠  numéros pris deux fois (aucune porte ne le verra) :"
    sed 's/^/       /' <<<"$clashes"
  fi

  # `_integration` comme numéro de ticket : la passe rejoue la porte, donc elle migre
  # comme un worker et doit s'isoler pareil (cf. `AFK_TICKET` dans le worker).
  [[ -n "$SETUP_CMD" ]] && ( cd "$wt" && AFK_TICKET=_integration AFK_WORKTREE="$wt" \
    locked install bash -c "$SETUP_CMD" ) > "$AFK_DIR/integration-setup.log" 2>&1

  echo "  → vérification de l'ensemble"
  [[ "$INTEGRATION_VERIFY_CMD" != "$VERIFY_CMD" ]] &&
    echo "     porte d'intégration : ${INTEGRATION_VERIFY_CMD}"
  local ok=0
  ( cd "$wt" && locked verify bash -c "$INTEGRATION_VERIFY_CMD" ) \
    > "$AFK_DIR/integration-verify.txt" 2>&1 && ok=1

  # Le verdict PORTE SON PÉRIMÈTRE. « L'ensemble compile » après une branche écartée au
  # merge se lit au bilan comme « toutes les branches se combinent », ce qui est
  # précisément la question à laquelle la passe existe pour répondre.
  local scope="" n=${#INTEG_MERGED[@]} m=${#OK[@]}
  (( ${#INTEG_CONFLICTS[@]} )) && scope=" — PARTIEL : ${n}/${m} branches, sans ${INTEG_CONFLICTS[*]}"
  if (( ok )); then
    INTEG_VERDICT="vert"; echo "  ✓ l'ensemble compile${scope}"
  else
    INTEG_VERDICT="rouge"; echo "  ✗ rouge à l'intégration${scope} — .afk/integration-verify.txt"
    tail -n 10 "$AFK_DIR/integration-verify.txt" | sed 's/^/     /'
  fi
  (( ${#INTEG_CONFLICTS[@]} )) && INTEG_VERDICT="$INTEG_VERDICT (partiel : ${n}/${m})"
  [[ -n "$clashes" ]] && INTEG_VERDICT="$INTEG_VERDICT + numéros en double"

  if [[ "$KEEP_WORKTREES" != "1" && "$ok" == "1" && ${#INTEG_CONFLICTS[@]} -eq 0 && -z "$clashes" ]]; then
    git worktree remove --force "$wt" 2>/dev/null; rm -rf "$wt"
    git branch -qD afk-integration 2>/dev/null
  else
    echo "  · worktree gardé pour inspection : .afk/wt/_integration"
  fi
}

# ─── Bilan ────────────────────────────────────────────────────────────────────

# Transcripts de ce run pour un ticket. Claude Code les range sous
# $CLAUDE_CONFIG_DIR/projects/<cwd de la session, / et . remplacés par ->.
ctx_of() {
  local t="$1" d
  d="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$WORKTREE_DIR/$t" | sed 's#[/.]#-#g')"
  [[ -d "$d" ]] || return 0
  find "$d" -maxdepth 1 -name '*.jsonl' -newer "$RUN_MARKER" -exec cat {} + 2>/dev/null |
    peak_context
}

write_summary() {
  local f="$AFK_DIR/summary.md" t
  {
    printf '# Run afk — %s tickets, %s\n\n' "${#TICKETS[@]}" "$(fmt_dur $SECONDS)"
    printf '| Ticket | Résultat | PR | Essai | Contexte | Durée | Titre |\n|---|---|---|---|---|---|---|\n'
    for t in "${TICKETS[@]}"; do
      local res pr att d ctx
      res=$(sget "$t" result); pr=$(sget "$t" pr); att=$(sget "$t" attempt)
      d=$(sget "$t" dur); d=${d:+$(fmt_dur "$d")}; d=${d:-—}
      ctx=$(ctx_of "$t"); ctx=${ctx:+$(( ctx / 1000 ))k}; ctx=${ctx:-—}
      [[ " ${SKIP[*]} " == *" $t "* ]] && res="gelé"
      [[ " ${DRAFT[*]} " == *" $t "* ]] && res="draft"
      [[ " ${ABSORBED[*]} " == *" $t "* ]] && res="absorbé"
      [[ " ${CI_RED[*]} " == *" $t "* ]] && res="$res / CI rouge"
      [[ -n "${VERIFY[$t]:-}" && "${VERIFY[$t]}" != "$VERIFY_CMD" ]] && res="$res ⚠"
      printf '| #%s | %s | %s | %s | %s | %s | %s |\n' \
        "$t" "${res:-—}" "${pr:+#$pr}" "${att:-—}" "$ctx" "$d" "${TITLE[$t]:-}"
    done
    printf -- '\n- intégration : %s%s\n' "$INTEG_VERDICT" \
      "$( (( ${#INTEG_CONFLICTS[@]} )) && echo " — écartées au merge : ${INTEG_CONFLICTS[*]} ; mergées : ${INTEG_MERGED[*]}" )"
    printf -- '- porte : %s%s\n' "$VERIFY_CMD" \
      "$( [[ "$INTEGRATION_VERIFY_CMD" != "$VERIFY_CMD" ]] && echo " · intégration : $INTEGRATION_VERIFY_CMD" )"
    printf -- '- les tickets marqués ⚠ ont eu une porte locale RÉDUITE (ligne `Verify:`) : seule leur CI a joué la porte complète.\n'
    printf -- '- vert au 1er essai : %s/%s\n' "$FIRST_TRY" "$(( ${#OK[@]} + ${#KO[@]} ))"
    printf -- '- contexte : le pic de la session ; au-delà de ~200k le ticket était trop gros.\n'
    printf '\nLogs par ticket : `.afk/<n>.out` (orchestrateur), `.afk/<n>-<essai>.log` (session),\n'
    printf '`.afk/<n>-verify.txt` (porte), `.afk/<n>-ci.txt` (CI).\n'
  } > "$f"
  echo "  résumé : .afk/summary.md"
}

# ─── Boucle ───────────────────────────────────────────────────────────────────

if (( ${#ARGV[@]} )); then
  TICKETS=("${ARGV[@]}")
else
  # --limit explicite : `gh issue list` plafonne à 30 SANS le dire, et rend les plus
  # RÉCENTS. Sur un dépôt à plus de 30 tickets ouverts, le run partait donc sur une
  # tranche arbitraire, et les tickets tombés hors tranche apparaissaient comme des
  # « bloqueurs ouverts hors run » — un gel silencieux, pas une erreur.
  mapfile -t TICKETS < <(gh issue list --label "$LABEL" --state open --limit 500 \
    --json number -q '.[].number' | sort -n)
fi

(( ${#TICKETS[@]} == 0 )) && { echo "aucun ticket ${LABEL}."; exit 0; }

CI_FAILFAST=""; KNOWN_LABELS=""
mkdir -p "$AFK_DIR"; printf '*\n' > "$AFK_DIR/.gitignore"
# Les transcripts s'accumulent d'un run à l'autre dans le même dossier : ce marqueur
# sert à ne relire que ceux de ce run-ci.
RUN_MARKER="$AFK_DIR/.runstart"; : > "$RUN_MARKER"

echo "${#TICKETS[@]} ticket(s) : ${TICKETS[*]}"
echo "base : ${BASE_REF} → PR sur ${BASE_BRANCH}   labels : ${LABEL} → ${LABEL_REVIEW} / ${LABEL_KO}"
echo "vérification : ${VERIFY_CMD}"
[[ "$INTEGRATION_VERIFY_CMD" != "$VERIFY_CMD" ]] &&
  echo "  · intégration : ${INTEGRATION_VERIFY_CMD}"
echo -n "parallélisme : ${JOBS} session(s)"
(( JOBS > 1 )) && [[ "$VERIFY_LOCK" == "1" ]] && echo -n "   vérifications sérialisées (ressources partagées)"
echo
[[ "$CI_TIMEOUT" == "0" ]] && echo "CI : non consultée" || echo "CI : attendue en fin de run (${CI_TIMEOUT})"

echo; echo "→ lecture des ${#TICKETS[@]} tickets…"
plan_run

if (( ${#DROPPED[@]} )); then
  keep=()
  for t in "${TICKETS[@]}"; do
    [[ " ${DROPPED[*]} " == *" $t "* ]] || keep+=("$t")
  done
  TICKETS=(${keep[@]+"${keep[@]}"})
  (( ${#TICKETS[@]} == 0 )) && { echo; echo "plus rien à faire."; exit 0; }
fi

if [[ "$DRY_RUN" == "1" ]]; then
  # Le plan, sans rien lancer. Les vagues montrent exactement où le parallélisme
  # est possible et où le DAG l'interdit.
  echo; echo "═══ Plan ═══"
  declare -A LIVERED=()
  local_wave=1; remaining=("${TICKETS[@]}")
  while (( ${#remaining[@]} )); do
    wave=(); frozen=(); next=()
    for t in "${remaining[@]}"; do
      ready=1; froze=0
      [[ -n "${EXT[$t]}" ]] && froze=1
      for b in ${DEPS[$t]}; do [[ -n "${LIVERED[$b]:-}" ]] || ready=0; done
      if   (( froze )); then frozen+=("$t")
      elif (( ready )); then wave+=("$t")
      else next+=("$t"); fi
    done
    for t in "${frozen[@]}"; do echo "  ⏸  #${t} gelé — bloqueurs ouverts hors run : ${EXT[$t]}"; done
    (( ${#wave[@]} == 0 )) && { for t in "${next[@]}"; do echo "  ⏸  #${t} gelé — bloqueur non livrable"; done; break; }
    echo "  vague ${local_wave} ($( (( ${#wave[@]} > 1 && JOBS > 1 )) && echo "parallèle, ${JOBS} à la fois" || echo "séquentiel" )) :"
    for t in "${wave[@]}"; do
      # Même calcul que launch() : la base, puis ce qui reste à merger par-dessus.
      # Les branches du run n'existent pas encore, deepest_branch retombe donc sur la
      # dernière listée — c'est le pire cas, et c'est celui qu'il faut montrer.
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
      (( ${#absorb[@]} )) && printf '          absorbe : %s\n' "${absorb[*]}"
      [[ "${VERIFY[$t]}" != "$VERIFY_CMD" ]] && printf '          Verify: %s\n' "${VERIFY[$t]}"
      [[ "${TMO[$t]}"    != "$TIMEOUT"    ]] && printf '          Timeout: %s\n' "${TMO[$t]}"
      LIVERED[$t]=1
    done
    remaining=("${next[@]}"); local_wave=$(( local_wave + 1 ))
  done
  echo; echo "(dry run — rien lancé)"
  exit 0
fi

setup_git_auth
git fetch -q origin "$BASE_BRANCH" || { echo "✗ fetch de origin/${BASE_BRANCH} impossible"; exit 1; }
# Les branches des bloqueurs livrés hors run : sans ce fetch, origin/<branche> peut
# être absente ou périmée, et le worktree partirait d'un état qui n'existe plus.
(( ${#EXT_FETCH[@]} )) && { git fetch -q origin "${EXT_FETCH[@]}" ||
  echo "⚠  fetch des branches hors run (${EXT_FETCH[*]}) incomplet — leurs dépendants peuvent échouer"; }
[[ -n "$(git status --porcelain)" ]] &&
  echo "· arbre principal sale — sans effet : le script travaille dans .afk/wt/, il n'y touche pas"
gh pr checks --help 2>&1 | grep -q -- '--fail-fast' && CI_FAILFAST="--fail-fast"

KNOWN_LABELS=$(gh label list --limit 200 --json name -q '.[].name' 2>/dev/null)
ensure_label "$LABEL_REVIEW" "Livré par un agent, PR ouverte, en attente de revue humaine"
ensure_label "$LABEL_KO"     "Rendu à un humain : l'agent n'a pas abouti"

mkdir -p "$WORKTREE_DIR"
trap finish EXIT INT TERM
schedule
ci_phase
integration_check

echo
echo "═══ Bilan  ($(fmt_dur $SECONDS)) ═══"
echo "  vert   (${#OK[@]}) : ${OK[*]:-—}"
(( ${#DRAFT[@]} )) &&
  echo "  draft  (${#DRAFT[@]}) : ${DRAFT[*]}  → session anormale, relire avant de sortir du draft"
(( ${#ABSORBED[@]} )) &&
  echo "  absorbé (${#ABSORBED[@]}) : ${ABSORBED[*]}  → rien à faire, base déjà verte : livrés par un prédécesseur, à fermer"
echo "  rouge  (${#KO[@]}) : ${KO[*]:-—}  → passés en ${LABEL_KO}, worktrees gardés dans .afk/wt/"
echo "  gelé   (${#SKIP[@]}) : ${SKIP[*]:-—}  → bloqueurs non levés, relance après merge"
(( ${#CI_RED[@]} )) &&
  echo "  CI rouge (${#CI_RED[@]}) : ${CI_RED[*]}  → repassés en ${LABEL_KO}"
(( ${#CI_UNKNOWN[@]} )) &&
  echo "  CI non concluante (${#CI_UNKNOWN[@]}) : ${CI_UNKNOWN[*]}"
# Une seule ligne « intégration » : le verdict porte déjà son périmètre, une seconde ligne
# du même nom juste au-dessus se lisait comme deux verdicts contradictoires.
[[ "$INTEG_VERDICT" != "—" ]] &&
  echo "  intégration : ${INTEG_VERDICT}$( (( ${#INTEG_CONFLICTS[@]} )) && echo "  → conflit sur ${INTEG_CONFLICTS[*]}, à résoudre à la main avant merge" )"
(( ${#OK[@]} + ${#KO[@]} > 0 )) &&
  echo "  vert au 1er essai : ${FIRST_TRY}/$(( ${#OK[@]} + ${#KO[@]} ))"
write_summary

echo
echo "Sous ~50% de vert au premier essai, le problème est dans /to-tickets, pas ici."
echo "100% de vert n'est pas mieux si la porte ne vérifie rien : \"vert\" veut dire"
echo "\"ça compile\" tant qu'un ticket n'a pas sa propre ligne Verify:."
