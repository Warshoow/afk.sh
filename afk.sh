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

# Surcharge propre à un ticket : la première ligne "<Champ>: <valeur>" de son corps, sur
# stdin. Un seul parseur pour les quatre champs — ils ne diffèrent que par le nom et par
# ce qu'on accepte comme valeur.
#
# Ils existent tous pour la même raison : le réglage global a été taillé pour le ticket
# moyen, et celui qui écrit le ticket est le seul à savoir avant qu'il ne tourne que
# celui-ci n'est pas moyen.
#   Verify:  la porte. Sans elle, VERIFY_CMD. C'est la seule façon pour un ticket d'app
#            de ne pas être gardé par un typecheck de monorepo entier, et pour un ticket
#            d'aspect d'exiger autre chose qu'une compilation.
#   Timeout: le budget de temps, au format de timeout(1). Une refonte (migration +
#            formule + gardes + tests + docs) ne rentre pas dans le gabarit d'un ticket
#            moyen et se fait couper au milieu.
#   Model:   le modèle. Une correction de typo n'a pas besoin du modèle d'une refonte.
#   Effort:  le niveau de réflexion, parmi ceux que claude(1) accepte.
#
# Une valeur qui ne passe pas son motif est IGNORÉE plutôt que passée telle quelle à
# claude(1) ou timeout(1), qui refuseraient alors de lancer la session — un ticket mal
# rédigé ne doit pas coûter un run.
#
# Les motifs vivent ici, pas dans les appels : check.sh source ce fichier et teste donc
# ceux qu'afk.sh emploie vraiment. Un motif recopié dans le test ne vérifierait que lui-même.
RE_TIMEOUT='[0-9]+(\.[0-9]+)?[smhd]?'          # le format de timeout(1)
RE_MODEL='[A-Za-z0-9][A-Za-z0-9._-]*'          # pas une liste de noms connus : elle serait
                                               # périmée au prochain modèle. Interdit juste
                                               # ce qui n'est pas un nom (espaces, métacaractères).
RE_EFFORT='(low|medium|high|xhigh|max)'        # l'ensemble fermé que claude(1) accepte
RE_VERIFY='[^`]*[^`:[:space:]]'                # une commande ne finit pas par « : » — c'est
                                               # la forme d'une phrase d'introduction, et c'est
                                               # celle qui a fini au `bash -c`. Et elle ne garde
                                               # pas de backtick après le nettoyage : ce qui en
                                               # garde est de la prose qui CITE des commandes.
                                               # Prix payé : une commande à substitution
                                               # `cmd` à l'ancienne est refusée aussi. Elle
                                               # s'écrit $(cmd) depuis trente ans.

