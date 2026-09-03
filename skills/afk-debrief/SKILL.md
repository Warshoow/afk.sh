---
name: afk-debrief
description: "Dépouille un run afk terminé — lit .afk/summary.md et les traces, classe chaque non-vert par cause (porte fausse, ticket trop gros, vrai échec), propose quoi corriger et quoi relancer, et consigne les défauts d'afk lui-même dans son docs/defauts.md. À lancer au réveil, avant de merger. Déclencheurs : /afk-debrief, « dépouille le run », « qu'est-ce qui a raté cette nuit ? », « pourquoi #48 est rouge ? »."
---

# /afk-debrief

Le run est fini. Ce skill lit ce qu'il a laissé, dit **pourquoi** chaque ticket n'est
pas vert, et propose quoi corriger avant de relancer.

Un rouge n'est pas un verdict sur le ticket : la porte peut avoir été fausse, le
worktree mal amorcé, le modèle indisponible. Trier ça est tout le travail.

## 1 — Le bilan

```bash
cat .afk/summary.md
```

Pas de fichier → aucun run n'est allé jusqu'au bout ; passe à `.afk/<n>.out`.

Colonnes : résultat, PR, essai, modèle, contexte, coût, durée. Sous le tableau :
verdict d'intégration, portes employées, taux de vert au 1er essai, et les commandes
de reprise des rouges.

## 2 — Lire le run avant les tickets

Quatre choses se lisent sur l'ensemble, et une seule d'entre elles peut expliquer
tous les rouges à la fois :

| Ce que tu vois au bilan | Ce que ça dit |
|---|---|
| **intégration rouge alors que les tickets sont verts** | ce n'est pas N problèmes, c'en est un : la combinaison. `.afk/integration-verify.txt`, worktree gardé dans `.afk/wt/_integration` |
| **« numéros en double »** | deux branches ont pris le même numéro d'ADR ou de migration. Aucune porte ne peut le voir, git non plus : renuméroter avant de merger. Le numéro reste à qui le cite le plus (`git grep -c` tranche) |
| **« même chemin créé par plusieurs branches »** | deux branches ont créé le même fichier, avec deux API toutes deux justes. Chacune compile sans l'autre : seule la combinaison le dit |
| **« tickets du run cités dans la doc mergée »** | une phrase peut être au futur sur ce qui est livré depuis dix minutes. Aucun conflit git, aucune porte : relire les lignes citées |
| **colonne « Modèle » ≠ le modèle demandé** | `FALLBACK_MODEL` a joué : le principal était indisponible. Les verts de cette nuit ont tourné sur le modèle de secours, relis-les de plus près |
| **colonne « Contexte » proche de la fenêtre** | ticket trop gros, même vert. C'est le thermomètre du découpage, pas une note de qualité |
| **« aucune CI sur ce dépôt »** | la porte locale est la seule qui ait joué du run entier. Si elle était réduite sur certains tickets, ceux-là n'ont eu aucune porte complète — la ligne les nomme |

Et une mise en garde : **un taux de vert de 100 % ne veut rien dire si la porte ne
vérifie rien.** Les tickets marqués `⚠` ont eu une porte locale rétrécie par leur ligne
`Verify:` — seule leur CI a joué la porte complète.

## 3 — Classer chaque non-vert

Pour chaque ticket qui n'est pas vert, `sget` a laissé la cause dans `.afk/<n>.status`
(`reason=`), et le détail est dans un fichier précis :

```bash
cat .afk/<n>.status          # result, reason, session, model, cost
cat .afk/<n>.out             # la trace de l'orchestrateur pour ce ticket
```

| Résultat / `reason` | Où c'est écrit | Cause probable | Quoi faire |
|---|---|---|---|
| `ko` / `setup` | `<n>-setup.log` | l'installation a échoué **dans le worktree** : lockfile absent à la racine, fichier gitignoré indispensable non semé | corriger `SETUP_CMD` ou `SEED_GLOBS` dans `.afk.env`, puis relancer le ticket |
| `ko` / `verify` | `<n>-fail.txt` (dernier échec conservé) | à trancher : porte fausse ou vrai échec — voir l'étape 4 | selon le verdict |
| `ko` / `pr` | `<n>.out` | une PR est déjà ouverte sur cette branche | fermer la PR, ou fermer le ticket |
| `ko`, aucun commit | `<n>-verify.txt` | l'agent n'a rien produit **et** la base était rouge : le repo était déjà cassé avant lui | réparer la base d'abord, tout le lot en dépend |
| `draft` / `coupée` | la PR elle-même | le `timeout` a tiré : la session a pu être coupée **au milieu d'un fichier** | relire en entier avant de sortir du draft, et regarder si le ticket mérite une ligne `Timeout:` |
| `draft` / `anormale` | la PR + `<n>-<essai>.json` | la session s'est arrêtée entre deux actions, `subtype` dit laquelle | relire ; le travail présent compile, sa complétude n'est pas garantie |
| `draft` / `non commité` | la PR elle-même | l'orchestrateur a rattrapé un arbre de travail que l'agent n'avait pas commité | le travail est là ; vérifier le message de commit, il porte le titre du ticket et pas le format du dépôt |
| `vert non prouvé` | le bilan | porte locale réduite (`Verify:`) **et** CI non concluante : rien n'a joué la porte complète | relancer la CI, ou passer la porte complète à la main sur la branche |
| `poussée refusée` | `<n>-push.txt` | le remote a refusé la branche (jeton sans la portée `workflow`, branche déjà présente). Le travail est complet et vert en local | pousser à la main depuis le worktree gardé ; **ne pas** relancer le ticket, la session referait le même travail |
| `gelé` | `<n>.out` | son bloqueur n'a pas été livré | rien à faire sur lui : corriger le bloqueur, il repartira |
| `absorbé` | le commentaire posé sur l'issue | rien à faire, la base était déjà verte : un prédécesseur avait livré son contenu | vérifier puis fermer le ticket |
| `/ CI rouge` | `<n>-ci.txt` | la porte locale était verte, la CI du dépôt non : la porte locale est plus étroite que la CI | élargir `VERIFY_CMD`, ou la ligne `Verify:` du ticket |

