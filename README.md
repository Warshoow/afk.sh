# afk

Boucle externe qui enchaîne `/implement` sur les tickets `ready-for-agent`.
Un ticket = une session Claude neuve = une PR. Aucun LLM dans l'orchestrateur :
il ordonne, il lance, il vérifie, il pousse, il étiquette.

Se branche sur le workflow [mattpocock/skills](https://github.com/mattpocock/skills) :

```
/wayfinder ou /to-spec  →  /to-tickets  →  /triage  →  ./afk.sh  →  tu merges
                            (issues +      (label     (N sessions
                             Blocked by)    ready-      headless)
                                            for-agent)
```

## Prérequis

- Repo configuré par `/setup-matt-pocock-skills`, tracker **GitHub** (`docs/agents/issue-tracker.md`).
- `claude`, `gh`, `git`, `timeout` dans le PATH. Working tree propre.
- `gh auth login` fait : le token sert aussi à pousser, sans passphrase.
- Les skills mattpocock installés dans le `CLAUDE_CONFIG_DIR` utilisé par le script
  (défaut `~/.claude-perso`) — sinon `/implement` n'existe pas dans la session headless.

## Usage

```bash
./afk.sh                      # tous les tickets ready-for-agent, en série
./afk.sh 43 48 49 50          # ceux-là
./afk.sh -j 3 43 48 49 50     # en parallèle partout où le DAG le permet
./afk.sh -n -j 3 43 48 49 50  # le plan : vagues, bases, piles, gelés, porte effective
VERIFY_CMD="npm test" ./afk.sh
CI_TIMEOUT=0 ./afk.sh         # ne pas attendre la CI
./check.sh                    # teste les parseurs
./harness.sh                  # teste l'orchestrateur (claude et gh bouchonnés)
```

Aucune interaction humaine par défaut : pas de passphrase (voir plus bas), pas de
pause (`CHECKPOINT_EVERY=0`), pas de prompt de permission. `nohup ./afk.sh -j 3 &`
et tu relis au réveil.

| Env | Défaut | |
|---|---|---|
| `VERIFY_CMD` | `pnpm typecheck && pnpm test && pnpm lint` | la définition de "fini", surchargeable par ticket |
| `MAX_ATTEMPTS` | `2` | 1 essai + 1 reprise, en session neuve |
| `TIMEOUT` | `45m` | borne un run (`--max-turns` n'existe plus en 2.1.x), surchargeable par ticket |
| `CI_TIMEOUT` | `15m` | attente de la CI après ouverture de PR ; `0` = ne pas consulter |
| `INTEGRATION` | `1` | passe d'intégration des branches vertes en fin de run ; `0` = sauter |
| `LABEL` / `LABEL_REVIEW` / `LABEL_KO` | lus dans `docs/agents/triage-labels.md` | |
| `MEMORY_RE` | racine + `apps/*` + `packages/*` | chemins qui comptent comme "décision capturée" |
| `BASE_BRANCH` | branche par défaut du remote | |
| `JOBS` | `1` | sessions simultanées ; `auto` = `nproc/4` borné à 4 |
| `VERIFY_LOCK` | `1` | sérialise les vérifications quand `JOBS > 1` |
| `SETUP_CMD` | déduit du lockfile | amorçage d'un worktree (`pnpm install --frozen-lockfile`) |
| `SEED_GLOBS` | `.env`, `apps/*/.env`, … | fichiers gitignorés recopiés dans chaque worktree |
| `KEEP_WORKTREES` | `0` | garder les worktreees verts aussi (les rouges le sont toujours) |
| `CHECKPOINT_EVERY` | `0` | pause pour relire les PRs ; `0` = jamais |
| `STACK_ON_OPEN_PR` | `1` | empiler sur un bloqueur hors run dont la PR est ouverte, au lieu de geler |
| `ALLOW_REVIEW` | `0` | relancer un ticket déjà `in-review` (il a déjà une PR ouverte) |

## Parallélisme

`-j N` lance N tickets à la fois. **Un ticket = un worktree git** (`.afk/wt/<n>`) :
deux agents dans le même arbre de travail se piétinent, et c'est aussi ce qui libère
l'arbre principal — le script n'y fait plus aucun `checkout`, `pull` ni `reset`. Tu
peux continuer à bosser dedans, sur la branche que tu veux, pendant qu'un run tourne.
Les worktrees partent de `origin/<base>`, jamais de la branche locale.

L'ordonnanceur respecte le DAG des bloqueurs : un ticket ne démarre que quand tous
ses bloqueurs du run sont verts, et un bloqueur rouge gèle ses dépendants (leur base
n'existe pas). `-n` imprime les vagues, donc exactement où le parallélisme est
possible et où le DAG l'interdit :

```
vague 1 (parallèle, 3 à la fois) :
  #43   base origin/master  [mobile] Le logo-toile se transforme en radar…
  #48   base origin/master  [backend][mobile] Critique : un commentaire attaché…
vague 2 (séquentiel) :
  #49   base feat/48        [backend][mobile] Signalement d'un standard…
vague 3 (séquentiel) :
  #50   base feat/49        [admin] File de modération des signalements
```

**Les sessions Claude tournent en parallèle, les vérifications font la queue.** Une
session ne partage rien ; une vérification tient le Postgres de test, des ports et la
RAM d'un `turbo typecheck`. Deux `node ace test` simultanés sur la même base se
détruisent. D'où `VERIFY_LOCK=1` : `flock` sérialise vérifications et installs, la
partie longue reste parallèle. Mesuré sur hexa-zero : amorçage d'un worktree 19 s
(worktree 1 s, `pnpm install` 4 s en hardlinks depuis le store local, `typecheck`
13 s) — négligeable devant une session.

Une branche ne peut être checkout que dans un seul worktree : si tu as `feat/48`
sorti dans ton arbre, `-n` te le dit avant de lancer quoi que ce soit.

## Ce qu'il fait, ticket par ticket

1. **Frontière.** Lit les bloqueurs (dépendances natives GitHub, sinon la section
   `## Blocked by` écrite par `/to-tickets`). Bloqueur encore ouvert et non traité
   dans ce run → ticket gelé, pas lancé — sauf s'il a une PR ouverte : sa branche est
   poussée et lisible, on empile dessus comme sur un bloqueur du run
   (`STACK_ON_OPEN_PR=0` pour geler quand même).
2. **PRs empilées.** Bloqueur livré dans ce run mais pas encore mergé → la branche
   part de la sienne, et sa PR cible sa branche. Plusieurs bloqueurs → la base est
   celle qui contient déjà les autres (`merge-base --is-ancestor`), les restantes
   sont mergées ; conflit → gelé.
3. **Session neuve** : `claude -p "/implement le ticket #N …"`, jamais `--resume`.
   Reprendre une session qui vient d'échouer, c'est repartir du contexte qui a échoué.
   La reprise reçoit les 60 dernières lignes de l'échec, dans une session vierge.
4. **Vérification externe.** C'est le script qui note la copie, pas l'agent.
   Zéro commit produit → la porte est passée **sur la base** pour trancher : rouge,
   c'est un échec ; verte, le ticket est **absorbé** (voir plus bas).
5. **Vert** → push, PR `Closes #N` sur la bonne base, ticket basculé en `in-review`,
   puis attente de la CI. **Rouge** → `ready-for-human` + commentaire avec la sortie
   d'échec. La machine à états de `/triage` continue de tourner pendant que tu dors.
6. **Worktree jeté** si vert, **gardé** si rouge : c'est là qu'on va lire ce qui
   s'est passé, avec les `node_modules` déjà en place.
7. **CI** en fin de run, toutes les PR surveillées en parallèle (attendre dans le
   worker immobiliserait un slot pour du polling).
8. **Intégration** en fin de run : toutes les branches vertes mergées dans un
   worktree jetable, puis `VERIFY_CMD`. Rapporte ; ne touche à aucune PR.

## Logs

Tout est dans `.afk/` (auto-ignoré), une famille de fichiers par ticket :

| Fichier | Contenu |
|---|---|
| `<n>.out` | la trace de l'orchestrateur pour ce ticket — ce que tu lis d'abord |
| `<n>-<essai>.log` | la session Claude complète |
| `<n>-verify.txt` / `<n>-fail.txt` | la sortie de la porte, dernier échec conservé |
| `<n>-setup.log` | l'install du worktree |
| `<n>-ci.txt` | la sortie de `gh pr checks` |
| `<n>.status` | le verdict machine (`result`, `pr`, `draft`, `attempt`) |
| `summary.md` | le tableau du run : résultat, PR, essai, CI, intégration |

En série, la trace sort aussi à l'écran en direct. En parallèle elle est mise de côté
et déversée d'un bloc quand le ticket finit, sinon les sorties s'entrelacent ; une
ligne `… en cours : #48 (3m12) #50 (1m04)` toutes les deux minutes dit qui travaille.

## Porte de vérification par ticket

`VERIFY_CMD` est une porte unique pour tous les tickets. Sur un monorepo, c'est
contradictoire avec « reste dans le périmètre du ticket » : un ticket backend qui touche
un contrat typé de bout en bout casse le typecheck du client, et l'agent doit sortir de
son périmètre pour rendre du vert.

Un ticket peut donc déclarer sa propre porte, avec une ligne dans son corps :

```
Verify: pnpm turbo typecheck --filter=@hexa-zero/backend
```

Le script la lit et l'utilise à la place de `VERIFY_CMD` — pour ce ticket seulement.
La ligne est exécutée telle quelle : les tickets font partie de la surface de confiance,
au même titre que le `bypassPermissions` de la session.

C'est aussi la réponse au risque symétrique du taux de vert : **100 % de vert ne veut rien
dire si la porte ne vérifie rien.** Sur un ticket d'aspect, « vert » signifie « ça compile ».

## Budget de temps par ticket

`TIMEOUT` est global, la taille d'un ticket ne l'est pas : une refonte — migration,
formule, gardes, tests, quatre docs — ne rentre pas dans le gabarit d'un ticket moyen,
et se fait couper au milieu. Même endroit, même parseur que `Verify:` :

```
Timeout: 90m
```

Le format est celui de `timeout(1)` (`90m`, `2h`, `3600`). Une valeur d'une autre forme
est ignorée : passée telle quelle, elle empêcherait la session de démarrer.

## Quand un ticket n'a plus rien à faire

Un ticket peut être livré par son prédécesseur — l'agent du ticket d'avant est allé plus
loin que son périmètre, ce qui est la norme dès qu'un contrat typé traverse les apps.
« L'agent a échoué » et « il n'y avait plus rien à faire » sortaient tous les deux en
`aucun commit` : deux essais brûlés par ticket, puis `ready-for-human` pour une raison
fausse.

Quand la session ne produit aucun commit, la porte tourne donc **sur la base** :

- **rouge** → l'agent n'a effectivement rien produit, essai suivant puis `ready-for-human` ;
- **verte** → le ticket est **absorbé** : basculé en `in-review` avec un commentaire, pas
  de PR, ni rouge ni « vert au 1er essai ». Ses dépendants partent de la base qu'il a
  lui-même utilisée, au lieu de geler derrière un faux échec.

## Quand une session se termine mal

Une session Claude peut mourir après avoir produit du travail complet, ou à 60 % : la
porte rend exactement le même vert dans les deux cas. Le script ne jette pas le travail
— le filet commite l'arbre sale, avec le titre du ticket comme message — mais :

- la PR sort **en draft**, avec le code de sortie et le chemin du log dans son corps ;
- le ticket ne compte pas comme « vert au premier essai » ;
- il apparaît dans la ligne `draft` du bilan.

Même traitement quand l'agent n'a pas commité de lui-même : c'est une anomalie, pas un
succès.

## Ctrl-C

Un outil qui tourne des heures se fait interrompre. Sur `INT`/`TERM`, l'orchestrateur tue
la **descendance** de chaque worker — le worker est un sous-shell, `claude` et `pnpm` sont
dessous, et tuer le sous-shell seul les laissait orphelins et vivants — puis récolte les
worktrees des tickets verts ou absorbés. Ceux des rouges et des interrompus restent :
c'est là qu'on va lire ce qui s'est passé.

## Git sans clavier

Le remote est souvent en SSH, avec une clé à passphrase et sans `ssh-agent` — chaque
`pull` et chaque `push` réclament alors le clavier, dans un outil qui veut dire *away
from keyboard*. Pire : en détaché, le push dort sans rien afficher, indiscernable d'un
ticket qui prend du temps.

Le script réécrit `github.com` en HTTPS pour la durée du run et sert le token `gh` via
son credential helper. Rien n'est écrit dans `.git/config`, le token ne touche jamais le
disque, et la configuration d'origine du repo n'est pas modifiée (tout passe par
`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`).

## Tests

- `./check.sh` — les quatre parseurs (`label_for`, `blocked_refs`, `verify_override`,
  `deepest_branch`). Rapide, sans effet de bord.
- `./harness.sh` — l'orchestrateur en entier, sans réseau ni LLM : `claude` et `gh`
  bouchonnés, remote nu local, 8 tickets couvrant un DAG en losange, le filet, une
  session plantée, un bloqueur externe ouvert, un gel en cascade, la phase CI et
  l'intégration. 20 assertions. Il a trouvé trois bugs à sa première exécution —
  le faire tourner après toute modification de la boucle.

## Limites assumées

- Ne merge rien. La revue humaine reste la dernière porte.
- Le parallélisme ne s'applique qu'aux tickets indépendants. Une chaîne de quatre
  tickets empilés reste une chaîne : `-j 8` n'y changera rien.
- Un `pnpm install` par worktree. Hardlinks depuis le store, donc quasi gratuit en
  disque, mais un store distant ou un `nodeLinker` non hoisté changerait la note.
- La passe d'intégration détecte les collisions, elle ne les résout pas.
- `--permission-mode bypassPermissions` : à faire tourner dans un conteneur si le repo
  n'est pas jetable.