# Le nettoyage de la valeur, avant validation :
#   1. le gras qui suit le « : » — `**Verify:** cmd` laisse ses deux astérisques APRÈS le
#      deux-points, donc hors de portée du premier sed ;
#   2. si la valeur COMMENCE par un span backtick, on ne garde que lui. Un ticket bien
#      rédigé écrit la commande en `code` puis, en français, ce qu'elle ne couvre pas :
#      la prose est une note pour l'agent, pas une porte. Sans ça la ligne entière partait
#      au `bash -c`, où le `**` globait sur le cwd.
#   3. les backticks ne tombent QUE si la valeur est le span tout entier. Une porte qui
#      commence en français et cite ses commandes au milieu (« à la main, `python -m jarvis
#      hub` + `npm run dev` : … ») échappe au point 2 — rien à y garder, elle ne commence
#      pas par un span. Son backtick résiduel est ce qui la fait refuser par `RE_VERIFY`,
#      et l'effacer aveuglément effaçait la seule trace qui la distingue d'une commande.
# La forme nue (`Verify: pnpm test`) reste acceptée telle quelle : c'est celle du README.
meta_line() {   # $1 = nom du champ, $2 = motif de validation (défaut : n'importe quoi)
  sed -n -E "s/^[[:space:]>*+-]*[\`*]*$1[\`*]*[[:space:]]*:[[:space:]]*//Ip" |
    sed -E 's/^[*_[:space:]]+//; s/^(`[^`]+`).*$/\1/; s/^`([^`]*)`$/\1/; s/[[:space:]]+$//' |
    awk 'NF{print; exit}' |
    grep -Ex -- "${2:-.+}" || true   # absent ou mal formé : pas une erreur
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

# Un champ de l'objet rendu par `claude -p --output-format json`, sur stdin. Pas de jq :
# une seule clé cherchée telle quelle, comme peak_context — et la sortie d'erreur de la
# session atterrit dans le même fichier, donc un parseur JSON strict refuserait de le
# lire. Les clés visées (session_id, subtype, is_error, total_cost_usd) précèdent toutes
# le champ "result", qui est du texte libre : le premier match est le bon.
jval() {   # nom de la clé
  grep -o "\"$1\":\"\?[^,\"}]*" | head -1 | cut -d: -f2- | tr -d '"'
}

# Les modèles réellement utilisés par la session — une entrée "canonicalModel" par
# modèle dans modelUsage. C'est ce qui rend FALLBACK_MODEL visible : un repli change le
# modèle sans rien dire, et une nuit entière peut basculer sur le secours.
jmodels() {
  grep -o '"canonicalModel":"[^"]*"' | cut -d'"' -f4 | sed 's/^claude-//' | sort -u |
    paste -sd' ' -
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
# ($HOME=/home/node, config sur /home/<user>/.claude).
CLAUDE_CONFIG_CANDIDATES=("$HOME"/.claude /home/*/.claude)
if [[ -z "${CLAUDE_CONFIG_DIR:-}" ]]; then
  for d in "${CLAUDE_CONFIG_CANDIDATES[@]}"; do
    [[ -d "$d/plugins/cache/mattpocock" ]] && { CLAUDE_CONFIG_DIR="$d"; break; }
  done
fi
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"        # 1 essai + 1 reprise, en session neuve
TIMEOUT="${TIMEOUT:-45m}"                # garde-fou : borne un run (pas de --max-turns en 2.1.x)
                                         # surchargeable par ticket : ligne "Timeout:" du corps
CI_TIMEOUT="${CI_TIMEOUT:-15m}"          # attente de la CI ; 0 = ne pas consulter
CI_RETRY_WAIT="${CI_RETRY_WAIT:-10}"     # secondes avant de réessayer un « no checks » (cf. ci_phase)
INTEGRATION="${INTEGRATION:-1}"          # passe d'intégration des branches vertes en fin de run
CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-0}"  # 0 = jamais de pause. C'est un outil non surveillé.

# Le modèle et le niveau de réflexion des sessions. Vides = les défauts de claude(1).
# Surchargeables par ticket : lignes "Model:" et "Effort:" du corps.
MODEL="${MODEL:-}"
EFFORT="${EFFORT:-}"

# Un run AFK n'a personne devant lui. Sans repli, une indisponibilité passagère du
# modèle sort la session en erreur, le ticket brûle ses deux essais en quelques
# secondes et part en ready-for-human — pour une raison qui n'a rien à voir avec lui,
# et la file entière y passe. --fallback-model ne marche qu'avec --print, donc
# exactement ici. Le repli est visible : le bilan donne le modèle qui a réellement
# tourné, ticket par ticket. Vide = pas de repli.
FALLBACK_MODEL="${FALLBACK_MODEL:-sonnet}"

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
# Le dépôt d'afk lui-même, qui n'est PAS le dépôt travaillé : le script est monté dans
# les devcontainers et lancé depuis n'importe quel projet. `$PWD` est le projet,
# `$AFK_HOME` est afk — le seul endroit qui survive d'un projet à l'autre, et donc le
# seul où un journal puisse s'accumuler. `readlink -f` parce que le script est souvent
# atteint par un lien. Surchargeable : harness.sh le détourne pour ne pas écrire dans
# le vrai dépôt pendant ses tests.
AFK_HOME="${AFK_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}"
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
  echo "  force-le : CLAUDE_CONFIG_DIR=/chemin/vers/.claude $0 …"; exit 1; }

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

# Ce que les bloqueurs ont déjà livré. Le worktree part de LEUR branche (cf. launch),
# donc leur travail est déjà sur le disque ici — mais rien ne le dit à l'agent, qui
# démarre en session neuve. Deux dégâts, tous les deux vus : il refait un travail déjà
# fait (le ticket « absorbé » brûle ses deux essais à le redécouvrir seul), et il
# renomme au passage un contrat typé qu'il vient d'hériter, parce qu'il n'a pas lu
# l'ADR que son prédécesseur venait d'écrire pour lui.
# Aucun fichier à produire, aucun format à imposer à l'agent : le prédécesseur commite
# déjà ses décisions (voir la consigne CONTEXT.md/ADR ci-dessous), et le DAG sert de
# filtre — la base ne contient que les ancêtres de ce ticket, rien d'autre du run.
# L'argument est le HEAD d'AVANT la session : à l'essai 2, HEAD porte déjà le travail
# de l'agent, qui n'a rien à apprendre de lui-même.
inherited_note() {   # committish hérité
  local files mem n
  files=$(git diff --name-only "$BASE_REF...$1" 2>/dev/null)
  [[ -z "$files" ]] && return 0
  n=$(wc -l <<<"$files")

  printf '\n--- HÉRITÉ DE TES BLOQUEURS ---\n'
  printf 'Ta base porte déjà leur travail (%d fichier(s)). Si un critère de ton ticket y\n' "$n"
  printf 'est déjà satisfait, tu le signales et tu ne le réécris pas.\n'
  mem=$(grep -E "$MEMORY_RE" <<<"$files")
  [[ -n "$mem" ]] &&
    printf '\nLeurs décisions, à lire AVANT de coder :\n%s\n' "$(sed 's|^|  - |' <<<"$mem")"
  printf '\nFichiers déjà touchés :\n%s\n' "$(head -n 30 <<<"$files" | sed 's|^|  - |')"
  (( n > 30 )) &&
    printf '  … et %d autres : git diff --name-only %s...%s\n' "$(( n - 30 ))" "$BASE_REF" "$1"
  return 0
}

build_prompt() {
  local ticket="$1" attempt="$2" verify="$3" inherited="$4"

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
- Tu ne lances pas la vérification toi-même : l'orchestrateur la passe après toi. La
  lancer, c'est la faire tourner deux fois — et une session qui rend son tour en
  l'attendant se termine sans avoir commité.
- D'autres tickets tournent peut-être en parallèle dans d'autres worktrees. Tu ne
  regardes qu'ici, tu ne touches à aucune autre branche.
EOF

  inherited_note "$inherited"

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

declare -A DEPS=() EXT=() TITLE=() VERIFY=() TMO=() MDL=() EFF=()
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

    VERIFY[$t]=$(meta_line Verify "$RE_VERIFY" <<<"$body"); VERIFY[$t]="${VERIFY[$t]:-$VERIFY_CMD}"
    printf '%s' "${VERIFY[$t]}"  > "$AFK_DIR/$t.verify"
    TMO[$t]=$(meta_line Timeout "$RE_TIMEOUT" <<<"$body"); TMO[$t]="${TMO[$t]:-$TIMEOUT}"
    printf '%s' "${TMO[$t]}"     > "$AFK_DIR/$t.timeout"
    # Un nom de modèle bien formé mais faux fait échouer la session tout de suite, comme
    # une ligne "Verify:" qui ne compile pas : même surface de confiance.
    MDL[$t]=$(meta_line Model "$RE_MODEL" <<<"$body"); MDL[$t]="${MDL[$t]:-$MODEL}"
    printf '%s' "${MDL[$t]}"     > "$AFK_DIR/$t.model"
    EFF[$t]=$(meta_line Effort "$RE_EFFORT" <<<"$body"); EFF[$t]="${EFF[$t]:-$EFFORT}"
    printf '%s' "${EFF[$t]}"     > "$AFK_DIR/$t.effort"

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
  local title labels verify tmo mdl eff head0 rc crashed netted attempt
  local out sid why c cost=0 cut=0
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
  # `result_initial`, pas `result` : le fichier est append-only et `sget` lit la
  # DERNIÈRE ligne, mais un humain qui fait `cat` ou `grep result=` sur un ticket vert
  # lisait `result=ko` en tête. Absent = rouge de toute façon (cf. `reap`).
  st "result_initial=ko"; st "branch=$branch"; st "base=$base"

  # Les drapeaux de la session. --output-format json parce que le code de retour ne
  # dit pas POURQUOI une session s'est arrêtée, et que le bilan a besoin du coût, du
  # modèle réellement utilisé et de l'identifiant de session pour qu'un ticket rouge
  # se reprenne à la main (claude --resume) au lieu de se relire dans un log.
  copts=(--permission-mode bypassPermissions --output-format json)
  [[ -n "$mdl" ]] && copts+=(--model "$mdl")
  [[ -n "$eff" ]] && copts+=(--effort "$eff")
  [[ -n "$FALLBACK_MODEL" ]] && copts+=(--fallback-model "$FALLBACK_MODEL")

  echo "  worktree    : ${wt#$REPO_ROOT/}"
  echo "  base        : ${base}"
  [[ "$verify" != "$VERIFY_CMD" ]] && echo "  vérification: ${verify}   (Verify: du ticket)"
  [[ "$tmo" != "$TIMEOUT" ]] && echo "  budget      : ${tmo}   (Timeout: du ticket)"
  [[ -n "$mdl" ]] && echo "  modèle      : ${mdl}"
  [[ -n "$eff" ]] && echo "  effort      : ${eff}"
  local seeded; seeded=$(cat "$AFK_DIR/$ticket-seed.n" 2>/dev/null || echo 0)
  (( seeded )) && echo "  semé        : ${seeded} fichier(s) ignoré(s) recopié(s) depuis l'arbre principal"

  cd "$wt" || { echo "  ✗ worktree inaccessible"; return; }

  if [[ -n "$SETUP_CMD" ]]; then
    echo "  → dépendances (${SETUP_CMD})"
    # `AFK_TICKET` / `AFK_WORKTREE` sont exportés pour que `SETUP_CMD` puisse ISOLER ce
    # worktree de ses voisins. Le besoin est venu d'un vrai dégât (défaut 17, docs/defauts.md) :
    # plusieurs worktrees partageaient une base de test fixée en dur dans un `.env.test` versionné,
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
    out="$AFK_DIR/$ticket-$attempt.json"
    timeout "$tmo" claude -p "$(build_prompt "$ticket" "$attempt" "$verify" "$head0")" \
      "${copts[@]}" > "$out" 2>&1
    rc=$?; crashed=0; netted=0; cut=0

    # Ce que la session raconte d'elle-même. `subtype` nomme la panne
    # (error_during_execution, error_max_turns…) là où le code de retour ne donne qu'un
    # chiffre ; `session_id` la rend reprenable à la main ; le coût s'additionne sur les
    # essais, le modèle est celui du dernier — c'est lui qui a produit la branche.
    sid=$(jval session_id < "$out"); why=$(jval subtype < "$out")
    st "session=$sid"; st "model=$(jmodels < "$out")"
    # Rien lu = rien à dire : une session tuée avant d'écrire son objet doit laisser le
    # coût VIDE au bilan, pas un "0,0000 $" qui se lirait comme une session gratuite.
    c=$(jval total_cost_usd < "$out")
    [[ -n "$c" ]] && { cost=$(awk -v a="$cost" -v b="$c" 'BEGIN{printf "%.4f", a+b}'); st "cost=$cost"; }

    (( rc == 124 )) && { echo "  ⚠  timeout ${tmo} — le ticket peut porter sa propre ligne \"Timeout:\""; crashed=1; cut=1; }
    (( rc != 0 && rc != 124 )) && {
      echo "  ⚠  session terminée anormalement (${why:-code ${rc}}) — ${AFK_DIR##*/}/${ticket}-${attempt}.json"
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
      # Une session COUPÉE au timeout peut l'avoir été au milieu d'un fichier ; une session
      # qui a rendu son tour s'est arrêtée entre deux actions. La porte ne dit ni l'un ni
      # l'autre — elle dit que ce qui existe compile. Ce n'est pas la même relecture.
      if (( cut )); then
        pr_body+=$'\n\n'"> ⚠ **La session agent a été COUPÉE** au bout de \`${tmo}\` (ligne \`Timeout:\` du ticket). Elle peut l'avoir été au milieu d'un fichier : la porte dit que ce qui existe compile, pas que le travail est complet. Session : \`.afk/${ticket}-${attempt}.json\`."
      elif (( crashed )); then
        pr_body+=$'\n\n'"> ⚠ **La session agent s'est terminée anormalement** (${why:-code ${rc}}). Le travail présent passe la vérification, mais rien ne garantit qu'il soit complet — d'où le draft. Session : \`.afk/${ticket}-${attempt}.json\`."
      fi
      (( netted ))  && pr_body+=$'\n\n'"> ⚠ L'agent n'a pas commité lui-même : l'orchestrateur a rattrapé l'arbre de travail."

      # La branche est complète, verte et commitée : ce qui a échoué est le transport
      # (jeton sans la portée `workflow`, branche déjà sur le remote), pas le travail.
      # Un second essai échouerait à l'identique, et la ranger avec les rouges la fait
      # reprendre de zéro au run suivant. Elle a sa propre ligne au bilan, et son
      # worktree est gardé comme celui d'un rouge.
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

      local dwhy=""
      (( cut )) && dwhy="coupée"; (( crashed && ! cut )) && dwhy="anormale"
      (( netted )) && dwhy="${dwhy:+$dwhy, }non commité"
      st "result=ok"; st "pr=$pr_num"; st "draft=$suspect"; st "draft_why=$dwhy"
      if (( suspect )); then
        echo "  ✓ vert (essai ${attempt}) — PR #${pr_num} en DRAFT sur ${base#origin/}"
        echo "     ⚠  ${dwhy} : relire avant de sortir du draft"
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
OK=(); KO=(); SKIP=(); DRAFT=(); ABSORBED=(); PUSH_KO=(); FIRST_TRY=0

deps_state() {   # 0 = prêt, 1 = attendre, 2 = gelé
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
    elif [[ "$(sget "$t" reason)" == "push" ]]; then
      PUSH_KO+=("$t")   # branche verte et commitée en local, seulement pas poussée
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

# « Aucune CI déclarée » et « CI toujours en cours » sortaient dans le même panier. Ce
# n'est pas la même information : la seconde est un verdict qui manque, la première est
# une propriété du DÉPÔT, vraie pour tous les tickets de tous les runs. Confondues, elles
# marquaient « vert non prouvé » les quinze tickets d'un lot sur un dépôt sans workflow.
CI_RED=(); CI_UNKNOWN=(); CI_NONE=()

ci_phase() {
  (( ${#OK[@]} )) || return 0
  [[ "$CI_TIMEOUT" == "0" ]] && return 0
  echo; echo "═══ CI (${#OK[@]} PR, timeout ${CI_TIMEOUT}) ═══"

  local t pr pids=()
  for t in "${OK[@]}"; do
    pr=$(sget "$t" pr)
    # `--watch` ne surveille que des check runs DÉJÀ enregistrés : avec zéro, il ne
    # patiente pas, il sort tout de suite. Or GitHub met quelques secondes à enregistrer
    # le run après `gh pr create` (mesuré : ~4 s), ce qui expose la dernière PR créée.
    # « Le dépôt n'a pas de CI » et « la CI n'est pas encore enregistrée » rendaient donc
    # la même phrase, alors que la seconde se répare en réessayant.
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
      0)   echo "  ✓ #${t} (PR #${pr}) CI verte" ;;
      124) echo "  ⚠  #${t} (PR #${pr}) CI toujours en cours après ${CI_TIMEOUT} — non concluant"
           CI_UNKNOWN+=("$t") ;;
      *)   if grep -qi 'no checks' "$AFK_DIR/$t-ci.txt" 2>/dev/null; then
             echo "  ⚠  #${t} (PR #${pr}) aucune CI déclarée"; CI_NONE+=("$t")
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
declare -A INTEG_FILES=()   # branche → fichiers en conflit, pour le résumé
INTEG_NOTES=""              # numéros en double, chemins créés deux fois, renvois au futur

# Les fichiers ajoutés par chaque branche verte, une ligne "<branche> <chemin>".
# Contre SA base, pas contre BASE_REF : une branche empilée porte les commits de son
# bloqueur, elle « ajoute » donc aussi les fichiers de celui-ci.
added_files() {
  local t b
  for t in "${OK[@]}"; do
    b=$(sget "$t" base); b="${b:-$BASE_REF}"
    git diff --name-only --diff-filter=A "$b...${BRANCH_OF[$t]}" 2>/dev/null |
      sed "s|^|${BRANCH_OF[$t]} |"
  done
}

numbering_clashes() { added_files | cut -d' ' -f2- | clashing_numbers; }

# Deux branches qui CRÉENT le même chemin sont vertes chacune de son côté — le fichier
# répond au même besoin vu des deux bouts, avec deux API différentes et toutes deux
# justes. Aucune porte ne peut le voir. `clashing_numbers` non plus : son `sort -u`
# d'entrée écrase justement les deux lignes identiques qu'on cherche, et son awk ne
# regarde que les noms qui commencent par un chiffre.
same_path_adds() {
  added_files | sort -u |
    awk '{ b[$2] = b[$2] " " $1; n[$2]++ } END { for (p in n) if (n[p] > 1) printf "%s :%s\n", p, b[p] }' |
    sort
}

# Merger une branche empilée AVANT sa base est un conflit par construction, et il se lit
# comme un vrai recouvrement. La liste des verts est remplie dans l'ordre d'ACHÈVEMENT ;
# on la retrie par nombre de commits depuis la base commune — une branche empilée en a
# strictement plus que la sienne, donc elle passe après.
merge_order() {
  local t
  for t in "${OK[@]}"; do
    printf '%s %s\n' "$(git rev-list --count "$BASE_REF..${BRANCH_OF[$t]}" 2>/dev/null || echo 0)" "$t"
  done | sort -n | cut -d' ' -f2
}

# Une branche écrit « c'est #116 qui ouvrira cette liste » ; #116 livre dans le même run ;
# personne ne réécrit la phrase — ni celle qui l'a écrite (elle est finie), ni #116 (elle
# ne sait pas qu'elle est citée). Les deux côtés sont d'accord, git fusionne en silence,
# et la doc affirme au futur ce qui est livré depuis dix minutes. On ne juge pas la
# phrase, on montre où elle est. `git grep` : les fichiers suivis seulement.
stale_refs() {   # $1 = worktree d'intégration
  local nums; nums=$(IFS='|'; echo "${OK[*]}")
  git -C "$1" grep -nE "#(${nums})([^0-9]|$)" -- '*.md' ':!CHANGELOG.md' ':!RUNS.md' 2>/dev/null |
    head -n 20
}

integration_check() {
  { (( ${#OK[@]} < 2 )) || [[ "$INTEGRATION" != "1" ]]; } && return 0
  echo; echo "═══ Intégration (${#OK[@]} branches vertes) ═══"

  local wt="$WORKTREE_DIR/_integration" t b clashes
  git worktree remove --force "$wt" 2>/dev/null; git worktree prune; rm -rf "$wt"
  git worktree add -q -B afk-integration "$wt" "$BASE_REF" || {
    echo "  ✗ worktree d'intégration impossible"; return 0; }
  seed_worktree "$wt" >/dev/null

  for t in $(merge_order); do
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
        files="REFUSÉ — $(head -n 1 "$AFK_DIR/integration-merge.err")"
        echo "  merge ${b} ✗ ${files}"
      fi
      # Écrit, pas seulement affiché : c'est la donnée dont la revue a besoin en premier
      # — elle dit lesquels des conflits sont de la doc et lesquels sont du code, donc
      # combien la résolution va coûter. Le terminal, lui, se ferme.
      INTEG_FILES[$b]="$files"
      INTEG_CONFLICTS+=("$b")
    fi
  done

  # Les collisions de numéro et les chemins créés deux fois se lisent sur les branches,
  # pas sur l'arbre mergé : deux fichiers de noms différents y coexistent sans rien dire,
  # et un `add/add` résolu n'en garde qu'un.
  clashes=$(numbering_clashes)
  if [[ -n "$clashes" ]]; then
    echo "  ⚠  numéros pris deux fois (aucune porte ne le verra) :"
    sed 's/^/       /' <<<"$clashes"
    INTEG_NOTES+=$'\n'"- numéros pris deux fois :"$'\n'"$(sed 's/^/  - /' <<<"$clashes")"
  fi
  local dupes; dupes=$(same_path_adds)
  if [[ -n "$dupes" ]]; then
    echo "  ⚠  même chemin créé par plusieurs branches :"
    sed 's/^/       /' <<<"$dupes"
    INTEG_NOTES+=$'\n'"- même chemin créé par plusieurs branches :"$'\n'"$(sed 's/^/  - /' <<<"$dupes")"
  fi

  local stale; stale=$(stale_refs "$wt")
  if [[ -n "$stale" ]]; then
    echo "  ⚠  tickets du run cités dans la doc mergée — relire, la phrase peut être au futur :"
    sed 's/^/       /' <<<"$stale"
    INTEG_NOTES+=$'\n'"- tickets du run cités dans la doc mergée (phrase au futur ?) :"$'\n'"$(sed 's/^/  - /' <<<"$stale")"
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
  [[ -n "$dupes"   ]] && INTEG_VERDICT="$INTEG_VERDICT + chemins en double"

  if [[ "$KEEP_WORKTREES" != "1" && "$ok" == "1" && ${#INTEG_CONFLICTS[@]} -eq 0 && -z "$clashes" && -z "$dupes" ]]; then
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

# Une ligne par run dans le dépôt d'afk. `.afk/summary.md` est ÉCRASÉ au run suivant :
# sans ce journal, aucun historique n'existe nulle part, et le taux de vert d'une nuit
# ne se compare à rien. Il traverse les projets, ce dépôt étant monté dans chacun.
# Aucun LLM : ce sont des faits, pas un jugement — le jugement est dans /afk-debrief,
# qui écrit les défauts d'afk lui-même dans docs/defauts.md.
append_run_log() {
  local f="$AFK_HOME/RUNS.md" t models total
  # Dépôt monté en lecture seule : on ne journalise pas, ce n'est pas une erreur de run.
  [[ -w "$AFK_HOME" ]] || return 0

  models=$(for t in "${TICKETS[@]}"; do sget "$t" model; done | tr ' ' '\n' | awk 'NF' |
    sort -u | paste -sd' ' -)
  total=$(for t in "${TICKETS[@]}"; do sget "$t" cost; done | awk '{s+=$1} END{if(s) printf "$%.2f", s}')

  [[ -f "$f" ]] || {
    printf '# Journal des runs\n\n'
    printf "Une ligne par run d'\`afk.sh\`, ajoutée automatiquement à la fin. \`.afk/summary.md\`\n"
    printf "est écrasé au run suivant : c'est ici, et seulement ici, que l'historique survit — et\n"
    printf "il traverse les projets, ce dépôt étant monté dans chacun.\n\n"
    printf "Les faits seulement. Ce qui demande un jugement va dans\n"
    printf '[docs/defauts.md](docs/defauts.md), écrit par `/afk-debrief`.\n\n'
    printf '| Date | Projet | Tickets | Vert | Non prouvé | Draft | Rouge | Push refusé | Gelé | Absorbé | 1er essai | Modèle | Coût | Durée | Intégration |\n'
    printf '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n'
  } > "$f"

  # Un seul printf, une seule ligne courte : deux runs lancés depuis deux projets
  # peuvent l'ajouter en même temps sans se marcher dessus.
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$(date +%Y-%m-%d\ %H:%M)" "${REPO_ROOT##*/}" "${#TICKETS[@]}" \
    "${#GREEN[@]}" "${#UNPROVEN[@]}" "${#DRAFT[@]}" "${#KO[@]}" "${#PUSH_KO[@]}" \
    "${#SKIP[@]}" "${#ABSORBED[@]}" \
    "${FIRST_TRY}/$(( ${#OK[@]} + ${#KO[@]} ))" "${models:-—}" "${total:-—}" \
    "$(fmt_dur $SECONDS)" "$INTEG_VERDICT" >> "$f"
}

write_summary() {
  local f="$AFK_DIR/summary.md" t b
  {
    printf '# Run afk — %s tickets, %s\n\n' "${#TICKETS[@]}" "$(fmt_dur $SECONDS)"
    printf '| Ticket | Résultat | PR | Essai | Modèle | Contexte | Coût | Durée | Titre |\n'
    printf '|---|---|---|---|---|---|---|---|---|\n'
    for t in "${TICKETS[@]}"; do
      local res pr att d ctx mdl cost
      res=$(sget "$t" result); pr=$(sget "$t" pr); att=$(sget "$t" attempt)
      d=$(sget "$t" dur); d=${d:+$(fmt_dur "$d")}; d=${d:-—}
      ctx=$(ctx_of "$t"); ctx=${ctx:+$(( ctx / 1000 ))k}; ctx=${ctx:-—}
      mdl=$(sget "$t" model); mdl=${mdl:-—}
      cost=$(sget "$t" cost); cost=${cost:+\$$cost}; cost=${cost:-—}
      [[ " ${SKIP[*]} " == *" $t "* ]] && res="gelé"
      [[ " ${DRAFT[*]} " == *" $t "* ]] && res="draft"
      [[ " ${ABSORBED[*]} " == *" $t "* ]] && res="absorbé"
      [[ " ${UNPROVEN[*]} " == *" $t "* ]] && res="vert non prouvé"
      [[ " ${PUSH_KO[*]} " == *" $t "* ]] && res="poussée refusée"
      [[ " ${CI_RED[*]} " == *" $t "* ]] && res="$res / CI rouge"
      [[ -n "${VERIFY[$t]:-}" && "${VERIFY[$t]}" != "$VERIFY_CMD" ]] && res="$res ⚠"
      printf '| #%s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$t" "${res:-—}" "${pr:+#$pr}" "${att:-—}" "$mdl" "$ctx" "$cost" "$d" "${TITLE[$t]:-}"
    done
    printf -- '\n- intégration : %s%s\n' "$INTEG_VERDICT" \
      "$( (( ${#INTEG_CONFLICTS[@]} )) && echo " — écartées au merge : ${INTEG_CONFLICTS[*]} ; mergées : ${INTEG_MERGED[*]}" )"
    # Le SUR QUOI, pas seulement le QUI : `integration-merge.err` est écrasé à chaque
    # branche et git rapporte les CONFLICT sur stdout, donc sans ça la liste des fichiers
    # se reconstruit à coups de `git merge-tree` en devinant l'ordre de merge d'origine.
    for b in "${INTEG_CONFLICTS[@]}"; do
      printf -- '  - `%s` : %s\n' "$b" "${INTEG_FILES[$b]:-—}"
    done
    [[ -n "$INTEG_NOTES" ]] && printf -- '%s\n' "$INTEG_NOTES"
    printf -- '- porte : %s%s\n' "$VERIFY_CMD" \
      "$( [[ "$INTEGRATION_VERIFY_CMD" != "$VERIFY_CMD" ]] && echo " · intégration : $INTEGRATION_VERIFY_CMD" )"
    printf -- '- les tickets marqués ⚠ ont eu une porte locale RÉDUITE (ligne `Verify:`) : seule leur CI a joué la porte complète.\n'
    printf -- '- vert au 1er essai : %s/%s\n' "$FIRST_TRY" "$(( ${#OK[@]} + ${#KO[@]} ))"
    printf -- '- contexte : le pic de la session. Il mesure la TAILLE du travail, pas sa qualité —\n'
    printf -- '  un pic haut sur un ticket bien cadré reste vert. À lire avec le périmètre livré.\n'
    printf -- '- modèle : celui qui a réellement tourné. Un autre que le modèle demandé = un repli\n'
    printf -- '  (`FALLBACK_MODEL=%s`) a joué, le modèle voulu était indisponible.\n' "${FALLBACK_MODEL:-aucun}"
    printf -- '- coût : prix catalogue cumulé sur les essais du ticket, tel que rendu par la session.\n'

    # Un ticket rendu à un humain se relit aujourd'hui dans un fichier. La session qui l'a
    # produit existe toujours et son worktree est gardé : on donne de quoi y RENTRER, et
    # lui demander ce qu'un log ne dira jamais — pourquoi il a pris ce chemin-là.
    # Les rouges seulement : `claude --resume` cherche la session dans le répertoire où
    # elle a tourné, et le worktree d'un vert est jeté.
    local sid resumable=0
    for t in "${TICKETS[@]}"; do
      [[ " ${KO[*]} ${PUSH_KO[*]} " == *" $t "* ]] || continue
      sid=$(sget "$t" session); [[ -n "$sid" ]] || continue
      (( resumable++ == 0 )) && printf '\nReprendre une session à la main :\n\n'
      printf -- '- #%s : `(cd %s/%s && claude --resume %s)`\n' \
        "$t" "${WORKTREE_DIR#$REPO_ROOT/}" "$t" "$sid"
    done

    printf '\nLogs par ticket : `.afk/<n>.out` (orchestrateur), `.afk/<n>-<essai>.json` (session),\n'
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
echo "modèle : ${MODEL:-défaut de claude}${EFFORT:+ · effort ${EFFORT}}${FALLBACK_MODEL:+ · repli ${FALLBACK_MODEL}}"
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
      [[ "${MDL[$t]}"    != "$MODEL"      ]] && printf '          Model: %s\n' "${MDL[$t]}"
      [[ "${EFF[$t]}"    != "$EFFORT"     ]] && printf '          Effort: %s\n' "${EFF[$t]}"
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

# Un ticket à porte locale RÉDUITE dont la CI n'a pas conclu n'a été vu par AUCUNE porte
# complète, et une PR en draft ne se merge pas. Les deux faits étaient imprimés, à trois
# lignes d'écart, sans jamais être croisés : c'était au lecteur de rapprocher deux listes
# de numéros pour s'apercevoir qu'un « vert » ne l'était pas.
GREEN=(); UNPROVEN=(); REDUCED=()
for t in "${OK[@]}"; do
  [[ "${VERIFY[$t]:-}" != "$VERIFY_CMD" ]] && REDUCED+=("$t")
  if   [[ " ${DRAFT[*]} " == *" $t "* ]]; then continue
  elif [[ " ${CI_UNKNOWN[*]} " == *" $t "* && "${VERIFY[$t]:-}" != "$VERIFY_CMD" ]]; then UNPROVEN+=("$t")
  else GREEN+=("$t"); fi
done

echo
echo "═══ Bilan  ($(fmt_dur $SECONDS)) ═══"
echo "  vert   (${#GREEN[@]}) : ${GREEN[*]:-—}"
(( ${#UNPROVEN[@]} )) &&
  echo "  vert non prouvé (${#UNPROVEN[@]}) : ${UNPROVEN[*]}  → porte locale réduite ET CI non concluante : rien n'a joué la porte complète"
(( ${#DRAFT[@]} )) &&
  echo "  draft  (${#DRAFT[@]}) : $(for t in "${DRAFT[@]}"; do printf '#%s (%s) ' "$t" "$(sget "$t" draft_why)"; done) → relire avant de sortir du draft"
(( ${#ABSORBED[@]} )) &&
  echo "  absorbé (${#ABSORBED[@]}) : ${ABSORBED[*]}  → rien à faire, base déjà verte : livrés par un prédécesseur, à fermer"
echo "  rouge  (${#KO[@]}) : ${KO[*]:-—}  → passés en ${LABEL_KO}, worktrees gardés dans .afk/wt/"
(( ${#PUSH_KO[@]} )) && {
  echo "  poussée refusée (${#PUSH_KO[@]}) : ${PUSH_KO[*]}  → branche verte et commitée en local, aucun label changé :"
  for t in "${PUSH_KO[@]}"; do
    echo "     #${t} : $(head -n 3 "$AFK_DIR/$t-push.txt" 2>/dev/null | tr '\n' ' ')"
  done; }
echo "  gelé   (${#SKIP[@]}) : ${SKIP[*]:-—}  → bloqueurs non levés, relance après merge"
(( ${#CI_RED[@]} )) &&
  echo "  CI rouge (${#CI_RED[@]}) : ${CI_RED[*]}  → repassés en ${LABEL_KO}"
(( ${#CI_UNKNOWN[@]} )) &&
  echo "  CI non concluante (${#CI_UNKNOWN[@]}) : ${CI_UNKNOWN[*]}"
# Une seule ligne pour tout le run : sur un dépôt sans workflow, le dire ticket par
# ticket n'apprend rien de plus au quinzième qu'au premier.
(( ${#CI_NONE[@]} == ${#OK[@]} && ${#OK[@]} )) &&
  echo "  aucune CI sur ce dépôt : la porte locale est la seule qui ait joué$( (( ${#REDUCED[@]} )) && echo " — et elle était RÉDUITE sur ${REDUCED[*]}" )"
# Une seule ligne « intégration » : le verdict porte déjà son périmètre, une seconde ligne
# du même nom juste au-dessus se lisait comme deux verdicts contradictoires.
[[ "$INTEG_VERDICT" != "—" ]] &&
  echo "  intégration : ${INTEG_VERDICT}$( (( ${#INTEG_CONFLICTS[@]} )) && echo "  → conflit sur ${INTEG_CONFLICTS[*]}, à résoudre à la main avant merge" )"
(( ${#OK[@]} + ${#KO[@]} > 0 )) &&
  echo "  vert au 1er essai : ${FIRST_TRY}/$(( ${#OK[@]} + ${#KO[@]} ))"
write_summary
append_run_log

echo
echo "Sous ~50% de vert au premier essai, le problème est dans /to-tickets, pas ici."
echo "100% de vert n'est pas mieux si la porte ne vérifie rien : \"vert\" veut dire"
echo "\"ça compile\" tant qu'un ticket n'a pas sa propre ligne Verify:."
