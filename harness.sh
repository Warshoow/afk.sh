#!/usr/bin/env bash
# harness.sh — test d'intégration de l'orchestrateur, sans réseau ni LLM.
#
# check.sh teste les parseurs. Celui-ci teste tout le reste : l'ordonnanceur sur le
# DAG, les worktrees, le filet, la détection de session plantée, les PRs empilées, le
# gel en cascade, la phase CI et l'intégration. `claude` et `gh` sont bouchonnés, le
# remote est un dépôt nu local.
#
# Il a trouvé trois bugs à sa première exécution (message de gel dupliqué, printf dont
# le format commence par "-", ordre de récolte indéfini). Le faire tourner après toute
# modification de la boucle.
set -uo pipefail
cd "$(dirname "$0")"
AFK="$PWD/afk.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fix" "$T/cfg/plugins/cache/mattpocock"

# ─── Le DAG de test ───────────────────────────────────────────────────────────
# 1 ← 3 ← 4, et 4 ← 1 aussi : la base de 4 doit être feat/3 (qui contient feat/1),
#                             et feat/1 ne doit PAS être annoncé comme absorbé.
# 2 : l'agent ne commite pas            → filet → draft
# 5 : bloqué par #99, ouvert hors run   → gelé
# 6 : l'agent plante (rc=1) après avoir commité → draft
# 7 : vérification rouge aux deux essais → ko
# 8 : bloqué par 7                       → gelé en cascade
printf '## Blocked by\n\nNone\n' > "$T/fix/1.body"
for n in 2 6 7; do cp "$T/fix/1.body" "$T/fix/$n.body"; done
printf '## Blocked by\n\n- #1\n'       > "$T/fix/3.body"
printf '## Blocked by\n\n- #1\n- #3\n' > "$T/fix/4.body"
printf '## Blocked by\n\n- #99\n'      > "$T/fix/5.body"
printf '## Blocked by\n\n- #7\n'       > "$T/fix/8.body"

# ─── Le lot du second run ─────────────────────────────────────────────────────
#  9 : l'agent ne produit rien, la base est verte  → absorbé (ni rouge, ni ready-for-human)
# 10 : bloqué par 9                                → ne gèle pas, part sur la base de 9
# 11 : déjà in-review                              → retiré de la liste
# 12 : Timeout:/Model:/Effort: dans le corps       → surcharges propres au ticket
# 13 : l'agent ne produit rien, sa porte est rouge → vrai échec, ko
printf '## Blocked by\n\nNone\n'                    > "$T/fix/9.body"
printf '## Blocked by\n\n- #9\n'                    > "$T/fix/10.body"
printf '## Blocked by\n\nNone\n'                    > "$T/fix/11.body"
printf 'Timeout: 90m\nModel: sonnet\n**Effort**: high\n\n## Blocked by\n\nNone\n' > "$T/fix/12.body"
printf 'Verify: false\n\n## Blocked by\n\nNone\n'  > "$T/fix/13.body"
printf 'in-review\n'                                 > "$T/fix/11.labels"
printf '## Blocked by\n\nNone\n'                    > "$T/fix/20.body"

# ─── Le lot du sixième run ────────────────────────────────────────────────────
# 17 : le remote refuse sa branche      → poussée refusée, pas un échec d'implémentation
# 18 × 19 : créent le même fichier      → aucune porte ne le voit, seul le merge le dit
# 18 cite #19 au futur dans un .md      → renvoi périmé, git fusionne ça en silence
# 21 : porte réduite + CI muette        → « vert » sans qu'aucune porte complète ait joué
for n in 17 18 19; do printf '## Blocked by\n\nNone\n' > "$T/fix/$n.body"; done
printf 'Verify: true\n\n## Blocked by\n\nNone\n'      > "$T/fix/21.body"

