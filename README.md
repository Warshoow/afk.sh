# afk

Boucle externe qui enchaîne `/implement` sur les tickets `ready-for-agent`.
Un ticket = une session Claude neuve = une PR. Aucun LLM dans l'orchestrateur :
il ordonne, il lance, il vérifie, il pousse, il étiquette.

Se branche sur le workflow [mattpocock/skills](https://github.com/mattpocock/skills).

**Une fois par projet**, jamais à refaire :

```
/setup-matt-pocock-skills   →   /afk-setup
 (docs/agents/, les labels        (.afk.env : la commande qui dit
  de triage, la mémoire            « ce ticket est fini » ici)
  de projet)
```

**À chaque lot de travail** :

```
/grill-with-docs  →  /to-tickets  →  /triage  →  /afk-preflight
 (clarifier ce      (issues +        (label       (relire le lot :
  qu'il y a          Blocked by)      ready-       ce qui ferait
  à faire)                            for-agent)   perdre la nuit)

        →  ./afk.sh  →  /afk-debrief  →  tu merges
           (N sessions    (classer les
            headless)      non-verts)
```

Entre `/afk-preflight` et `/afk-debrief`, tu dors.

## Prérequis

- Repo configuré par `/setup-matt-pocock-skills`, tracker **GitHub** (`docs/agents/issue-tracker.md`).
- Un `.afk.env` à la racine, écrit par `/afk-setup` (voir [Config par projet](#config-par-projet)).
  Sans lui, la porte de vérification reste celle d'un monorepo pnpm — fausse partout ailleurs.
- `claude`, `gh`, `git`, `timeout` dans le PATH. Working tree propre.
- `gh auth login` fait : le token sert aussi à pousser, sans passphrase.
- Les skills mattpocock installés dans le `CLAUDE_CONFIG_DIR` utilisé par le script
  (défaut `~/.claude`) — sinon `/implement` n'existe pas dans la session headless.

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
| `INTEGRATION_VERIFY_CMD` | `$VERIFY_CMD` | porte de la passe d'intégration — y mettre la forme **non cachée** (`turbo … --force`) |
| `MAX_ATTEMPTS` | `2` | 1 essai + 1 reprise, en session neuve |
| `TIMEOUT` | `45m` | borne un run (`--max-turns` n'existe plus en 2.1.x), surchargeable par ticket |
| `CI_TIMEOUT` | `15m` | attente de la CI après ouverture de PR ; `0` = ne pas consulter |
| `MODEL` | vide | modèle des sessions ; vide = le défaut de `claude`, surchargeable par ticket |
| `EFFORT` | vide | niveau de réflexion (`low`…`max`) ; vide = le défaut, surchargeable par ticket |
| `FALLBACK_MODEL` | `sonnet` | modèle de repli quand le principal est indisponible ; vide = pas de repli |
| `INTEGRATION` | `1` | passe d'intégration des branches vertes en fin de run ; `0` = sauter |
| `LABEL` / `LABEL_REVIEW` / `LABEL_KO` | lus dans `docs/agents/triage-labels.md` | |
| `MEMORY_RE` | racine + `apps/*` + `packages/*` | chemins qui comptent comme "décision capturée" |
| `BASE_BRANCH` | branche par défaut du remote | |
| `JOBS` | `1` | sessions simultanées ; `auto` = `nproc/4` borné à 4 |
| `VERIFY_LOCK` | `1` | sérialise les vérifications quand `JOBS > 1` |
| `SETUP_CMD` | déduit du lockfile | amorçage d'un worktree (`pnpm install --frozen-lockfile`) — reçoit `AFK_TICKET` et `AFK_WORKTREE` |
| `SEED_GLOBS` | `.env`, `apps/*/.env`, … | fichiers gitignorés recopiés dans chaque worktree |
| `KEEP_WORKTREES` | `0` | garder les worktreees verts aussi (les rouges le sont toujours) |
| `AFK_HOME` | le dossier du script | où s'écrit `RUNS.md` — à détourner si le dépôt d'afk est monté en lecture seule |
| `CHECKPOINT_EVERY` | `0` | pause pour relire les PRs ; `0` = jamais |
| `STACK_ON_OPEN_PR` | `1` | empiler sur un bloqueur hors run dont la PR est ouverte, au lieu de geler |
| `ALLOW_REVIEW` | `0` | relancer un ticket déjà `in-review` (il a déjà une PR ouverte) |

## Config par projet

Les défauts du tableau ci-dessus sont taillés pour un monorepo pnpm. Un repo Python,
PHP ou Rust n'a pas la même définition de « fini » — et même sur un repo npm,
`npm test` ouvre souvent un watcher qui ne rend jamais la main (`vitest` sans `run`) :
le ticket meurt alors sur `TIMEOUT`, pour une raison qui n'a rien à voir avec lui.

Un repo déclare donc sa porte dans un `.afk.env` à sa racine, versionné à côté du code :

```bash
# .afk.env — ownhomemap
# `pnpm test` = vitest en watch : il ne rend jamais la main. C'est test:run qu'il faut.
VERIFY_CMD="${VERIFY_CMD:-pnpm lint && pnpm test:run}"
```

Il est sourcé après les arguments : **ligne de commande > `.afk.env` > défaut du
script**, d'où le `${VAR:-...}`. N'y mettre que ce qui diffère.

C'est du shell du repo, exécuté tel quel — même surface de confiance que les lignes
`Verify:` d'un ticket.

### La porte de l'intégration se sépare de celle des tickets

Un cache de build peut rendre une porte creuse. Turbo, par exemple, hache les fichiers
**suivis par git** : un fichier généré et gitignoré n'entre pas dans la clé, donc un worktree
qui ne l'a pas produit **la même empreinte** que l'arbre principal qui l'a → cache hit, logs
rejoués, rien d'exécuté. La porte affiche `$ tsc --noEmit` et un ✓ sans avoir compilé une
ligne, et si le cache est partagé entre worktrees le faux vert voyage. Sur un run réel, huit
tickets ont été verts sur un défaut que seule la passe d'intégration a vu — elle présentait la
première combinaison de contenus jamais vue, donc un cache miss, donc une exécution.

**`Cached: n cached` est une ligne de sécurité, pas une statistique de performance.**

`INTEGRATION_VERIFY_CMD` permet de payer la forme honnête **une fois**, sur la combinaison,
sans l'imposer à chaque ticket :

```bash
# .afk.env
INTEGRATION_VERIFY_CMD="${INTEGRATION_VERIFY_CMD:-pnpm exec turbo typecheck lint --force && pnpm test}"
```

La passe annonce sa porte quand elle diffère, et le résumé consigne les deux.

### Isoler un worktree de ses voisins

Deux worktrees en parallèle sont deux copies du code, pas deux copies de ce qui vit
**autour** : une base de test, un port, un bucket. Si le repo fixe le nom de sa base de
test en dur dans un fichier versionné, les deux suites la migrent et la rollbackent en même
temps — et le ticket courant est noté rouge pour la migration d'un voisin. C'est arrivé, et
le symptôme n'accuse jamais le vrai coupable (`unable to release database lock`, ou un
`Schema file "…033_…" is missing` qui vient d'un fichier absent de CETTE branche).

`SETUP_CMD` tourne déjà **dans** le worktree et **sous le verrou `install`**, donc sérialisé.
Il reçoit de quoi se distinguer :

| variable | valeur |
|---|---|
| `AFK_TICKET` | le numéro du ticket, ou `_integration` pour la passe finale |
| `AFK_WORKTREE` | le chemin absolu du worktree |

Au projet d'en faire ce qu'il veut — c'est lui qui sait de quoi il doit s'isoler :

```bash
# .afk.env
SETUP_CMD="${SETUP_CMD:-scripts/afk-worktree-setup.sh && pnpm install --frozen-lockfile --prefer-offline}"
```

```bash
# scripts/afk-worktree-setup.sh — une base de test par worktree
[ -n "$AFK_TICKET" ] || exit 0          # lancé hors afk : rien à isoler
db="myapp_test_${AFK_TICKET#_}"
echo "DB_DATABASE=$db" > apps/backend/.env.test.local
dropdb --if-exists "$db" && createdb "$db"
```

Rien n'est détruit à la sortie : une base vide par numéro de ticket, recréée au prochain
run du même ticket. Si ça devient gênant, c'est un `dropdb` dans un `TEARDOWN_CMD` qui
n'existe pas encore.

Le skill `/afk-setup` (dans [`skills/afk-setup/`](skills/afk-setup/SKILL.md)) lit le
repo — scripts, workflows CI, `CLAUDE.md` —, éprouve la commande proposée puis écrit
ce fichier. Une fois par projet, après `/setup-matt-pocock-skills` et avant le premier
run. Pour l'installer :

```bash
ln -s "$PWD/skills/afk-setup" ~/.claude/skills/afk-setup   # ou ton CLAUDE_CONFIG_DIR
```

## Les deux skills du run

`afk.sh` n'a aucun LLM : il ordonne, lance, vérifie, pousse, étiquette. Le jugement est
avant et après, dans une session interactive.

[`/afk-preflight`](skills/afk-preflight/SKILL.md) — **entre `/triage` et le run.** Lit
le plan (`./afk.sh -n`) et le corps des tickets, et dit ce qui va coûter la nuit : un
ticket gelé par un bloqueur déjà mergé mais non fermé, un critère d'acceptation
qu'aucune porte ne peut voir, une refonte sans `Timeout:`, deux tickets de la même vague
sur les mêmes fichiers, un ticket mécanique qui n'a pas besoin du modèle des refontes.
Il propose les corrections, il ne les applique pas et ne lance pas le run.

[`/afk-debrief`](skills/afk-debrief/SKILL.md) — **au réveil, avant de merger.** Lit
`.afk/summary.md` et les traces, et classe chaque non-vert par cause : porte fausse,
worktree mal amorcé, ticket trop gros, vrai échec. Il sait distinguer un rouge dû au
ticket d'un rouge dû à l'environnement, et propose quoi remettre en `ready-for-agent`
pour la nuit suivante.

```bash
ln -s "$PWD/skills/afk-preflight" ~/.claude/skills/afk-preflight
ln -s "$PWD/skills/afk-debrief"   ~/.claude/skills/afk-debrief
```

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
   `--resume` reste offert à un humain sur un ticket rouge, à la fin du bilan.
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
| `<n>-<essai>.json` | ce que la session raconte d'elle-même : panne, coût, modèle, `session_id` |
| `<n>-verify.txt` / `<n>-fail.txt` | la sortie de la porte, dernier échec conservé |
| `<n>-setup.log` | l'install du worktree |
| `<n>-ci.txt` | la sortie de `gh pr checks` |
| `<n>.status` | le verdict machine (`result`, `pr`, `draft`, `attempt`, `session`, `cost`, `model`) |
| `summary.md` | le tableau du run : résultat, PR, essai, modèle, **contexte max**, coût, CI, intégration |

**`.afk/` est écrasé au run suivant.** Ce qui doit survivre vit dans le dépôt d'afk
lui-même — monté dans chacun de tes projets, donc commun à tous :

| Fichier | Contenu | Écrit par |
|---|---|---|
| `RUNS.md` | une ligne par run : date, projet, verts/drafts/rouges/gelés, 1er essai, modèle, coût, durée, intégration | `afk.sh`, à la fin de chaque run |
| `docs/defauts.md` | les défauts **d'afk** constatés en vrai pendant un run, numérotés | `/afk-debrief`, ou à la main |

Le chemin est celui du script (`AFK_HOME`), pas celui du projet : que tu lances `afk.sh`
depuis un devcontainer où il est monté ou depuis l'extérieur, il écrit au même endroit.
Dépôt monté en lecture seule → rien n'est journalisé, et ce n'est pas une erreur de run.

En série, la trace sort aussi à l'écran en direct. En parallèle elle est mise de côté
et déversée d'un bloc quand le ticket finit, sinon les sorties s'entrelacent ; une
ligne `… en cours : #48 (3m12) #50 (1m04)` toutes les deux minutes dit qui travaille.

## Le contexte comme thermomètre du découpage

Une session neuve garantit un départ propre, pas une arrivée propre. Avec une fenêtre
de 1M, rien ne compacte : la session grossit jusqu'à finir le ticket. Mesuré sur
hexa-zero — même run, mêmes règles :

| ticket | tours | contexte max |
|---|---|---|
| #43 | 64 | 140k |
| #49 | 208 | 289k |
| #50 | 214 | 312k |

`summary.md` porte donc une colonne **contexte**, lue dans le transcript de la session.
C'est la même information que « vert au 1er essai », prise en amont : un ticket qui
frôle la fenêtre était trop gros, et ça se voit **avant** que la qualité ne s'en
ressente.

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

Ça fait trois niveaux, du plus général au plus précis — **le plus précis gagne** :

```
défaut du script  →  .afk.env du repo  →  ligne Verify: du ticket
(monorepo pnpm)      (ce projet)           (ce ticket)
```

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

## Modèle et effort par ticket

Même endroit, même parseur, pour la même raison : le réglage global a été choisi pour le
ticket moyen, et une correction de typo n'a pas besoin du modèle d'une refonte.

```
Model: sonnet
Effort: high
```

`Model:` accepte un alias (`opus`, `sonnet`, `haiku`) ou un nom complet ; `Effort:` un des
niveaux de `claude` (`low`, `medium`, `high`, `xhigh`, `max`). Sans ces lignes, `MODEL` et
`EFFORT` s'appliquent ; sans eux, les défauts de `claude`.

Le bilan donne le modèle qui a **réellement** tourné : `FALLBACK_MODEL` bascule sur un
modèle de secours quand le principal est indisponible — sans ça, une nuit entière peut
changer de modèle sans le dire. C'est ce repli qui évite qu'une indisponibilité passagère
brûle les deux essais d'un ticket en quelques secondes et vide la file.

## Reprendre une session ratée

Un ticket rendu à `ready-for-human` garde son worktree **et** sa session. Le bilan donne
la commande pour y rentrer :

```
(cd .afk/wt/48 && claude --resume 42ce8dfe-…)
```

C'est le seul moyen de demander à l'agent pourquoi il a pris ce chemin-là — un log ne le
dira jamais.

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
