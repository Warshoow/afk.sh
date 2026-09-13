---
name: afk-spec
description: "Transforme une idée d'app en un dépôt qu'afk peut travailler tout seul — choisit la stack, écrit docs/spec.md dont chaque critère porte la commande qui le prouve, monte le squelette qui démarre, la CI, le .afk.env, et pose le jalonnage. À lancer une fois, au tout début, avant la première vague. Déclencheurs : /afk-spec, « je veux construire <idée> », « monte le dépôt pour cette idée », « écris le spec », « vague 0 »."
---

# /afk-spec

Une idée n'est pas exécutable. Ce skill la rend exécutable : un dépôt qui démarre, une
porte qui passe, et une liste de critères dont **chacun nomme la commande qui le
prouve**. Après ça, `/afk-wave` et `/afk-merge` tournent en boucle sans personne.

C'est la seule étape de la boucle qui mérite d'être relue réveillé : elle choisit la
stack pour tout le reste, et elle écrit le seul juge que la boucle aura.

## La règle qui tient tout le reste

**`docs/spec.md` s'écrit ici et ne change plus jamais.** Les vagues suivantes n'ont le
droit que de cocher des cases — pas d'ajouter, pas de reformuler, pas de retirer un
critère.

Sinon la boucle se déclare gagnante toute seule : celui qui écrit les critères et celui
qui les remplit sont le même modèle. C'est le seul mode d'échec qui ne se voit nulle
part dans le bilan.

## 1 — L'idée, et ce qu'elle exclut

Une phrase pour ce que l'app fait. Puis, explicitement, **ce qu'elle ne fera pas** :
tout ce qui n'est pas dans le spec ne sera jamais construit, et c'est voulu — l'agent ne
rattrapera pas un oubli, il inventera.

Trop gros pour un spec (« un Notion », « un CRM ») → dis-le et propose la première
tranche qui se tient debout seule. Une boucle sur cinquante critères passe ses nuits à
empiler du code que rien ne relit.

## 2 — La stack

La plus ennuyeuse qui tienne. Deux contraintes, dans cet ordre :

- **la porte tourne sans service externe.** Chaque ticket tourne dans un worktree
  jetable : un Postgres vivant, un Redis, un `docker compose` et tous les tickets
  meurent rouges pour une raison qui n'est pas la leur. SQLite sur fichier, serveur en
  mémoire, faux client — c'est une décision de vague 0, pas un détail.
- **le modèle la connaît sans chercher.** Une stack pointue coûte une session de
  documentation par ticket, toutes les nuits.

Une ligne de justification par choix, dans le `README.md`. Personne ne la relira avant
six mois.

## 3 — Les critères

Le cœur du skill. Un critère s'écrit comme ceci :

```markdown
- [ ] **A3** — `POST /tasks` avec un titre renvoie 201 et l'id créé.
      `pnpm vitest run tests/api/tasks.spec.ts -t "création"`
```

Trois parties : un numéro stable, la phrase, **et la commande qui rend 0 quand c'est
vrai**. Le fichier de test n'existe pas encore : le chemin est une consigne pour le
ticket qui prendra ce critère.

**Le test, avant d'écrire quoi que ce soit : quelle commande rend 0 si c'est vrai, et
non-0 sinon ?** Pas de réponse → ce n'est pas un critère, c'est un souhait. Réécris-le
ou jette-le.

| Souhait | Critère |
|---|---|
| « l'utilisateur peut créer une tâche » | `POST /tasks` renvoie 201, et la tâche apparaît dans `GET /tasks` |
| « l'interface est agréable » | (pas un critère — voir plus bas) |
| « c'est rapide » | `GET /tasks` sur 1000 lignes répond en moins de 200 ms |
| « les erreurs sont gérées » | `POST /tasks` sans titre renvoie 400 et un corps `{error}` |

Ce qu'aucune commande ne juge — une mise en page, une animation, un ton — **ne va pas
dans le spec**. Ça se traite plus tard, ticket par ticket, par une ligne
`Gauntlet: <référence>` quand tu auras une référence à viser. Un critère de goût dans le
spec bloque la boucle pour toujours ou se coche à l'aveugle.