cat > "$T/bin/gh" <<'X'
#!/usr/bin/env bash
FIX="$HARNESS/fix"; log() { echo "$*" >> "$HARNESS/gh.log"; }
case "$1" in
  auth)  [[ "$2" == token ]] && echo faketoken; exit 0 ;;
  api)   exit 1 ;;                                  # aucune dépendance native
  label) case "$2" in
           list)   printf 'ready-for-agent\nin-review\nready-for-human\n' ;;
           create) log "label create $3" ;;
         esac; exit 0 ;;
  issue) case "$2" in
           view) n="$3"
             [[ "$*" == *"--json body"*   ]] && { cat "$FIX/$n.body" 2>/dev/null; exit 0; }
             [[ "$*" == *"--json title"*  ]] && { echo "titre du ticket $n"; exit 0; }
             [[ "$*" == *"--json labels"* ]] && { cat "$FIX/$n.labels" 2>/dev/null || echo enhancement; exit 0; }
             [[ "$*" == *"--json state"*  ]] && { echo OPEN; exit 0; } ;;
           edit)    log "edit $*" ;;
           comment) log "comment $3" ;;
           list)    printf '1\n2\n' ;;
         esac; exit 0 ;;
  pr)    case "$2" in
           # PR ouverte pour #99, seulement quand le test le demande : le premier run
           # a besoin que #99 n'en ait pas, pour vérifier le gel.
           list)   [[ -n "${OPEN_PR:-}" && "$*" == *"--head feat/99"* ]] && echo "feat/99"
                   exit 0 ;;
           create) for a in "$@"; do [[ ${prev:-} == --head ]] && b=$a; prev=$a; done
                   log "pr create $*"; echo "https://x/y/pull/9${b##*/}"; exit 0 ;;
           # NO_CHECKS       : le dépôt n'a pas de CI, --watch sort tout de suite.
           # NO_CHECKS_ONCE  : la CI existe mais n'est pas ENCORE enregistrée (le cas réel,
           #                   ~4 s après `gh pr create`) — afk doit réessayer.
           checks) [[ "$3" == --help ]] && { echo "  --fail-fast"; exit 0; }
                   nc() { echo "no checks reported on the 'feat/x' branch"; exit 1; }
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
printf '%s\n' "$p" >> "$HARNESS/prompt-$n.txt"   # le prompt est testable, comme le reste
printf '%s\n' "$*" >> "$HARNESS/args-$n.txt"     # les drapeaux passés à claude aussi

# L'objet de `claude -p --output-format json`, sur stdout : afk y lit la panne, le coût,
# le modèle réellement utilisé et l'identifiant de session. Une sortie vide ou libre
# ferait passer chaque session pour muette.
res() { printf '{"session_id":"sess-%s","total_cost_usd":0.5,"is_error":%s,"subtype":"%s",' \
          "$n" "${2:-false}" "${1:-success}"
        printf '"modelUsage":{"m":{"canonicalModel":"claude-sonnet-5"}},"result":"fini"}\n'; }
case "$n" in
  9|13) res; exit 0 ;;                 # sort proprement sans rien produire
  20) sleep 987654 ;;                  # ne finit jamais : cible de l'interruption
  2) echo "j'écris et je ne commite pas" > work-$n.txt; res; exit 0 ;;
  6) echo x > work-$n.txt; git add -A; git commit -qm "feat(#6): ok"
     res error_during_execution true; exit 1 ;;
  7) touch BROKEN; git add -A; git commit -qm "feat(#7): casse"; res; exit 0 ;;
  18) echo "export const a = 1" > shared.ts
      mkdir -p docs; echo "la liste : c'est #19 qui l'ouvrira" > docs/renvoi.md
      git add -A; git commit -qm "feat(#18): ok"; res; exit 0 ;;
  19) echo "export const b = 2" > shared.ts
      git add -A; git commit -qm "feat(#19): ok"; res; exit 0 ;;
  *) echo x > work-$n.txt; mkdir -p docs/adr; echo "adr $n" > "docs/adr/000$n-x.md"
     git add -A; git commit -qm "feat(#$n): ok"; res; exit 0 ;;
esac
X
chmod +x "$T/bin/gh" "$T/bin/claude"

# ─── Dépôt jetable ────────────────────────────────────────────────────────────
git init -qb master "$T/repo"; git init -q --bare "$T/origin.git"
cd "$T/repo"
git config user.email a@b; git config user.name t
mkdir -p docs/agents
echo "tracker: GitHub" > docs/agents/issue-tracker.md
{ printf '| r | l | s |\n|---|---|---|\n'
  for r in ready-for-agent ready-for-human in-review; do printf '| `%s` | `%s` | x |\n' "$r" "$r"; done
} > docs/agents/triage-labels.md
echo "# contexte" > CONTEXT.md
git add -A && git commit -qm init
git remote add origin "$T/origin.git"
git push -q origin master
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
# Un bloqueur livré à la main : branche poussée, PR ouverte, ticket toujours ouvert.
git checkout -qb feat/99 && echo 99 > from99.txt && git add -A && git commit -qm "feat(#99): à la main"
git push -q origin feat/99 && git checkout -q master && git branch -qD feat/99

