# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ce que c'est

Trois scripts bash, aucune dépendance, aucun LLM dans l'orchestrateur. `afk.sh` enchaîne
des sessions `claude -p "/implement le ticket #N"` sur les tickets `ready-for-agent` d'un
repo GitHub configuré par `/setup-matt-pocock-skills`. Le README décrit le comportement
utilisateur ; ce fichier décrit les invariants internes.

`skills/` contient trois skills qui encadrent le run sans jamais entrer dedans :
`afk-setup` (écrire le `.afk.env`), `afk-preflight` (relire le lot avant de lancer),
`afk-debrief` (dépouiller le run au réveil). Ils proposent, ils n'agissent pas — un
skill qui lancerait `afk.sh` ou réétiquetterait un ticket remettrait du LLM dans la
boucle par la porte de derrière.

Le code et les commentaires sont en français — s'y tenir.

## Commandes

```bash
./check.sh          # parseurs purs, ~1 s, sans effet de bord
./harness.sh        # orchestrateur complet, claude et gh bouchonnés, remote nu local (~1 min)
bash -n afk.sh      # syntaxe seule (check.sh le fait déjà en premier)
./afk.sh -n 43 48   # le plan, sans rien lancer — utile pour valider l'ordonnanceur à la main
```

Pas de runner par test unitaire : `harness.sh` est monolithique, il tourne en entier.
Pour isoler, commenter les `want`/`want2`/`want4` non concernés, ou lire les traces
laissées dans son `$T` temporaire (`run.log`, `run2.log`, `gh.log`).

**Faire tourner `./harness.sh` après toute modification de la boucle** (ordonnanceur,
worker, worktrees, phases CI/intégration). Il a trouvé trois bugs à sa première exécution.

## Architecture

### Un seul fichier, deux moitiés

`afk.sh` se coupe en deux à la ligne `[[ -n "${AFK_LIB:-}" ]] && return 0` :

- **au-dessus** : les parseurs purs (`label_for`, `blocked_refs`, `meta_line`,
  `deepest_branch`, `peak_context`, `clashing_numbers`, `jval`, `jmodels`). `check.sh`
  fait `AFK_LIB=1 source ./afk.sh` pour les tester seuls. Ils ne doivent lire aucune
  globale et ne rien écrire. Les motifs de validation des surcharges (`RE_TIMEOUT`,
  `RE_MODEL`, `RE_EFFORT`) sont là aussi, pour que `check.sh` teste ceux qui servent
  vraiment plutôt qu'une copie.
- **en dessous** : config, garde-fous, et la boucle. Rien de tout ça n'est testable par
  `check.sh` — ça passe par `harness.sh`.

Ajouter un parseur ⇒ le placer au-dessus de la garde et lui ajouter un cas dans `check.sh`.

### Le pipeline

`plan_run` → `schedule` (→ `launch` → `worker`) → `ci_phase` → `integration_check` → `write_summary`

- **`plan_run`** lit chaque ticket une fois via `gh` et met tout en cache dans
  `.afk/<n>.{body,title,labels,verify,timeout}`. Le worker ne rappelle jamais l'API pour
  des métadonnées. Il classe aussi les bloqueurs en `DEPS` (dans le run, ou hors run mais
  à PR ouverte) et `EXT` (hors run, gelant).
- **`schedule`** boucle sur `deps_state` dont le **code de retour est un tri-état** :
  `0` prêt, `1` attendre, `2` gelé. Jusqu'à `JOBS` workers vivants.
- **`worker`** tourne dans un sous-shell, cwd = son worktree.

### Le protocole parent/enfant

Un worker est un sous-shell : **il ne peut rien écrire dans les tableaux du parent.** Il
dépose des lignes `clé=valeur` dans `.afk/<n>.status`, le parent les relit avec `sget`.
Toute nouvelle information remontée par un worker passe par là.

Clés : `result` (`ok` | `ko` | `absorbed`), `branch`, `base`, `base_ref`, `attempt`,
`pr`, `draft`, `draft_why`, `reason`, `dur`, `session`, `cost`, `model`. `draft` est un
drapeau posé sur un `ok`, pas un résultat.

Le fichier est **append-only** et `sget` lit la dernière ligne. La valeur prudente
écrite au démarrage s'appelle donc `result_initial`, pas `result` : un humain qui fait
`cat` ou `grep result=` sur un ticket vert lisait `result=ko` en tête. Un `result`
absent vaut rouge (`reap` le traite dans sa branche par défaut).

`reap` traduit ces statuts en tableaux du parent (`OK` `KO` `SKIP` `DRAFT` `ABSORBED`
`PUSH_KO` `BRANCH_OF` `FIRST_TRY`), qui alimentent ensuite `ci_phase`, `integration_check`
et le bilan. `GREEN` et `UNPROVEN` sont calculés au bilan seulement : `OK` reste la liste
brute des tickets qui ont ouvert une PR, `GREEN` en retire ce qu'aucune porte complète
n'a vu (draft, ou porte réduite + CI non concluante). C'est `GREEN` qui s'affiche.

### Isolation

Un ticket = un worktree `.afk/wt/<n>` sur `feat/<n>`, créé depuis `origin/<base>`.
**L'arbre principal n'est jamais touché** — aucun `checkout`, `pull` ni `reset`. Toute
opération git d'un worker doit rester dans son worktree (`git -C "$wt"` depuis le parent).
Un worktree vert est jeté, un rouge est gardé : c'est l'artefact de debug.