Le premier critère est toujours le même : **A0 — l'app démarre**, avec la commande qui
le prouve. C'est lui qui attrape « tous les tickets sont verts et rien ne tourne ».

Vise 10 à 30 critères. En dessous, le spec ne décrit pas une app ; au-dessus, découpe
l'idée.

## 4 — Les jalons

Groupe les critères en jalons ordonnés, chacun une chose qui se tient debout seule
(« l'API répond », « on peut se connecter », « l'écran de liste »). Un jalon est fini
quand tous ses critères sont cochés. `/afk-wave` ne travaille jamais deux jalons à la
fois.

Un jalon ne dépend que des précédents. Si deux jalons se réclament l'un l'autre, c'est
un seul jalon.

```markdown
## Jalon 1 — L'API répond
- [ ] **A0** — …
- [ ] **A1** — …

## Jalon 2 — Persistance
- [ ] **A4** — …
```

## 5 — Le squelette

Le minimum pour que **A0 passe et rien d'autre**. Pas d'écran vide « pour plus tard »,
pas de dossier `utils/` sans contenu : chaque fichier qui existe ici est un fichier
qu'un agent croira devoir respecter.

```bash
<la commande de A0>; echo "rc=$?"
```

`rc=0` ou le squelette n'est pas fini.

## 6 — Le reste de l'appareillage

Dans cet ordre, chacun est un prérequis du suivant :

```bash
/mattpocock-skills:setup-matt-pocock-skills   # docs/agents/issue-tracker.md, les labels
/afk-setup                                     # .afk.env, la porte éprouvée
```

Sans le premier, `afk.sh` refuse de démarrer. Sans le second, la porte sera celle d'un
monorepo pnpm.

Puis une CI qui joue la même porte que `VERIFY_CMD` — c'est elle qui vérifiera les PR,
et `/afk-merge` ne merge rien sans elle.

## 7 — Poser les repères

```bash
git commit -am "chore: spec, squelette et porte"
git tag afk-spec                     # la version de référence du spec
git branch dev && git push -u origin dev
echo 'BASE_BRANCH="${BASE_BRANCH:-dev}"   # la boucle atterrit sur dev, jamais sur master' >> .afk.env
```

`BASE_BRANCH=dev` n'est pas optionnel : sans lui, les worktrees partent de `master` et
les PR la visent — chaque ticket ignorerait alors tout ce que les vagues précédentes ont
livré.

Le tag est la garde : `/afk-wave` et `/afk-merge` comparent `docs/spec.md` à
`git show afk-spec:docs/spec.md` et refusent de tourner si autre chose que des cases a
bougé.

`dev` est la branche d'atterrissage. **`master` n'est jamais touchée par la boucle** —
c'est toi qui merges `dev`, réveillé.

Enfin, une milestone GitHub par jalon, dans l'ordre :

```bash
gh api repos/{owner}/{repo}/milestones -f title="Jalon 1 — L'API répond"
```

C'est là que `/afk-wave` accrochera ses tickets. Pas de fichier d'état en plus : le spec
porte les critères, GitHub porte les tickets et les jalons, git porte le reste.

## 8 — Montrer, puis attendre

Montre le spec et la stack, **attends validation**. C'est le seul point d'arrêt de toute
la boucle — après, plus personne ne relit avant le réveil.

Ce qui compte dans cette relecture : est-ce que la liste des critères, une fois tous
cochés, décrit l'app que tu voulais ? Si non, c'est maintenant, pas dans trois vagues.

## Ce que ce skill ne fait pas

- Il ne lance pas `afk.sh` et n'ouvre aucun ticket : c'est `/afk-wave`, une fois le spec
  validé.
- Il n'écrit aucun code applicatif — seulement le squelette qui fait passer A0.
- Il ne met pas dans le spec ce qu'aucune commande ne juge.
- Il ne revient jamais sur `docs/spec.md` après le tag. Si le spec est faux, c'est une
  décision humaine : corriger, retaguer, et le dire.