# ─── Exécution ────────────────────────────────────────────────────────────────
# AFK_HOME détourné : sans ça, chaque exécution du harness ajouterait ses lignes au
# RUNS.md du vrai dépôt.
export HARNESS="$T" PATH="$T/bin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" AFK_HOME="$T"
export VERIFY_CMD='! test -f BROKEN' SETUP_CMD='' CI_TIMEOUT=1m CI_RETRY_WAIT=1
out=$(JOBS=3 bash "$AFK" 1 2 3 4 5 6 7 8 2>&1) || true
printf '%s\n' "$out" > "$T/run.log"

# ─── Assertions ───────────────────────────────────────────────────────────────
fail=0
want() {
  if grep -qE -- "$2" <<<"$out"; then printf '  ✓ %s\n' "$1"
  else printf '  ✗ %s\n     attendu : /%s/\n' "$1" "$2"; fail=1; fi
}
dont() {
  if grep -qE -- "$2" <<<"$out"; then printf '  ✗ %s\n     inattendu : /%s/\n' "$1" "$2"; fail=1
  else printf '  ✓ %s\n' "$1"; fi
}

want "les indépendants démarrent ensemble"        '▸ #1 démarré.*origin/master'
want "PR empilée sur son bloqueur"                '▸ #3 démarré.*base feat/1'
want "base topologique : feat/3 contient feat/1"  '▸ #4 démarré  \(base feat/3\)'
dont "un ancêtre n'est pas annoncé absorbé"       '#4 démarré.*absorbe'
want "PR ciblée sur le nom de branche"            'PR #91 sur master$'
want "filet -> draft"                             '#92 en DRAFT'
want "session plantée -> draft"                   '#96 en DRAFT'
want "bloqueur externe ouvert -> gelé"            '#5 gelé — bloqueurs ouverts hors run : 99$'
want "bloqueur du run échoué -> gel en cascade"   "#8 gelé — un bloqueur du run n'a pas été livré"
want "vérification rouge -> abandon après 2"      '#7 gelé|abandonné après 2 essais'
want "phase CI sur toutes les PR"                 '═══ CI \(5 PR'
want "intégration verte"                          'intégration : vert'
want "les drafts ne sont pas comptés verts"        'vert   \(3\) : 1 3 4'
want "le draft dit POURQUOI il est en draft"      'draft  \(2\) : #2 \(non commité\) #6 \(anormale\)'
want "1 rouge"                                    'rouge  \(1\) : 7'
want "2 gelés"                                    'gelé   \(2\) : 5 8'
want "drafts exclus du 1er essai"                 'vert au 1er essai : 3/6'
want "session plantée nommée, pas un code"        'session terminée anormalement \(error_during_execution\)'

grep -qE -- '--output-format json' "$T/args-1.txt" && grep -qE -- '--fallback-model sonnet' "$T/args-1.txt" &&
  echo "  ✓ session lancée en JSON, avec repli" || { echo "  ✗ drapeaux de session manquants"; fail=1; }

grep -qE '^\| #7 \| ko \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ résumé écrit" || { echo "  ✗ résumé absent ou faux"; fail=1; }
grep -qE '\| 0m[0-9]{2}s \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ durées consignées" || { echo "  ✗ durées manquantes"; fail=1; }
# Le journal traverse les runs et les projets : c'est le seul historique qui survive à
# l'écrasement de .afk/summary.md.
grep -qE '^\| [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} \| repo \| 8 \| 3 \| 0 \| 2 \| 1 \| 0 \| 2 \| 0 \| 3/6 \| sonnet-5 \| \$3\.50 \|' "$T/RUNS.md" &&
  echo "  ✓ le run est consigné dans RUNS.md" ||
  { echo "  ✗ run absent du journal"; sed -n '$p' "$T/RUNS.md" 2>/dev/null; fail=1; }