## 4 — Porte fausse ou vrai échec

Un `ko / verify` ne dit pas encore de qui c'est la faute. Le worktree du rouge est
**gardé**, dépendances installées :

```bash
cd .afk/wt/<n>
git log --oneline origin/<base>..HEAD      # ce que l'agent a produit
<la porte du ticket>                        # la relancer à la main
git stash list; git status                  # ce qu'il a laissé en plan
```

Puis compare ce que la porte reproche à ce que l'agent a touché :

```bash
git -C .afk/wt/<n> diff --name-only origin/<base>..HEAD
```

La porte se plaint de fichiers **absents de cette liste** → c'est l'environnement ou la
porte, pas le ticket : le worktree n'a pas ce qu'il faut, ou la porte est plus large que
le périmètre. Elle se plaint de fichiers **de la liste** → vrai échec, et `<n>-fail.txt`
dit lequel.

Ne remets pas le worktree sur la base pour trancher : ça détruit l'état de l'échec, qui
est justement ce qu'on est venu lire.

## 5 — Demander à la session

Le bilan donne, pour chaque rouge, de quoi rentrer dans la session qui l'a produit :

```bash
(cd .afk/wt/<n> && claude --resume <id>)
```

C'est le seul moyen d'obtenir ce qu'aucune trace ne contient : **pourquoi** l'agent a
pris ce chemin-là. Utile quand l'échec est un choix de conception, inutile quand
l'environnement était cassé — dans ce cas, la réponse est dans `.afk.env`.

## 6 — Décider, puis proposer

Un tableau, un ticket par ligne : **à relancer tel quel** / **corriger la porte puis
relancer** / **redécouper** / **à prendre à la main**, chacun avec la raison en une
ligne.

Puis les actions, prêtes à coller — le nom exact des labels est dans
`docs/agents/triage-labels.md` :

```bash
gh issue edit <n> --add-label <ready-for-agent> --remove-label <ready-for-human>
```

Et, quand un ticket doit être redécoupé, dis-le explicitement : c'est `/to-tickets`
qui le fait, pas ce skill.

**Propose, attends validation, ne réétiquette rien d'office.** Un ticket remis en
`ready-for-agent` repart la nuit suivante : c'est une décision de run.

## 7 — Consigner ce qui est un défaut d'afk

Le dépôt d'afk est monté dans chaque projet : c'est le seul endroit qui traverse les
runs **et** les projets. `RUNS.md` y reçoit déjà les faits de chaque run, ajoutés par
`afk.sh`. Ce qui demande un jugement va dans `docs/defauts.md`, et c'est toi qui l'y
mets.

Le chemin est celui du script, pas celui du projet :

```bash
d=$(dirname "$(readlink -f "$(command -v afk.sh || echo ./afk.sh)")")
tail -40 "$d/docs/defauts.md"      # le format, et le dernier numéro pris
```

**Le tri est tout le travail.** N'y écris que ce qui aurait cassé **de la même façon sur
n'importe quel dépôt** : l'orchestrateur, les worktrees, la porte, le prompt, le
protocole parent/enfant. Un test instable, un `.afk.env` mal réglé, un ticket mal
découpé sont des problèmes **du projet** — ils se corrigent là-bas et n'ont rien à faire
dans ce registre.

Un défaut d'afk se reconnaît à une chose : la trace accuse le mauvais coupable. Un
ticket sain noté rouge, un gel sans bloqueur réel, un vert qui n'a rien compilé, un
ticket qui brûle ses essais pour une raison qui n'est pas la sienne.

Numéro suivant, verdict dans le titre (**corrigé** si tu as déjà la correction,
**ouvert** sinon), et trois paragraphes : ce qu'on a vu, la cause, ce qu'on en a fait.
Puis **montre l'entrée écrite**. Contrairement aux tickets et aux PR, tu n'attends pas
validation pour celle-ci : un défaut qu'on ne consigne pas se retrouve, et se
rediagnostique en entier.

Rien à consigner est le cas normal. Ne remplis pas le registre pour le remplir.

## 8 — Nettoyage

Les worktrees rouges sont gardés exprès. Une fois le ticket compris :

```bash
git worktree remove --force .afk/wt/<n>
```

Ne les supprime pas avant d'avoir conclu — ils contiennent l'état exact de l'échec,
`node_modules` compris.

## Ce que ce skill ne fait pas

- Il ne merge aucune PR et ne relit pas le code des verts : ça, c'est la revue.
- Il ne relance pas `afk.sh`.
- Il ne réétiquette ni ne ferme aucun ticket sans validation.
- Il ne conclut pas d'un rouge que le ticket était mauvais : la moitié des rouges sont
  des portes, pas des tickets.
- Il n'écrit pas dans `docs/defauts.md` les problèmes du projet travaillé : ce registre
  ne concerne qu'afk, il est lu depuis tous les projets.
