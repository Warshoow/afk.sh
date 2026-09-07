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
verdict dans le titre : **corrigé**, **atténué** (le dégât est réduit, la cause reste)
ou **ouvert**.

**Ce fichier ne garde que les défauts vivants** — ouverts et atténués. Un défaut corrigé
part dans [defauts-corriges.md](defauts-corriges.md) : la numérotation est commune et
continue, `grep -rn 'défaut 17' docs/` les trouve tous les deux. La coupure existe parce
qu'un dépouillement lit ce fichier en entier, et que trente entrées closes coûtaient
autant à lire que les quatre qui demandent encore une décision.

Les défauts 1 à 32 ont été constatés avant que ce fichier existe. Ils sont repris ici
depuis le journal tenu dans le dépôt où ils sont sortis — `docs/agents/afk.md` de
hexa-zero, qui garde le détail long, les mesures et les leçons de découpage. Ici on ne
garde que le défaut. Le **18** manque : c'était un problème de ce dépôt-là (un fichier
généré et gitignoré, donc absent d'un worktree neuf, qui faisait échouer sa porte), il
n'a rien à voir avec afk et il apparaît seulement comme révélateur du défaut 20.

---

## 10 — La porte globale pousse l'agent hors du périmètre de son ticket — atténué

*2026-08-19 · hexa-zero · #44, chiffré sur #64 le 2026-08-21*

**Ce qu'on a vu.** Le prompt exige « aucun fichier hors sujet », la porte exige un
`typecheck` à l'échelle du dépôt entier. Sur #44, étiqueté `[backend]`, retirer un champ d'un
transformer cassait le typecheck du client : l'agent a dû modifier 10 fichiers mobiles pour
obtenir du vert, et il a eu raison. Sur #64, même mécanique en plus gros — 31 fichiers,
+1342/−538, dont 220 insertions côté mobile pour un ticket annoncé « backend + types + docs ».

**La cause.** Les deux contraintes se contredisent dès qu'un ticket touche un contrat typé de
bout en bout. Ce n'est pas un bug du script : c'est l'interaction entre sa porte et le
découpage. **Un découpage par app est incompatible avec une porte à l'échelle du dépôt.**

**Ce qu'on en a fait.** Un ticket peut déclarer `Verify: <cmd>` dans son corps ; le script
l'utilise à sa place. Le prompt reconnaît la tension : si tenir le périmètre rend la porte
inatteignable, faire le minimum hors périmètre **et l'écrire dans une décision**. Le fond
reste un problème de découpage — tranche verticale, pas app — et il appartient à celui qui
écrit les tickets.

## 20 — Une porte verte ne prouve pas qu'elle a tourné — atténué

*2026-08-31 · hexa-zero · lot de 8*

**Ce qu'on a vu.** La porte était **verte sur les 8 tickets** et **rouge à l'intégration**,
sur une erreur qui touchait tous les worktrees neufs de la même façon. Elle affichait
`admin:typecheck $ tsc -b --noEmit` et un `✓` sans avoir compilé une ligne.

**La cause.** Le cache de build calcule sa clé sur les fichiers **suivis par git**. Un
fichier généré et gitignoré n'entre pas dans la clé : un worktree neuf qui ne l'a pas produit
rend **quand même la même empreinte** que le dépôt principal qui l'a → cache hit, logs
rejoués, compilateur jamais lancé. L'intégration, elle, présente une combinaison de contenus
jamais vue → cache miss → exécution réelle → les erreurs sortent. Et le cache est **partagé
entre les worktrees**, ce qui fait voyager un faux vert d'un arbre à l'autre.

**Ce qu'on en a fait.** `INTEGRATION_VERIFY_CMD` sépare la porte de la passe d'intégration de
celle des tickets, et le projet y met la forme non cachée (`--force`). Trop cher à payer sur
chaque ticket, indispensable sur la combinaison : c'est le seul verdict qui compte.

**Ce qui reste.** Rien ne signale qu'une porte de *ticket* n'a pas tourné. `Cached: n cached`
dans la sortie du build est une **information de sécurité**, pas une statistique de
performance : une porte « 7/7 » en plein cache n'a rien vérifié. C'est la ligne à lire avant
de croire un vert.

## 21 — Un `Verify:` réduit ne se réduit plus quand le ticket déborde — atténué

*2026-08-31 · hexa-zero · #113*

