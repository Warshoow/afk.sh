# Défauts

Ce qui a cassé **dans afk**, en vrai, pendant un run. Un défaut par entrée, numéroté,
daté, avec le projet et le ticket où il est apparu.

Ici et pas ailleurs :

- [CHANGELOG.md](../CHANGELOG.md) dit ce qui a **changé** pour l'utilisateur. Il ne dit
  pas ce que le changement a coûté avant d'être fait.
- [propositions.md](propositions.md) dit ce qu'on a **envisagé** et pourquoi on a
  tranché. Une proposition part d'une idée, un défaut part d'un dégât.
- [RUNS.md](../RUNS.md) donne les **faits** de chaque run, ajoutés par `afk.sh`. Un
  défaut est un jugement porté dessus.

**Ce qui n'a rien à faire ici** : les problèmes du projet travaillé. Un test instable,
une porte mal réglée, un ticket mal découpé se corrigent dans ce projet-là. On ne
consigne ici que ce qui aurait cassé de la même façon sur n'importe quel dépôt.

Écrit par `/afk-debrief` au dépouillement d'un run, ou à la main. Numérotation continue,
verdict dans le titre : **corrigé** ou **ouvert**.

Les défauts 1 à 16 n'ont pas été consignés : ils ont été trouvés et corrigés avant que
ce fichier existe. Leur trace est dans les commentaires de `afk.sh` et dans
`git log`.

---

## 17 — Bases de test partagées entre worktrees — corrigé

*2026-08-31 · hexa-zero*

**Ce qu'on a vu.** En parallèle, des tickets sains sortaient rouges, avec des erreurs de
migration qui ne parlaient pas de leur code. Le même ticket relancé seul passait au vert.

**La cause.** Le nom de la base de test était fixé en dur dans un `.env.test` versionné.
Chaque worktree recopiait donc le même, et le `migrate()` / `rollback()` d'un voisin
vidait la base sous les tests du ticket courant. La porte notait le ticket rouge pour le
travail d'un autre — le pire cas possible, puisque rien dans sa trace ne pointe ailleurs
que vers lui.

**Ce qu'on en a fait.** `afk.sh` exporte `AFK_TICKET` et `AFK_WORKTREE` avant `SETUP_CMD`,
qui tourne déjà sous le verrou `install`. C'est au projet de s'isoler avec — une base par
numéro de ticket, un port, un bucket : lui seul sait de quoi il doit s'isoler. Le README
en donne l'exemple, section « Isoler un worktree de ses voisins ».
