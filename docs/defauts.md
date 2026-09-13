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

---

## 40 — « absorbé » ne distingue pas « déjà livré » de « bloqué, l'agent a refusé » — atténué

*2026-09-09 · jarvis-project · #114*

**Ce qu'on a vu.** #114 supprimait `agent.py` et `jarvis/llm/`. La session est sortie en
7m20 sans un commit, avec un verdict explicite : *« #114 ne peut pas être fait maintenant
— bloqué par #107/#108/#109, pas encore mergés dans cette base. Aucun changement
effectué. »* Elle citait les trois appelants encore vivants, fichier et ligne. afk a
passé la porte sur la base, l'a trouvée verte, et a conclu **absorbé** : le ticket est
passé en `in-review` avec un commentaire lui disant *« vérifier puis fermer »*. Les
fichiers à supprimer sont toujours là.

**La cause.** `absorbed` se décide sur deux faits — aucun commit, base verte — et rien
d'autre. C'était la correction d'un défaut réel : un ticket vidé par son prédécesseur
brûlait ses deux essais puis partait en `ready-for-human` pour une raison fausse. Mais la
porte de la base ne prouve rien sur le contenu d'un ticket : elle est verte parce que le
dépôt compile, pas parce que la suppression a eu lieu. Un ticket de suppression est
l'espèce où l'écart se voit, il n'en est pas la seule — n'importe quel ticket dont
l'agent constate qu'il est trop tôt sort ainsi. Et le verdict n'est pas neutre : il
réétiquette et invite à fermer, donc il fait disparaître le ticket du prochain lot.

**Ce qu'on en a fait (2026-09-09).** Le troisième cas existe. Le prompt demande à la
session, quand elle ne commite rien, de nommer son cas en dernière ligne : `AFK: DEJA
LIVRE`, ou `AFK: BLOQUE <ce qui manque>`. La seconde sort **gelée** — le même verdict
qu'un bloqueur non levé, parce que c'est le même fait, dit par la session au lieu de
l'ordonnanceur : label inchangé, aucune PR, un commentaire qui cite ce qui manque, pas
de second essai (même session, même base, même conclusion), et le ticket repart au run
suivant. Sans la ligne, la porte sur la base tranche comme avant.

Atténué et pas corrigé : le témoin est la session elle-même. Une session qui refuse sans
le dire repasse pour absorbée. Le distinguer *sans* lire son texte a été écarté —
exiger un bloqueur livré dans ce run casse le cas d'origine, un ticket que le dépôt avait
déjà livré avant le run n'a aucun bloqueur dans ce run (voir docs/propositions.md).

---

## 41 — La colonne « Modèle » compte les sous-agents et fait lire un repli qui n'a pas eu lieu — atténué

*2026-09-09 · jarvis-project · #111*

**Ce qu'on a vu.** #111 portait `Model: sonnet`, la trace de l'orchestrateur affiche
`modèle : sonnet`, et le bilan met `opus-5 sonnet-5` dans sa colonne « Modèle ». La
légende sous le tableau dit qu'un modèle autre que celui demandé signifie que
`FALLBACK_MODEL` a joué — donc, à la lecture, sonnet aurait été indisponible. C'est
l'inverse : sonnet a tenu toute la session, opus n'a tourné que dans les deux sous-agents
`reviewer` que la session a lancés, et que le dépôt épingle sur opus dans
`.claude/agents/`.

**La cause.** `jmodels()` relève tous les `canonicalModel` de `modelUsage` et les rend
dédoublonnés. `modelUsage` agrège la session **et** ses sous-agents, qui portent le modèle
de leur définition et pas celui du ticket. La colonne mesure donc « quels modèles ont été
facturés » là où sa légende promet « quel modèle a répondu ». Ça touche n'importe quel
dépôt dont les `.claude/agents/*.md` nomment un modèle, et c'est justement le cas des
dépôts où l'on demande une revue avant commit.

**Ce qu'on en a fait (2026-09-09).** `subagent_stats.spawned` est lu (`jspawned`) et
affiché avec les modèles, pas dans une colonne à lui : `sonnet-5 (+2 sous-agents)`. C'est
lui qui dit si un second modèle est un repli ou une revue, et il explique du même coup une
part du coût, qui agrège les sous-agents comme `modelUsage`. La légende dit maintenant ce
qui est vrai : plusieurs modèles **sans** sous-agent = un repli ; avec, ils portent le
modèle de leur définition et pas celui du ticket.

Atténué et pas corrigé : la colonne ne dit toujours pas *lequel* des modèles était celui
de la session. Le premier `modelUsage` l'est (la session appelle l'API avant qu'aucun
sous-agent n'existe), mais s'y fier rend un repli en cours de session invisible — la liste
complète plus le nombre de sous-agents ne mentent sur rien.

---

## 43 — Le bilan chronomètre le ticket, jamais ses phases — ouvert

*2026-09-12 · jarvis-project · run du 2026-09-11*

**Ce qu'on a vu.** « Pourquoi les tickets mettent si longtemps ? » Le bilan ne peut pas
répondre : il donne une durée par ticket et rien d'autre. Il a fallu ouvrir les
`.afk/<n>-<essai>.json` un par un et comparer leur `duration_ms` au `dur` du `.status`
pour voir où passe le temps :

```
#148  ticket 20m13  session 1m28   #149  13m10 / 12m07   #150  10m59 / 10m03
#151  10m58 / 9m57  #152  16m52 / 15m52
```