[[ -d "$T/repo/.afk/wt/7" && ! -d "$T/repo/.afk/wt/1" ]] &&
  echo "  ✓ worktree gardé sur échec, jeté sur succès" ||
  { echo "  ✗ mauvaise gestion des worktrees"; fail=1; }

# #4 part de feat/3, qui contient feat/1 : il doit hériter des ADR des DEUX ancêtres,
# et #1, qui n'a aucun bloqueur, ne doit pas voir la section du tout.
grep -qE '^  - docs/adr/0001-x\.md$' "$T/prompt-4.txt" 2>/dev/null &&
  grep -qE '^  - docs/adr/0003-x\.md$' "$T/prompt-4.txt" &&
  echo "  ✓ les décisions des ancêtres sont dans le prompt" ||
  { echo "  ✗ prompt sans les décisions héritées"; fail=1; }
[[ -f "$T/prompt-1.txt" ]] && ! grep -q 'HÉRITÉ' "$T/prompt-1.txt" &&
  echo "  ✓ sans bloqueur, rien d'hérité" ||
  { echo "  ✗ section héritée sur un ticket sans bloqueur"; fail=1; }


# ─── Second run : absorbé, Timeout:, in-review, faux vs vrai "aucun commit" ───
# En série : l'ordre de récolte est alors le seul possible, donc assertable.

out2=$(JOBS=1 bash "$AFK" 9 10 11 12 13 2>&1) || true
printf '%s\n' "$out2" > "$T/run2.log"
want2() {
  if grep -qE -- "$2" <<<"$out2"; then printf '  ✓ %s\n' "$1"
  else printf '  ✗ %s\n     attendu : /%s/\n' "$1" "$2"; fail=1; fi
}
echo
want2 "in-review retiré de la liste"              '#11 est in-review — ignoré'
want2 "ticket vidé par son prédécesseur"          '≡ absorbé'
want2 "absorbé compté à part"                     'absorbé \(1\) : 9'
want2 "absorbé ne gèle pas son dépendant"         'PR #910 sur master'
want2 "Timeout: du ticket honoré"                 'budget      : 90m   \(Timeout: du ticket\)'
want2 "Model: du ticket honoré"                   'modèle      : sonnet'
want2 "Effort: du ticket honoré"                  'effort      : high'
want2 "aucun commit + base rouge reste un échec"  "rouge  \(1\) : 13"
want2 "absorbé hors du vert au 1er essai"         'vert au 1er essai : 2/3'

grep -qE 'edit issue edit 9 .*--add-label in-review' "$T/gh.log" &&
  echo "  ✓ absorbé étiqueté in-review" || { echo "  ✗ absorbé mal étiqueté"; fail=1; }
grep -qE 'edit issue edit 13 .*--add-label ready-for-human' "$T/gh.log" &&
  echo "  ✓ vrai échec rendu à un humain" || { echo "  ✗ échec mal étiqueté"; fail=1; }
grep -qE 'pr create .*--head feat/9( |$)' "$T/gh.log" &&
  { echo "  ✗ un absorbé ne doit pas ouvrir de PR"; fail=1; } ||
  echo "  ✓ aucun PR pour un absorbé"
[[ "$(grep -c '^| 20' "$T/RUNS.md")" == 2 ]] &&
  echo "  ✓ un second run s'ajoute au journal, il ne l'écrase pas" ||
  { echo "  ✗ journal écrasé ou non ajouté"; fail=1; }
grep -qE '^\| #9 \| absorbé \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ résumé : absorbé" || { echo "  ✗ résumé sans absorbé"; fail=1; }
grep -qE -- '--model sonnet' "$T/args-12.txt" && grep -qE -- '--effort high' "$T/args-12.txt" &&
  echo "  ✓ Model:/Effort: transmis à claude" || { echo "  ✗ surcharges non transmises"; fail=1; }
# Deux essais à 0,5 : le coût est celui du TICKET, pas de sa dernière session.
grep -qE '^\| #13 \|.*\| sonnet-5 \|.*\| \$1\.0000 \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ résumé : modèle réel et coût cumulé" || { echo "  ✗ modèle ou coût absent du résumé"; fail=1; }
grep -qF 'claude --resume sess-13' "$T/repo/.afk/summary.md" &&
  echo "  ✓ un rouge se reprend à la main" || { echo "  ✗ pas de reprise proposée sur un rouge"; fail=1; }
