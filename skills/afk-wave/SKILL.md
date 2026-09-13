---
name: afk-wave
description: "Ouvre la vague suivante de tickets ready-for-agent à partir de docs/spec.md et de l'état réel du dépôt — choisit les critères non cochés du jalon courant, les découpe en tickets d'une session, les sérialise, et s'arrête quand il n'y a plus rien à ouvrir. Tourne entre deux runs afk, sans personne. Déclencheurs : /afk-wave, « ouvre la vague suivante », « les tickets du jalon courant », « qu'est-ce qu'on construit maintenant ? »."
---

# /afk-wave

Entre deux runs. Il lit ce que le spec demande encore, ce que le dépôt contient
**vraiment**, et ouvre les tickets de la vague suivante.

On ne découpe pas tout d'avance parce qu'on ne peut pas : les tickets d'une vague
dépendent du code que la vague précédente a réellement écrit, pas de celui qu'on
imaginait.

## 0 — La garde, avant tout le reste

```bash
git fetch -q origin && git switch -q dev && git pull -q
diff <(git show afk-spec:docs/spec.md | sed 's/\[x\]/[ ]/g') <(sed 's/\[x\]/[ ]/g' docs/spec.md)
```

Une différence autre que des cases → **arrête-toi et dis-le**. Le spec a dérivé : à
partir de là, plus rien ne juge la boucle, elle se décerne sa propre victoire. C'est un
arrêt, pas un avertissement.

Pas de tag `afk-spec` → le dépôt n'est pas passé par `/afk-spec`. Arrête-toi aussi.

## 1 — Ce qui reste

```bash
grep -n '^- \[ \]' docs/spec.md          # les critères non cochés
grep -n '^## Jalon' docs/spec.md
gh issue list --state open --json number,title,labels,milestone
```

Le **jalon courant** est le premier qui a encore un critère non coché. On ne travaille
que celui-là. Tous cochés dans tous les jalons → **il n'y a rien à ouvrir**, dis-le et
arrête-toi : c'est la fin normale de la boucle.

## 2 — Ce que le dépôt contient vraiment

Le spec dit ce qu'on veut ; il ne dit pas ce qui existe. Avant de découper :

```bash
git log --oneline afk-spec..dev | head -40
git diff --stat afk-spec..dev
```

Un ticket écrit contre un dépôt imaginé part chercher des fichiers qui n'existent pas et
brûle sa session. C'est la différence entre cette vague et la précédente.

## 3 — Les rouges de la vague d'avant

```bash
gh issue list --state open --label ready-for-human --json number,title,comments
```

Un critère non coché dont le ticket est déjà passé une fois : **recoupe-le plus petit**,
ne le rouvre pas tel quel — il échouera pareil.

Deux vagues sans qu'un critère atterrisse → laisse-le en `ready-for-human`, ne le remets
pas dans la vague, et **nomme-le dans ton rapport**. C'est une des trois conditions
d'arrêt de la boucle ; la faire passer en silence coûte toutes les nuits suivantes.

## 4 — Choisir

**3 à 6 critères**, pas plus. Le plan porte sur du code qui n'existe pas encore : au
delà, il est deviné, et la vague suivante le jettera.

Un ticket qui ne livre **aucun critère du spec** ne s'ouvre pas. Pas d'exception — c'est
exactement par là que la boucle part construire ce que personne n'a demandé.

## 5 — Écrire les tickets

Une tranche verticale par ticket — schéma, code, écran, test — sinon la porte ne peut
pas le juger seul.

```bash
gh issue create -t "<titre>" -l ready-for-agent -m "<jalon courant>" -F - <<'EOF'
## What to build

<en une phrase, puis ce qu'il ne faut pas toucher>

## Acceptance criteria

- [ ] **A3** — `POST /tasks` avec un titre renvoie 201 et l'id créé
- [ ] le test vit dans `tests/api/tasks.spec.ts`

## Blocked by

None

Verify: pnpm vitest run tests/api/tasks.spec.ts
EOF
```

Les critères recopiés **mot pour mot** depuis le spec, numéro compris. C'est ce qui
permet à `/afk-merge` de cocher mécaniquement, et à toi de relire sans ouvrir deux
fichiers.

La ligne `Verify:` est la commande du critère. Si le ticket en porte plusieurs, les
commandes enchaînées par `&&`. Éprouve-la avant de l'écrire — sur un fichier de test qui
n'existe pas encore, elle doit échouer proprement, pas rester bloquée :

```bash
timeout 120 bash -c '<la commande>'; echo "rc=$?"
```

`rc=124` = elle ne rend jamais la main (`vitest` sans `run`, `jest --watch`) : le ticket
mourra sur `TIMEOUT` pour une raison qui n'est pas la sienne.

## 6 — Sérialiser ce qui se marche dessus

Deux tickets de la même vague partent chacun d'une base qui ne contient pas l'autre :
les deux sont verts et la casse n'apparaît qu'à l'intégration — ou jamais, quand les
deux créent le **même chemin** avec deux API justes chacune de son côté.

Deux tickets qui annoncent les mêmes fichiers → un `Blocked by` sur celui qui peut
attendre. Pas une fusion : le second part alors de la branche du premier et voit son
travail.

Et les numéros qui se disputent (ADR, migration) se donnent **dans le corps**, avant le
run :

```bash
ls docs/adr | tail -3
```

## 7 — Relire son propre lot

```bash
./afk.sh -n
```

Lis-en : les vagues, les bases, les gels, la porte effective par ticket. Un ticket
**gelé** dans ta propre vague est une erreur de découpe que tu viens de commettre —
corrige le `Blocked by`.

Si une ligne `Verify:` n'apparaît pas dans le `-n` là où le ticket en écrit une, elle a
été refusée par le motif de validation : elle finit par `:`, ou par un backtick.

Le reste des pièges de contenu est dans `/afk-preflight` — **lis-le plutôt que de le
refaire**, c'est le même travail sur des tickets qui viennent d'ailleurs.

## 8 — Rendre

Un tableau : ticket, critères livrés, `Blocked by`, porte. Puis la commande de
lancement, **sans la lancer** :

```bash
nohup ./afk.sh -j 3 &
```

Contrairement à `/afk-preflight`, ce skill **ouvre** les tickets sans attendre
validation : il tourne dans une boucle où personne n'est réveillé. C'est pour ça que ses
interdits sont mécaniques et pas affaire de jugement — voir plus bas.

## Ce que ce skill ne fait pas

- **Il ne touche jamais `docs/spec.md`.** Ni une case, ni un mot. Cocher est le travail
  de `/afk-merge`, après avoir fait tourner la commande du critère.
- **Il n'invente aucun critère.** Un besoin découvert en route qui n'est pas dans le
  spec se dit dans le rapport ; il ne devient pas un ticket.
- Il ne rouvre pas un critère déjà coché.
- Il ne travaille pas deux jalons à la fois.
- Il ne lance pas `afk.sh` : un run dure des heures, ça n'a rien à faire dans une
  session. C'est la boucle au-dessus qui l'appelle.
- Il ne merge rien et ne ferme aucun ticket.
