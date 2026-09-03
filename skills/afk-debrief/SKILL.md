---
name: afk-debrief
description: "Dépouille un run afk terminé — lit .afk/summary.md et les traces, classe chaque non-vert par cause (porte fausse, ticket trop gros, vrai échec), propose quoi corriger et quoi relancer. À lancer au réveil, avant de merger. Déclencheurs : /afk-debrief, « dépouille le run », « qu'est-ce qui a raté cette nuit ? », « pourquoi #48 est rouge ? »."
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
| **« numéros en double »** | deux branches ont pris le même numéro d'ADR ou de migration. Aucune porte ne peut le voir, git non plus : renuméroter avant de merger |
| **colonne « Modèle » ≠ le modèle demandé** | `FALLBACK_MODEL` a joué : le principal était indisponible. Les verts de cette nuit ont tourné sur le modèle de secours, relis-les de plus près |
| **colonne « Contexte » proche de la fenêtre** | ticket trop gros, même vert. C'est le thermomètre du découpage, pas une note de qualité |

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
| `ko` / `push` | `<n>-push.txt` | la branche `feat/<n>` existe déjà sur le remote, ou le token n'a pas les droits | supprimer la branche distante ou la reprendre à la main |
| `ko` / `pr` | `<n>.out` | une PR est déjà ouverte sur cette branche | fermer la PR, ou fermer le ticket |
| `ko`, aucun commit | `<n>-verify.txt` | l'agent n'a rien produit **et** la base était rouge : le repo était déjà cassé avant lui | réparer la base d'abord, tout le lot en dépend |
| `draft` | la PR elle-même | vert, mais suspect — la note `⚠` de la PR dit pourquoi : session terminée anormalement, ou orchestrateur qui a rattrapé un arbre non commité | relire avant de sortir du draft ; le travail est là, sa complétude n'est pas garantie |
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

## 7 — Nettoyage

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
