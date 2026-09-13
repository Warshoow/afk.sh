---
name: afk-merge
description: "Fait atterrir une vague afk sur dev — merge les PR vertes dans l'ordre des bases, coche dans docs/spec.md les critères dont la commande passe vraiment, sort les rouges, et dit si la boucle continue ou s'arrête. Tourne après chaque run, sans personne. Déclencheurs : /afk-merge, « fais atterrir la vague », « merge ce qui est vert », « est-ce qu'on continue ? »."
---

# /afk-merge

Le run est fini. Ce skill fait atterrir ce qui tient, laisse le reste dehors, et tranche
la seule question de la boucle : **est-ce qu'on lance une vague de plus ?**

Il ne diagnostique pas les rouges — `/afk-debrief` le fait, mieux, et sans le refaire
ici. Ce skill décide ; l'autre explique.

## La règle

**Un critère ne se coche qu'après que sa commande soit passée sur `dev`.** Pas parce que
le ticket est vert, pas parce que la PR est mergée, pas parce que le travail a l'air
fait. On lance la commande, on lit le code de retour.

C'est ce qui rend le compteur mécanique. Un modèle qui coche à la lecture finit par tout
cocher.

## 1 — L'état

```bash
cat .afk/summary.md
git fetch -q origin && git switch -q dev && git pull -q
diff <(git show afk-spec:docs/spec.md | sed 's/\[x\]/[ ]/g') <(sed 's/\[x\]/[ ]/g' docs/spec.md)
```

Le `diff` ne rend rien d'autre que des cases, sinon **arrêt de la boucle** : le spec a
dérivé, plus rien ne la juge.

Pas de `.afk/summary.md` → aucun run n'est allé au bout. Ne merge rien, dis-le.

## 2 — Ce qui a le droit d'atterrir

Un ticket atterrit si les **trois** sont vrais :

| | où c'est écrit |
|---|---|
| `GREEN` au bilan (pas `OK` — `OK` contient les verts non prouvés) | `.afk/summary.md` |
| la PR n'est pas en draft | `sget <n> draft` |
| la CI de la PR est verte | `gh pr checks <n>` |

Un `vert non prouvé` (porte locale rétrécie **et** CI non concluante) n'atterrit pas :
personne n'a joué la porte complète. Il sort en `ready-for-human`.

## 3 — Merger, dans l'ordre des bases

afk empile : la branche d'un ticket bloqué part de celle de son bloqueur. La merger
avant son bloqueur ramène le travail de l'autre dans un merge qui ne le dit pas.

```bash
grep -h '^base_ref=' .afk/*.status        # la chaîne, ticket par ticket
gh pr merge <n> --merge --delete-branch   # dans l'ordre : bloqueur d'abord
```

`--merge`, pas `--squash` : un squash récrit les commits du bloqueur, et le dépendant
les rapporte une deuxième fois.

**Après chaque merge**, la porte sur `dev` :

```bash
<VERIFY_CMD>; echo "rc=$?"
```

Rouge → le merge qui vient d'arriver casse ce qui marchait. Annule-le
(`git revert -m 1 HEAD`), sors le ticket en `ready-for-human` avec la sortie de la porte
en commentaire, et continue avec les suivants. Un seul mauvais ticket ne coûte pas la
vague.

## 4 — Cocher

Pour chaque critère non coché du jalon courant, sa commande, sur `dev`, telle qu'elle est
écrite dans le spec :

```bash
timeout 300 bash -c '<la commande du critère>'; echo "rc=$?"
```

`rc=0` → `- [ ]` devient `- [x]`. Tout le reste → la case ne bouge pas, quoi que dise
le ticket.

Un critère qui passe alors que son ticket est rouge se coche quand même : c'est la
commande qui juge, pas le run.

Puis, et **seulement** ça :

```bash
git commit -am "chore(spec): vague <n> — A3 A4 cochés"
git push
diff <(git show afk-spec:docs/spec.md | sed 's/\[x\]/[ ]/g') <(sed 's/\[x\]/[ ]/g' docs/spec.md)   # doit être vide
```

Le `diff` après le commit n'est pas une politesse : c'est ce qui attrape la main qui a
glissé sur une phrase du spec.

## 5 — Les rouges

```bash
/afk-debrief
```

Ne refais pas son travail. Ce qu'il te faut de lui, c'est une chose par rouge : **ticket
ou environnement**.

- environnement (porte fausse, base rouge, `setup`, poussée refusée) → le ticket
  repart tel quel à la vague suivante, après la correction qu'il indique
- ticket → `ready-for-human`, et `/afk-wave` le recoupera plus petit

```bash
gh issue edit <n> --add-label ready-for-human --remove-label ready-for-agent
```

Et consigne dans `docs/defauts.md` d'afk ce qui aurait cassé pareil sur n'importe quel
dépôt — `/afk-debrief` dit lesquels. Rien à consigner est le cas normal.

## 6 — Le jalon

Tous les critères d'un jalon cochés → ferme sa milestone et dis quel jalon commence :

```bash
gh api -X PATCH repos/{owner}/{repo}/milestones/<id> -f state=closed
```

## 7 — Trancher

Trois arrêts. **Il en faut trois, sinon la boucle tourne pour rien :**

| | ce que tu dis |
|---|---|
| tous les critères cochés | fini — `dev` est prêt à être mergé dans `master`, par un humain |
| budget épuisé (le plafond donné au lancement) | ce que la dépense a acheté : critères cochés / total, et le jalon en cours |
| **deux vagues d'affilée sans qu'un seul critère se coche** | la boucle n'avance plus. Nomme le critère qui bloque et ce que `/afk-debrief` en dit |

Ces trois-là seulement. « La vague a mal tourné » n'est pas un arrêt : une vague rouge
sur trois est le régime normal, et la suivante recoupe plus petit.

Dans tous les autres cas : `/afk-wave`, puis un run de plus.

## 8 — Rendre

Court, c'est lu au réveil, en série avec les autres vagues :

```
Vague 4 — 3 tickets, 2 mergés, 1 sorti
Cochés : A7 A8   (14/26)
Sorti  : #61 — la porte de dev casse après merge, revert fait
Suite  : /afk-wave (jalon 2)
```

## Ce que ce skill ne fait pas

- **Il ne merge jamais dans `master`.** `dev` seulement. Le dernier merge est une
  décision humaine, et c'est la seule chose qui reste à l'être.
- **Il ne coche aucun critère dont il n'a pas lancé la commande lui-même.**
- **Il ne modifie pas le texte de `docs/spec.md`** — seulement des `[ ]` en `[x]`. Un
  critère qui s'avère impossible se signale dans le rapport et arrête la boucle ; il ne
  se réécrit pas.
- Il n'ouvre aucun ticket : c'est `/afk-wave`.
- Il ne relit pas le code des verts. La porte et la CI sont ce qu'on a ; les élargir est
  un changement de `.afk.env`, pas un jugement de fin de vague.
- Il ne relance pas `afk.sh`.
