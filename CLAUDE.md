# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ce que c'est

Trois scripts bash, aucune dépendance, aucun LLM dans l'orchestrateur. `afk.sh` enchaîne
des sessions `claude -p "/implement le ticket #N"` sur les tickets `ready-for-agent` d'un
repo GitHub configuré par `/setup-matt-pocock-skills`. Le README décrit le comportement
utilisateur ; ce fichier décrit les invariants internes.

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

- **au-dessus** : les cinq parseurs purs (`label_for`, `blocked_refs`, `verify_override`,
  `timeout_override`, `deepest_branch`). `check.sh` fait `AFK_LIB=1 source ./afk.sh` pour
  les tester seuls. Ils ne doivent lire aucune globale et ne rien écrire.
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
`pr`, `draft`, `reason`, `dur`. `draft` est un drapeau posé sur un `ok`, pas un résultat.

`reap` traduit ces statuts en tableaux du parent (`OK` `KO` `SKIP` `DRAFT` `ABSORBED`
`BRANCH_OF` `FIRST_TRY`), qui alimentent ensuite `ci_phase`, `integration_check` et le bilan.

### Isolation

Un ticket = un worktree `.afk/wt/<n>` sur `feat/<n>`, créé depuis `origin/<base>`.
**L'arbre principal n'est jamais touché** — aucun `checkout`, `pull` ni `reset`. Toute
opération git d'un worker doit rester dans son worktree (`git -C "$wt"` depuis le parent).
Un worktree vert est jeté, un rouge est gardé : c'est l'artefact de debug.

`set -uo pipefail`, **sans `-e`** : un échec de worker est un résultat, pas une raison
d'arrêter le run.

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

Les quatre runs du harness sont indépendants et ordonnés : parallèle (DAG en losange,
filet, crash, gel), série (absorbé, `Timeout:`, `in-review`), interruption, et empilement
sur une PR ouverte hors run. Les numéros de ticket portent leur scénario (voir l'en-tête
du fichier) — réutiliser un numéro existant pour autre chose casse les assertions.

## Les deux journaux

- `CHANGELOG.md` — une entrée par changement de **comportement observable**, pas par
  commit. À compléter en même temps que le changement, pas après.
- `docs/propositions.md` — une entrée par idée proposée, avec son verdict et le
  raisonnement, **y compris les refus** : une idée retenue laisse un commentaire dans le
  code, une idée refusée ne laisse rien et revient. Écarter une proposition sans l'y
  écrire, c'est accepter de refaire le raisonnement.

Le pourquoi d'un choix déjà implémenté reste dans le commentaire à côté du code — ces
deux fichiers ne le dupliquent pas, ils y renvoient.

## Surface de confiance

Les lignes `Verify:` et `Timeout:` d'un ticket sont exécutées / passées telles quelles.
Les tickets font partie de la surface de confiance, au même titre que le
`--permission-mode bypassPermissions` des sessions.