`set -uo pipefail`, **sans `-e`** : un échec de worker est un résultat, pas une raison
d'arrêter le run.

### La session

`claude -p … --output-format json`, jamais `--resume` : la sortie est un objet, pas un
log. `jval` y lit `subtype` (la panne se NOMME au lieu de rendre un code), `session_id`
(le bilan en fait un `claude --resume` pour les rouges, dont le worktree est gardé),
`total_cost_usd` (cumulé sur les essais du ticket) ; `jmodels` lit le modèle réellement
utilisé, seule façon de voir un repli `FALLBACK_MODEL`. Ajouter un drapeau de session
implique de le passer par `copts` — et de vérifier que le faux `claude` du harness rend
toujours un objet lisible, sinon chaque session passe pour muette.

### Le prompt

`build_prompt` reçoit `head0` — le HEAD d'AVANT la session — et pas `HEAD` :
`inherited_note` s'en sert pour lister ce que les bloqueurs ont livré
(`git diff --name-only "$BASE_REF...$head0"`). À l'essai 2, `HEAD` porte déjà le travail
de l'agent, qui n'a rien à apprendre de lui-même. Le faux `claude` du harness recopie
son prompt dans `$T/prompt-<n>.txt` : le prompt est testable comme le reste.

### Duplication assumée

Le bloc `DRY_RUN` refait le calcul de base/absorption de `launch()` (les branches du run
n'existent pas encore, `deepest_branch` retombe donc sur son repli). **Les deux doivent
rester d'accord** — modifier l'un sans l'autre fait mentir `-n`.

### Auth git

`setup_git_auth` réécrit github.com en HTTPS et branche le credential helper de `gh`,
uniquement via `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` exportés. **Ne jamais écrire dans
`.git/config`** : le token ne doit pas toucher le disque et la config du repo hôte ne
doit pas bouger. Les index sont contigus — ajouter une clé implique d'incrémenter `COUNT`.

## Toucher au harness

`harness.sh` bouchonne `claude` et `gh` par deux scripts dans un `$PATH` temporaire.
**Ajouter un appel `gh` dans `afk.sh` implique de le gérer dans le faux `gh`** — sinon il
tombe dans le `exit 0` final et rend une chaîne vide, ce qui se manifeste très loin de la
cause. Même chose pour un nouveau comportement d'agent : il se simule par un cas dans le
faux `claude`, indexé sur le numéro de ticket extrait du prompt.

Les sept runs du harness sont indépendants et ordonnés : parallèle (DAG en losange,
filet, crash, gel), série (absorbé, `Timeout:`, `in-review`), interruption, empilement
sur une PR ouverte hors run, deux bloqueurs directs indépendants (base + absorption,
double héritage), push refusé par le remote + même chemin créé deux fois + renvoi au
futur, et porte réduite avec CI muette. Les numéros de ticket portent leur scénario
(voir l'en-tête du fichier) — réutiliser un numéro existant pour autre chose casse les
assertions.

Le remote nu porte un hook `update` qui refuse `feat/17` : c'est ainsi qu'on simule un
`git push` rejeté sans réseau. Et le faux `gh pr checks` obéit à `NO_CHECKS` (le dépôt
n'a pas de CI) et `NO_CHECKS_ONCE` (la CI existe mais n'est pas encore enregistrée) —
les deux situations que `--watch` rendait par la même phrase.

## Les journaux

Écrits à la main, une entrée par événement, jamais une par commit — `git log` fait déjà
ça, et mieux :

- `CHANGELOG.md` — un changement de **comportement observable**. À compléter en même
  temps que le changement, pas après.
- `docs/propositions.md` — une idée proposée, avec son verdict et le raisonnement,
  **y compris les refus** : une idée retenue laisse un commentaire dans le code, une
  idée refusée ne laisse rien et revient. Écarter une proposition sans l'y écrire,
  c'est accepter de refaire le raisonnement.
- `docs/defauts.md` — un défaut d'afk constaté **en vrai pendant un run**, numéroté.
  Un commentaire du code peut y renvoyer (`défaut 17`). N'y va que ce qui aurait cassé
  de la même façon sur n'importe quel dépôt : les problèmes du projet travaillé se
  corrigent là-bas. Écrit par `/afk-debrief` ou à la main.

Écrit par la machine :

- `RUNS.md` — une ligne par run, ajoutée par `append_run_log` à la toute fin. Les
  faits, pas un jugement. Il vit dans `$AFK_HOME`
  (le dépôt du script, pas le projet travaillé) parce que c'est le seul endroit monté
  dans tous les projets, et parce que `.afk/summary.md` est écrasé au run suivant.
  `harness.sh` détourne `AFK_HOME` : sans ça ses runs de test s'y ajouteraient.

Le pourquoi d'un choix déjà implémenté reste dans le commentaire à côté du code — ces
fichiers ne le dupliquent pas, ils y renvoient.

## Surface de confiance

Les lignes `Verify:` et `Timeout:` d'un ticket sont exécutées / passées telles quelles.
Les tickets font partie de la surface de confiance, au même titre que le
`--permission-mode bypassPermissions` des sessions.
