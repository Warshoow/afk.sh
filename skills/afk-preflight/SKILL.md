---
name: afk-preflight
description: "Relit le lot de tickets ready-for-agent juste avant un run afk, et corrige ce qui ferait perdre la nuit — gel par un bloqueur hors run, critères qu'aucune porte ne peut vérifier, ticket trop gros pour son budget de temps. À lancer entre /triage et ./afk.sh. Déclencheurs : /afk-preflight, « est-ce que mes tickets sont prêts pour afk ? », « relis le lot avant de lancer », « pourquoi ce ticket serait gelé ? »."
---

# /afk-preflight

Un ticket mal rédigé ne coûte pas cinq minutes, il coûte `MAX_ATTEMPTS × TIMEOUT` de
nuit — et s'il bloque les autres, il coûte leur nuit aussi. Ce skill relit le lot avant
le run et rend une liste de corrections.

`./afk.sh -n` donne déjà toute la mécanique : vagues, bases, piles, gelés, porte
effective par ticket. **Ne la refais pas.** Ce skill juge le *contenu* des tickets,
ce que le script ne peut pas faire.

## 1 — Prérequis

```bash
test -f .afk.env || echo "pas de .afk.env — lance /afk-setup d'abord"
```

Pas de `.afk.env` → la porte sera celle d'un monorepo pnpm, fausse partout ailleurs.
Arrête-toi là.

## 2 — Le plan

```bash
./afk.sh -n            # tout le lot ready-for-agent
./afk.sh -n 43 48 49   # ou un lot explicite
```

Lis-en, sans les recalculer : les tickets **gelés**, les **vagues** (qui tourne en même
temps que qui), les **bases** (qui s'empile sur qui), et les lignes `Verify:` /
`Timeout:` / `Model:` / `Effort:` que les tickets se sont données.

## 3 — Les corps

```bash
gh issue view <n> --json title,body,labels -q '.title, .body'
```

Un ticket par appel, pour tout le lot. C'est la matière du reste.

## 4 — Ce qu'on cherche

| Ce que tu vois | Ce qui va se passer | Correction |
|---|---|---|
| **Gelé — bloqueur ouvert hors run** | le ticket ne démarre pas, et ses dépendants non plus | trois cas : (a) le bloqueur est fini mais son ticket n'a pas été fermé → le fermer ; (b) il a une PR ouverte → `STACK_ON_OPEN_PR=1` suffit, rien à faire ; (c) il est vraiment à faire → l'ajouter au lot, ou sortir le dépendant |
| **`Blocked by` périmé** (bloqueur déjà mergé) | gel pour rien | fermer le bloqueur, ou retirer la ligne du corps |
| **Critère d'acceptation qu'aucune porte ne peut voir** (« l'utilisateur voit un toast ») | « vert » voudra dire « ça compile » | soit un test qui le prouve et une ligne `Verify:` qui le lance, soit l'assumer — mais alors le dire, pas le découvrir au bilan |
| **Ticket qui traverse plusieurs apps avec un `Verify:` rétréci à une seule** | la porte locale ne voit pas la casse, seule la CI la verra — après la PR | élargir le `Verify:`, ou le retirer pour retomber sur la porte complète |
| **Refonte sans `Timeout:`** (migration + code + tests + docs, ou plus de ~6 critères) | coupé au milieu à `TIMEOUT`, deux fois | proposer `Timeout: 90m` (le format de `timeout(1)`) |
| **Périmètre flou** (« améliorer X », « nettoyer Y ») | l'agent part où il veut, la revue n'a rien à comparer | réécrire les critères d'acceptation en choses vérifiables, ou sortir le ticket du lot |
| **Deux tickets de la même vague sur les mêmes fichiers** | chaque worktree part de la base sans voir l'autre : ça compile des deux côtés et casse à l'intégration | sérialiser par un `Blocked by` entre les deux |
| **Ticket déjà couvert par une PR ouverte** | il sortira `absorbé`, au mieux | le fermer, ou le laisser : `absorbé` est un résultat propre, pas un échec |
| **Ticket mécanique** (renommage, config, doc, montée de version) | il tournera sur le modèle des refontes | `Model: sonnet` dans le corps |
| **Ticket dont un run précédent a fini près de la fenêtre de contexte** (colonne « Contexte » de `.afk/summary.md`) | trop gros : la qualité se dégrade avant l'échec | redécouper avec `/to-tickets` |

## 5 — Éprouver toute ligne `Verify:` avant de la proposer

Non négociable, même règle que `/afk-setup` : une porte non testée est une porte
inventée.

```bash
timeout 180 bash -c '<la commande de la ligne Verify:>'; echo "rc=$?"
```

`rc=124` = elle ne rend jamais la main (`vitest` sans `--run`, `jest --watch`) : le
ticket mourra sur `TIMEOUT` pour une raison qui n'a rien à voir avec lui.

## 6 — Rendre le verdict

Un tableau, un ticket par ligne : **part tel quel** / **à corriger** / **à sortir du
lot**, avec la raison en une ligne. Puis les corrections concrètes, prêtes à coller :

```bash
gh issue edit <n> --body-file -    # corps corrigé
gh issue edit <n> --remove-label <ready-for-agent>   # sortir du lot
```

**Propose, attends validation, n'édite rien d'office.** Un corps de ticket est de la
surface de confiance : ses lignes `Verify:` et `Timeout:` sont exécutées telles quelles
par le run.

Termine par la commande de lancement adaptée au lot, sans la lancer :

```bash
nohup ./afk.sh -j 3 43 48 49 &
```

## Ce que ce skill ne fait pas

- Il ne lance pas `afk.sh`. Un run dure des heures en détaché, ça n'a rien à faire dans
  une session.
- Il ne réécrit pas les critères d'acceptation à ta place : il dit lesquels ne sont pas
  vérifiables et propose une formulation, tu tranches.
- Il ne rejoue pas le calcul de `./afk.sh -n`. Si les deux se contredisent, c'est le
  script qui a raison.
