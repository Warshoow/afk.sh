# Journal des changements

Une entrée par changement de **comportement observable** — pas une par commit :
`git log` fait déjà ça, et mieux. Pas de version ni de tag : le dépôt n'en a pas,
les dates suffisent. Le raisonnement derrière un changement reste dans les
commentaires de `afk.sh`, à côté du code concerné ; le verdict sur les idées
proposées est dans [docs/propositions.md](docs/propositions.md).

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
