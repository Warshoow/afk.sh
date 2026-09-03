# Journal des changements

Une entrée par changement de **comportement observable** — pas une par commit :
`git log` fait déjà ça, et mieux. Pas de version ni de tag : le dépôt n'en a pas,
les dates suffisent. Le raisonnement derrière un changement reste dans les
commentaires de `afk.sh`, à côté du code concerné ; le verdict sur les idées
proposées est dans [docs/propositions.md](docs/propositions.md).

## 2026-09-04 (2)

Deux défauts vus au `-n` d'un lot de quinze tickets, **avant** de lancer : le run n'a pas
eu lieu.

### Corrigé

- Une ligne `Verify:` écrite comme dans un ticket bien rédigé — la commande en `code`,
  puis en français ce qu'elle ne couvre pas — partait **en entier** au `bash -c`, gras
  markdown compris, où le `**` globait sur le cwd. Quinze tickets rouges aux deux essais
  pour une raison qui n'avait rien à voir avec eux, et le `VERIFY_CMD` du `.afk.env`
  jamais joué une fois. `meta_line` mange le gras qui suit le `:` et, quand la valeur
  commence par un span backtick, ne garde que lui. La forme nue du README reste acceptée
  (défaut 33).
- `Verify` reçoit son motif de validation, `RE_VERIFY`, comme `Timeout`, `Model` et
  `Effort` : une valeur qui finit par `:` est une phrase d'introduction, pas une
  commande — elle est ignorée et le ticket retombe sur `VERIFY_CMD` (défaut 33).
- Une porte qui **commence en français** et cite ses commandes au milieu (« à la main,
  `python -m jarvis hub` + `npm run dev` : … ») est refusée elle aussi. Elle ne commence
  pas par un span et ne finit pas par `:` : les deux règles ci-dessus la laissaient
  passer entière, trois tickets sur quinze. Les backticks ne tombent donc plus que si la
  valeur **est** le span, et `RE_VERIFY` refuse celle qui en garde un — après nettoyage,
  un backtick résiduel ne vient plus que d'une prose qui cite des commandes. Une
  commande à substitution `` `cmd` `` à l'ancienne est refusée avec (défaut 33).
- « Aucune CI déclarée » ne vaut plus « CI non concluante ». La première est une
  propriété du dépôt : sur un dépôt sans workflow, elle marquait « vert non prouvé »
  tout ticket portant un `Verify:`. Le bilan le dit maintenant une fois pour le run, en
  nommant les tickets à porte réduite (défaut 34).

## 2026-09-04

Neuf défauts consignés dans [docs/defauts.md](docs/defauts.md) après un usage intensif
sur un dépôt réel. Huit corrigés, un atténué.

### Ajouté

- **`vert non prouvé`** et **`poussée refusée`** au bilan. Un ticket à porte locale
  réduite dont la CI n'a pas conclu n'a été vu par aucune porte complète ; une branche
  que le remote a refusé de recevoir est complète et verte, seulement pas poussée.
  Les deux sortent de la colonne `vert`, et une poussée refusée ne change aucun label
  ni ne relance de session — le second essai échouerait à l'identique (défauts 30, 32).
- La ligne `draft` du bilan dit **laquelle** des trois anomalies l'a mise là : `coupée`,
  `anormale`, `non commité`. Une session coupée au `timeout` peut l'avoir été au milieu
  d'un fichier — ce n'est pas la même relecture qu'une session qui a rendu son tour, et
  le corps de la PR le dit aussi (défaut 31).
- L'intégration signale le **même chemin créé par plusieurs branches** : deux branches
  qui ajoutent le même fichier sont vertes chacune de son côté, et seul le merge le voit
  (défaut 25). Et elle liste les **tickets du run cités dans la doc mergée** : une phrase
  au futur sur ce qui est livré depuis dix minutes ne produit aucun conflit (défaut 24,
  détection seulement).
- Une ligne du prompt : l'agent ne lance pas la porte lui-même. C'est ce qui a mangé le
  tour d'une session, qui s'est terminée sur `Gate still running` sans avoir commité
  (défaut 31).
- `CI_RETRY_WAIT` : `gh pr checks --watch` ne surveille que des checks déjà enregistrés
  et sort immédiatement quand il n'y en a aucun. La dernière PR créée était donc
  structurellement exposée — quatre secondes de retard, classée « aucune CI déclarée ».
  Afk réessaie quatre fois avant de conclure (défaut 29).

### Corrigé

- L'intégration merge dans l'**ordre topologique** : une branche empilée mergée avant sa
  base conflicte par construction, et ça se lisait comme un vrai recouvrement (défaut 27).
- `summary.md` garde les **fichiers en conflit** branche par branche, et les numéros et
  chemins en double. C'était affiché puis jeté : le terminal fermé, il fallait
  reconstruire à coups de `git merge-tree` en devinant l'ordre de merge (défaut 26).
- Les fichiers ajoutés d'une branche sont comptés contre **sa** base et non contre la
  base commune : une branche empilée porte les commits de son bloqueur (défaut 25).
- La première ligne de `<n>.status` ne dit plus `result=ko` sur un ticket vert : la
  valeur prudente du démarrage s'appelle `result_initial` (défaut 28).

## 2026-09-03

### Ajouté