grep -qF 'claude --resume sess-12' "$T/repo/.afk/summary.md" &&
  { echo "  ✗ reprise proposée sur un vert (worktree jeté)"; fail=1; } ||
  echo "  ✓ aucune reprise proposée sur un vert"

# ─── Troisième run : interruption ─────────────────────────────────────────────
# drop_worktree ne tournait que dans reap : un orchestrateur tué laissait derrière lui
# le worktree ET la session claude, orpheline et vivante.

echo
( JOBS=1 bash "$AFK" 20 > "$T/run3.log" 2>&1 ) & afkpid=$!
for _ in $(seq 60); do pgrep -f 'sleep 987654' >/dev/null && break; sleep 0.5; done
if pgrep -f 'sleep 987654' >/dev/null; then
  kill -TERM "$afkpid" 2>/dev/null
  wait "$afkpid" 2>/dev/null
  for _ in $(seq 20); do pgrep -f 'sleep 987654' >/dev/null || break; sleep 0.5; done
  pgrep -f 'sleep 987654' >/dev/null &&
    { echo "  ✗ session orpheline survivante"; pkill -f 'sleep 987654'; fail=1; } ||
    echo "  ✓ interruption : aucune session orpheline"
  grep -qE 'interruption — 1 session' "$T/run3.log" &&
    echo "  ✓ interruption annoncée" || { echo "  ✗ interruption silencieuse"; fail=1; }
else
  echo "  ✗ la session de test n'a jamais démarré"; kill "$afkpid" 2>/dev/null; fail=1
fi

# ─── Quatrième run : empiler sur un bloqueur livré hors run ───────────────────
# #99 est ouvert et n'est pas dans le run, mais sa branche est poussée et sa PR
# ouverte : le geler jusqu'au merge, c'est refuser d'empiler sur du travail livré.

echo
out4=$(OPEN_PR=1 JOBS=1 bash "$AFK" 5 2>&1) || true
printf '%s\n' "$out4" > "$T/run4.log"
want4() {
  if grep -qE -- "$2" <<<"$out4"; then printf '  ✓ %s\n' "$1"
  else printf '  ✗ %s\n     attendu : /%s/\n' "$1" "$2"; fail=1; fi
}
want4 "bloqueur hors run à PR ouverte : pas de gel" '#5 : bloqueur #99 livré hors run \(PR ouverte\) → base origin/feat/99'
want4 "le dépendant part de sa branche"             'PR #95 sur feat/99'
grep -qE 'pr create .*--base feat/99' "$T/gh.log" &&
  echo "  ✓ PR ciblée sur la branche du bloqueur" ||
  { echo "  ✗ PR mal ciblée"; fail=1; }

# ─── Cinquième run : deux bloqueurs directs indépendants ─────────────────────
# Le losange du premier run a toujours une branche dominante, donc `deepest_branch`
# trouve une base qui contient déjà l'autre et rien n'est mergé par-dessus. Ici aucune
# des deux ne contient l'autre : elle retombe sur la dernière, l'autre est absorbée par
# le worktree, et le dépendant doit hériter des DEUX mémoires — pas seulement de celle
# de sa base.
printf '## Blocked by\n\nNone\n'         > "$T/fix/14.body"
printf '## Blocked by\n\nNone\n'         > "$T/fix/15.body"
printf '## Blocked by\n\n- #14\n- #15\n' > "$T/fix/16.body"

echo
out5=$(JOBS=2 bash "$AFK" 14 15 16 2>&1) || true
printf '%s\n' "$out5" > "$T/run5.log"

grep -qE '▸ #16 démarré  \(base feat/15, absorbe feat/14\)' "$T/run5.log" &&
  echo "  ✓ frères indépendants : l'un sert de base, l'autre est absorbé" ||
  { echo "  ✗ absorption d'un frère indépendant ratée"; fail=1; }
grep -qE '^  - docs/adr/00014-x\.md$' "$T/prompt-16.txt" 2>/dev/null &&
  grep -qE '^  - docs/adr/00015-x\.md$' "$T/prompt-16.txt" &&
  echo "  ✓ les deux mémoires héritées, pas seulement celle de la base" ||
  { echo "  ✗ mémoire d'un seul bloqueur héritée"; fail=1; }
grep -qE 'vert   \(3\) : 14 15 16' "$T/run5.log" &&
  echo "  ✓ les trois verts" || { echo "  ✗ le dépendant n'est pas parti"; fail=1; }