Soit ~95 % en session, et **une minute** pour `SETUP_CMD` plus les deux passages de la
porte — l'inverse de ce qu'on soupçonnait. `#148` fait exception pour une autre raison :
`duration_ms` ne couvre que la boucle principale, ses deux sous-agents de revue tournaient
en arrière-plan (`duration_api_ms` = 14m47), et ces 18 minutes n'apparaissent nulle part.

**La cause.** `reap` écrit `dur=` et c'est tout. Le worker traverse pourtant quatre
phases mesurables et de nature différente — `SETUP_CMD`, la session, la porte, et
l'attente d'un verrou quand `JOBS > 1` — dont trois sont réglables (`JOBS`, `TIMEOUT`,
`VERIFY_CMD`, `SETUP_CMD`) et une ne l'est pas. Sans la découpe, la seule lecture
possible est « c'est lent », et les réglages se choisissent au pif : sérialiser la porte
n'a aucun effet là où elle dure une minute, et un dépôt dont la porte dure dix minutes
est exactement le cas inverse. `peak_context` a déjà réglé ce problème-là pour la taille
du travail ; la durée est restée un seul nombre.

**Ce qu'on en a fait.** Rien encore. Trois `st` dans le worker (`t_setup`, `t_session`,
`t_verify`, `$SECONDS` autour de chaque appel) et une colonne du résumé qui les rend
`1m / 15m52 / 0m38`. L'attente d'un verrou se déduit alors du reste : `dur` moins la
somme des trois. Reste à décider quoi faire des sous-agents en arrière-plan, qui
allongent la session sans être dans son `duration_ms` — `t_session` mesuré par afk les
compte, lui, puisqu'il chronomètre le processus `claude` jusqu'à sa sortie.

## 44 — Le plan gèle un bloqueur hors run que le run réel sait empiler — ouvert

`-n` affiche « gelé — bloqueur non livrable » pour tout ticket dont un bloqueur est
hors du lot mais porte une PR ouverte. Le run réel, lui, le lance sans broncher.

Les deux chemins ne posent pas la même question :

- `deps_state` (`afk.sh:900`) : `[[ -n "${BRANCH_OF[$b]:-}" ]] && continue` — la
  branche de la PR suffit, le ticket est prêt ;
- le plan (`afk.sh:1413`) : `[[ -n "${LIVERED[$b]:-}" ]]` — seul un ticket livré
  *dans ce run* compte, `BRANCH_OF` est ignoré.

Le plan s'auto-contredit dans la même sortie : il vient d'imprimer, à la lecture des
tickets, « · #20 : bloqueur #16 livré hors run (PR ouverte) → base origin/feat/16 ».

Vu sur Trainr le 2026-09-12, en reprenant un run interrompu : les 5 premiers tickets
étaient passés en `in-review` avec leurs PR ouvertes, et le plan du reliquat annonçait
les 4 tickets restants gelés. Rien ne l'était.

Ce que ça coûte : c'est précisément dans cette situation — reprise après interruption,
lot partiellement livré — qu'on consulte le plan avant de relancer. Il dit exactement
l'inverse de ce qui va se passer, et pousse à ne pas relancer.

Correction : au plan, amorcer `LIVERED` avec les bloqueurs qui ont déjà une branche
(`for b in "${!BRANCH_OF[@]}"; do LIVERED[$b]=1; done` avant la boucle des vagues), ou
tester `${LIVERED[$b]:-${BRANCH_OF[$b]:-}}` en 1413.

## 45 — Un empilement qui conflicte est rangé « gelé », comme un bloqueur non livré — ouvert

Un ticket dont les bloqueurs sont **tous livrés** sort « gelé » au bilan quand le merge
de leurs branches dans son worktree échoue. Le mot est le même que pour un bloqueur
jamais livré, et la colonne PR est vide dans les deux cas : rien ne distingue « son
prérequis manque » de « ses prérequis sont là mais ne tiennent pas ensemble ».

La trace existe pourtant, seule et non citée : `.afk/<n>-wt.err` contient le
`CONFLICT (content)` et les chemins en cause. Ni `<n>.out` ni `<n>.status` ne sont
écrits — `launch` échoue avant. Le bilan ne renvoie vers `<n>-wt.err` nulle part ; sa
légende ne nomme que `<n>.out`, `<n>-<essai>.json`, `<n>-verify.txt` et `<n>-ci.txt`.

Vu sur Trainr le 2026-09-12 : #23 dépendait de #19, #20, #21 et #22, tous livrés avec
leur PR. Il est sorti « gelé ». `23-wt.err` disait `CONFLICT (content): Merge conflict
in CONTEXT.md` et un second sur `app/components/Suivie.vue`. Lu sans ce fichier, le
bilan fait chercher un bloqueur manquant qui n'existe pas.

Ce que ça coûte : c'est l'information la plus utile du run — la combinaison des branches
ne tient pas — et c'est la seule qui ne remonte pas. Le diagnostic se fait à la main, en
fouillant un fichier dont la légende ne parle pas.

Correction : distinguer le résultat (`conflit` plutôt que `gelé` quand `<n>-wt.err`
contient `CONFLICT`), citer les chemins en conflit sous le tableau comme le fait déjà la
passe d'intégration pour ses branches écartées, et ajouter `<n>-wt.err` à la légende des
logs.