- Le bilan donne, par ticket, le **modèle qui a réellement tourné** et le **coût**
  cumulé sur ses essais. Les sessions tournent avec un modèle de repli
  (`FALLBACK_MODEL=sonnet`) : sans lui, une indisponibilité passagère du modèle brûle
  les deux essais d'un ticket en quelques secondes et vide la file — un run AFK n'a
  personne devant lui pour le voir.
- Un ticket rouge se reprend à la main : le bilan donne son
  `(cd .afk/wt/<n> && claude --resume <id>)`. Son worktree était déjà gardé, sa
  session aussi — il manquait de quoi y rentrer.
- Un ticket peut déclarer son modèle et son niveau de réflexion, comme il déclare
  déjà sa porte et son budget de temps : lignes `Model:` et `Effort:` de son corps
  (`MODEL` / `EFFORT` pour le réglage global).
- `RUNS.md` dans le dépôt d'afk : une ligne par run, ajoutée automatiquement à la fin.
  `.afk/summary.md` étant écrasé au run suivant, aucun historique ne survivait nulle
  part ; celui-ci traverse les runs **et** les projets, le dépôt d'afk étant monté dans
  chacun. `AFK_HOME` dit où il s'écrit.
- `docs/defauts.md` : le registre des défauts d'afk constatés pendant un run, numéroté
  et écrit par `/afk-debrief`. `afk.sh` citait déjà « défaut 17 » sans que ce numéro
  pointe sur quoi que ce soit.
- Deux skills encadrent le run, là où il faut du jugement et où le script n'en a pas :
  `/afk-preflight` relit le lot avant de lancer (ce qui sera gelé, ce qu'aucune porte
  ne peut vérifier, ce qui ne tient pas dans son budget), `/afk-debrief` dépouille le
  run au réveil et classe chaque non-vert par cause.

### Corrigé

- Une session qui s'arrête mal **nomme** sa panne (`error_during_execution`,
  `error_max_turns`, …) au lieu de rendre un code. Les sessions sortent en JSON
  (`--output-format json`), donc `.afk/<n>-<essai>.log` devient `.afk/<n>-<essai>.json`.

## 2026-09-02

### Ajouté

- Un ticket empilé reçoit dans son prompt ce que ses bloqueurs ont déjà livré :
  la liste de leurs ADR / `CONTEXT.md` à lire avant de coder, puis la liste des
  fichiers déjà touchés. Le travail était déjà sur le disque (le worktree part de
  la branche du bloqueur), mais l'agent démarrait en session neuve sans le savoir —
  il refaisait un travail fait, ou renommait un contrat qu'il venait d'hériter.

### Corrigé

- `CLAUDE_CONFIG_DIR` : le défaut cherche le répertoire qui contient réellement le
  plugin mattpocock, au lieu d'un chemin en dur — dans un devcontainer, `$HOME`
  n'est pas là où la config de l'hôte est montée.

## 2026-08-31

### Corrigé

- Le listing des tickets ne se tronque plus à 30 sans le dire (`gh issue list`
  plafonne silencieusement, et rend les plus récents) : les tickets hors tranche
  apparaissaient comme des « bloqueurs ouverts hors run », donc un gel silencieux.
- `SETUP_CMD` reçoit `AFK_TICKET` / `AFK_WORKTREE`, de quoi isoler un worktree de ses
  voisins. Sans ça, plusieurs worktrees partageaient la base de test d'un `.env.test`
  versionné, et la migration d'un voisin notait le ticket courant rouge.
- La passe d'intégration nomme son périmètre : un verdict vert après une branche
  écartée au merge se lisait comme « tout se combine », la question même à laquelle
  elle existe pour répondre. Elle accepte aussi une porte à part
  (`INTEGRATION_VERIFY_CMD`), parce qu'un cache de build qui hache les fichiers suivis
  par git rend un ✓ sans avoir compilé une ligne.
- Un merge refusé (arbre sale, base absente) ne s'écrit plus « CONFLIT » : ce n'est
  pas la même information, et ça envoyait chercher au mauvais endroit.
- Les numéros pris deux fois (ADR, migrations) sont signalés à l'intégration. Chaque
  worktree part de la base sans voir ses voisins, donc chaque agent prend le numéro
  libre qu'il voit et il a raison : les noms diffèrent, git ne voit aucun conflit,
  aucune porte ne peut le dire.
- Un seul verdict « intégration » au bilan : deux lignes du même nom se lisaient
  comme deux verdicts contradictoires.
- L'en-tête du run annonce la porte d'intégration quand elle diffère de la porte
  des tickets.

## 2026-08-22

### Ajouté

- `afk.sh` : enchaîne `/implement` sur les tickets `ready-for-agent`, un worktree et
  une session neuve par ticket, PR empilées selon le DAG des bloqueurs.
- `check.sh` (parseurs purs) et `harness.sh` (la boucle entière, `claude` et `gh`
  bouchonnés).
- `.afk.env` : le projet déclare lui-même sa porte de vérification et l'installation
  de ses dépendances, là où vit la vraie définition de « fini ».
- `/afk-setup` pour écrire ce `.afk.env`.
- Le pic de contexte de chaque session dans `.afk/summary.md` : le thermomètre du
  découpage. Il mesure la taille du travail, pas sa qualité.