# Une branche empilée mergée AVANT sa base conflicte par construction : l'intégration
# merge dans l'ordre topologique, pas dans l'ordre d'achèvement.
[[ "$(grep -o 'merge feat/[0-9]*' "$T/run5.log" | tail -1)" == "merge feat/16" ]] &&
  echo "  ✓ l'empilée est mergée après sa base" ||
  { echo "  ✗ ordre de merge non topologique"; fail=1; }

# ─── Sixième run : push refusé, même chemin créé deux fois, renvoi au futur ──
# Le remote refuse feat/17 comme GitHub refuse une branche qui touche .github/workflows/
# à un jeton sans la portée `workflow` : le travail est bon, c'est le transport qui casse.
cat > "$T/origin.git/hooks/update" <<'X'
#!/bin/sh
[ "$1" = refs/heads/feat/17 ] &&
  { echo "refusing to allow an OAuth App to create or update workflow" >&2; exit 1; }
exit 0
X
chmod +x "$T/origin.git/hooks/update"

echo
out6=$(NO_CHECKS_ONCE=1 JOBS=1 bash "$AFK" 17 18 19 2>&1) || true
printf '%s\n' "$out6" > "$T/run6.log"
want6() {
  if grep -qE -- "$2" <<<"$out6"; then printf '  ✓ %s\n' "$1"
  else printf '  ✗ %s\n     attendu : /%s/\n' "$1" "$2"; fail=1; fi
}
want6 "push refusé : sa propre ligne"          'poussée refusée \(1\) : 17'
want6 "push refusé : la raison du remote"      '#17 : .*refusing to allow an OAuth App'
want6 "push refusé n'est pas un rouge"         'rouge  \(0\) : —'
want6 "même chemin créé par deux branches"     'même chemin créé par plusieurs branches'
want6 "le chemin fautif est nommé"             'shared\.ts :.*feat/18.*feat/19|shared\.ts :.*feat/19.*feat/18'
want6 "ticket du run cité dans la doc mergée"  'docs/renvoi\.md:1:.*#19'
want6 "la CI pas encore enregistrée : réessai" '✓ #18 \(PR #918\) CI verte'
grep -qE '^\| #17 \| poussée refusée \|' "$T/repo/.afk/summary.md" &&
  echo "  ✓ résumé : poussée refusée" || { echo "  ✗ résumé sans la poussée refusée"; fail=1; }
grep -qE -- '- `feat/19` : shared\.ts' "$T/repo/.afk/summary.md" &&
  echo "  ✓ résumé : les fichiers en conflit, pas seulement la branche" ||
  { echo "  ✗ fichiers en conflit absents du résumé"; fail=1; }
grep -qE 'edit issue edit 17 .*ready-for-human' "$T/gh.log" &&
  { echo "  ✗ un push refusé ne doit pas rendre le ticket à un humain"; fail=1; } ||
  echo "  ✓ push refusé : aucun label changé"
[[ "$(head -n 1 "$T/repo/.afk/18.status")" == "result_initial=ko" ]] &&
  echo "  ✓ .status : la première ligne ne dit plus « ko » sur un vert" ||
  { echo "  ✗ .status : result=ko en tête"; head -n 1 "$T/repo/.afk/18.status"; fail=1; }

# ─── Septième run : vert, porte réduite, CI muette ───────────────────────────
# Les trois faits étaient imprimés séparément ; croisés, ils disent qu'aucune porte
# complète n'a jamais tourné sur ce ticket.
echo
out7=$(NO_CHECKS=1 JOBS=1 bash "$AFK" 21 2>&1) || true
printf '%s\n' "$out7" > "$T/run7.log"
grep -qE 'vert non prouvé \(1\) : 21' <<<"$out7" &&
  echo "  ✓ porte réduite + CI muette = vert non prouvé" ||
  { echo "  ✗ le vert non prouvé est encore compté vert"; fail=1; }
grep -qE 'vert   \(0\) : —' <<<"$out7" &&
  echo "  ✓ et il sort de la colonne « vert »" || { echo "  ✗ compté deux fois"; fail=1; }

echo
(( fail )) && { echo "ÉCHEC — trace : $T/run.log"; trap - EXIT; exit 1; }
echo "ok"