**Ce qu'on a vu.** 23 tickets d'interface portaient `Verify:` sans les tests, absents de leur
moitié du dépôt. #113, étiqueté `[mobile]`, a ajouté une **route serveur**, modifié un
controller et **trois** fichiers de tests. Sa porte locale ne pouvait pas les exécuter : elle
avait été taillée sur l'étiquette du ticket. Seule la CI de la PR les a couverts — verte,
donc l'affaire tient, mais la garantie a tenu par la CI, pas par la porte.

**La cause.** Le périmètre déclaré d'un ticket est une **prédiction**. Réduire une porte doit
réduire sa **durée**, jamais sa **couverture** — ou bien il faut assumer que la CI est la
seule porte qui compte et que la porte locale n'est qu'un filtre rapide.

**Ce qu'on en a fait.** C'est la seconde branche qui est assumée, et elle est maintenant
**écrite là où on la lit** : une PR dont la porte locale a été réduite le dit dans son corps,
avec la porte complète du dépôt, pour savoir ce qui n'a été vu que par la CI ; sa ligne du
résumé porte un ⚠.

**Ce qui reste.** Le fond est un problème de découpage, pas d'outil. Le motif qui prédit une
étiquette menteuse, trouvé après trois occurrences et lisible dans les critères sans ouvrir
le code : un ticket d'interface touche le serveur dès qu'il fait **apparaître une donnée
neuve**, qu'il **lit une donnée que le serveur borne encore**, ou que **la route dont il a
besoin n'existe pas** (son prédécesseur n'a livré qu'une partie du CRUD).

## 24 — Le renvoi périmé n'est pas un conflit, personne ne le signale — atténué

*2026-08-31 · hexa-zero · lot de 5*

**Ce qu'on a vu.** Une branche écrit « c'est **#116** qui ouvrira cette liste » ; #116 ouvre
la liste dans le même run ; personne ne réécrit la phrase — ni la branche qui l'a écrite
(elle est finie), ni #116 (elle ne sait pas qu'elle est citée). Les deux côtés sont d'accord
sur ces lignes, git les fusionne en silence, et la doc du dépôt affirme au futur ce qui est
livré depuis dix minutes. **Cinq** renvois de ce type sur un seul lot, dans quatre fichiers,
dont deux qu'aucune revue de PR n'aurait attrapés parce qu'ils ne sont dans le diff d'aucune
branche — un document **hérité tel quel** par une branche empilée.

**La cause.** C'est la moitié cachée de la règle « sur un conflit, ne pas choisir un côté
sans lire les deux » : elle suppose qu'il y a un conflit. La dérive la plus fréquente n'en
produit **aucun**. Ni git ni afk n'ont tort — aucune porte ne voit une phrase devenue fausse.

**Vu sous deux autres espèces depuis.** La **puce en double** : deux tickets documentent le
même module à deux endroits différents du même fichier, git ne voit aucun conflit, et l'arbre
mergé décrit deux fois le même module avec deux API dont une fausse. Et le **renvoi périmé
par l'autre bout** : un ticket supprime un écran et met à jour ses renvois, sauf celui d'un
fichier qu'un ticket voisin venait d'écrire la veille et qu'il n'a pas rouvert.

**La piste.** C'est une étape de revue, et elle est mécanisable — donc afk pourrait la
porter, après les merges :

```bash
# les tickets du lot cités au futur
grep -rnE "#(107|116|88|89|94)[^0-9]" --include=*.md --include=*.ts --include=*.tsx . \
  | grep -v node_modules \
  | grep -iE "ouvrira|arrivera|viendra|sera |pas encore|d'ici là|c'est #[0-9]+ qui|reste "

# un même fichier/module documenté deux fois
grep -rn '^- `' --include=CLAUDE.md --include=CONTEXT.md . | grep -v node_modules \
  | sed -E 's/^([^:]+):[0-9]+:- `([^`]+)`.*/\1 \2/' | sort | uniq -d
```

Un journal de runs doit sortir du premier filtre : ses entrées sont historiques, elles
**doivent** rester au passé de leur date.

**Ce qu'on en a fait (2026-09-04).** La détection seulement, et sur les `.md` seulement :
la passe d'intégration liste les tickets du run cités dans la doc mergée, avec leur
fichier et leur ligne. Elle ne juge pas la phrase — il faudrait une liste de verbes au
futur, qui serait fausse dès qu'on change de langue ou de style. Elle dit où regarder,
ce qui est exactement ce qui manquait : ces renvois ne sont dans le diff d'aucune
branche. La puce en double et le renvoi périmé par l'autre bout restent invisibles.
