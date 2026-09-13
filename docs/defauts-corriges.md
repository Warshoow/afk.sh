# Défauts corrigés

L'archive de [defauts.md](defauts.md) : ce qui a cassé dans afk, en vrai, pendant un run,
et qui ne casse plus. Même numérotation, mêmes règles d'écriture — seul le verdict change,
et c'est lui qui décide du fichier.

On les garde parce qu'une correction se relit : le correctif est dans `afk.sh` à côté du
code, mais ce que le défaut a coûté avant d'être vu n'est écrit qu'ici. Un commentaire du
code qui renvoie à « défaut 17 » renvoie à ce fichier-là dès que 17 est corrigé.

---

## 1 — Passphrase SSH demandée à chaque opération git — corrigé

*2026-08-18 · hexa-zero · #38*

**Ce qu'on a vu.** `Enter passphrase for key …` **deux fois par ticket** — une au `git pull`
de la base, une au `git push`. Sur 13 tickets, ~26 invites interactives dans un outil dont
le nom veut dire « away from keyboard ». Revu sur #44, en pire : le `git push` dormait en
`S+` sans rien afficher, et côté utilisateur ça ressemblait exactement à un ticket qui prend
du temps. Rien dans la sortie ne distinguait « je calcule » de « j'attends ton clavier ».

**La cause.** Remote en SSH, clé protégée par passphrase, ni `ssh-agent` ni `ssh-askpass`
dans le conteneur. En détaché — sans tty — le push échoue sec au lieu de demander, et le
travail poussé est perdu.

**Ce qu'on en a fait.** `github.com` est réécrit en HTTPS pour la durée du run
(`GIT_CONFIG_COUNT` / `KEY_n`, jamais `.git/config`), le jeton servi par
`gh auth git-credential`. `GIT_TERMINAL_PROMPT=0` : en détaché, ça échoue franchement au
lieu de dormir. Vérifié dans le conteneur — SSH échoue, HTTPS passe, aucun jeton sur le
disque.

## 2 — Le contrôle « décisions capturées » ne comprend qu'un seul contexte — corrigé

*2026-08-18 · hexa-zero · #38*

**Ce qu'on a vu.** L'agent avait mis à jour `apps/mobile/docs/adr/0002-…` — donc il *avait*
capturé sa décision — et l'avertissement « ni CONTEXT.md ni ADR touchés » s'est déclenché
quand même. Faux positif à tous les coups sur ce dépôt.

**La cause.** `grep -qE '^(CONTEXT\.md|docs/adr/)'` sur le diff. Un dépôt qui range ses
glossaires en `apps/*/CONTEXT.md` et ses ADR à deux niveaux tombe systématiquement à côté.

**Ce qu'on en a fait.** `MEMORY_RE`, surchargeable, couvre `CONTEXT.md`, `CONTEXT-MAP.md`,
`(apps|packages)/*/CONTEXT.md`, `docs/adr/` et `(apps|packages)/*/docs/adr/`.

## 3 — Le garde-fou « pas de CONTEXT.md » est un faux négatif — corrigé

*2026-08-18 · hexa-zero*

**Ce qu'on a vu.** « Les agents n'auront aucune mémoire de projet » à chaque lancement,
alors que la mémoire existe et que les agents la trouvent.

**La cause.** Même que le 2 : le garde-fou cherchait un `CONTEXT.md` à la racine, et ce
dépôt a un `CONTEXT-MAP.md` qui renvoie vers un `CONTEXT.md` par contexte.

**Ce qu'on en a fait.** Le contrôle accepte `CONTEXT.md`, `CONTEXT-MAP.md`, `docs/adr/` ou
n'importe quel `*/*/CONTEXT.md`.

## 4 — `DRY_RUN=1` n'inspectait rien — corrigé

*2026-08-19 · hexa-zero · #44 #46*

**Ce qu'on a vu.** `DRY_RUN=1 afk 44 46` n'a rien dit du fait que #46 était bloqué par #44.
Et le garde-fou « arbre sale » étant en amont, on ne pouvait même pas consulter le plan tant
qu'un fichier traînait.

**La cause.** Le script sortait **avant la boucle**, donc il n'appelait jamais `blockers()` :
ni base, ni piles, ni gelés.

**Ce qu'on en a fait.** La boucle est parcourue à blanc — branche, base, branches absorbées,
porte effective, `Timeout:` effectif, gelés — sans lancer `claude`. Le contrôle d'arbre
propre est passé **après**.

## 5 — La base d'un ticket empilé dépendait de l'ordre de listage — corrigé

*2026-08-20 · hexa-zero*

**Ce qu'on a vu.** Rien, et c'est le point : `base="${stack[-1]}"` tombait juste sur les 13
tickets du moment parce que les arêtes avaient été créées dans l'ordre topologique. Un coup
de chance.

**La cause.** Pour un ticket à plusieurs bloqueurs, la base doit être le bloqueur le plus
**profond**. Le script prenait le **dernier listé** par l'API, c'est-à-dire l'ordre
d'insertion des arêtes. Une arête ajoutée à la main plus tard, et la PR empilée présente un
diff gonflé du contenu de ses frères.

**Ce qu'on en a fait.** `deepest_branch()` choisit le bloqueur qui contient déjà les autres
(`git merge-base --is-ancestor`), avec repli sur le dernier listé si aucun ne domine.
Couvert par `check.sh` sur un vrai dépôt jetable.

## 6 — L'échec d'étiquetage était avalé — corrigé

*2026-08-19 · hexa-zero*

**Ce qu'on a vu.** Un ticket abandonné **perdait** `ready-for-agent` sans rien gagner :
il disparaissait de la requête de l'orchestrateur *et* de celle d'un humain.

**La cause.** `gh issue edit … >/dev/null 2>&1`, et le label d'échec n'existait pas encore
sur le dépôt. Le `--add-label` échouait en silence.

**Ce qu'on en a fait.** Les labels sont créés au démarrage s'ils manquent — sans `--force`,
pour ne pas repeindre un label existant — et `relabel()` affiche l'erreur de `gh` au lieu de
la jeter.

## 7 — Le label était retiré avant toute revue humaine — corrigé

*2026-08-19 · hexa-zero*

**Ce qu'on a vu.** Sur un succès, `ready-for-agent` partait dès l'ouverture de la PR. PR
refusée, ticket repris par personne.

**Ce qu'on en a fait.** Un état intermédiaire : `ready-for-agent` → `in-review`. Afk ne
reprend jamais un ticket `in-review` par listing de label ; une liste explicite le retire
avec un message (`ALLOW_REVIEW=1` pour forcer), sinon un second `gh pr create` sur la même
branche échoue.

## 8 — Une session qui plante était comptée comme un succès — corrigé

*2026-08-19 · hexa-zero · #44*

**Ce qu'on a vu.** La session s'est terminée sur `Execution error` — log de 314 octets contre
~2 Ko pour un run sain, donc `rc != 0`. Puis : le filet commite l'arbre sale, `HEAD != head0`
devient vrai **grâce au filet lui-même**, la vérification passe, la PR s'ouvre, le label part,
et le bilan annonce « vert au 1er essai : 1/1 ». Personne n'apprend que l'agent n'a jamais fini.

**La cause.** Le verdict était tiré du diff, pas du code de sortie de la session. Ici le
travail se trouvait complet ; rien ne le garantissait — **un agent qui plante à 60 % produit
exactement la même sortie verte**, `typecheck` et `lint` ne sachant pas ce qui manque. Et
`MAX_ATTEMPTS` ne servait jamais, la reprise étant court-circuitée par le succès apparent.

**Ce qu'on en a fait.** `rc != 0` ou timeout → PR ouverte **en draft**, code de sortie et
chemin du log dans le corps de la PR, ticket exclu du « vert au 1er essai » et listé en
`draft` au bilan. Le travail n'est jamais jeté ; c'est l'humain qui sort du draft.

## 9 — Le message de commit du filet atterrissait dans la PR — corrigé

*2026-08-19 · hexa-zero · #44*

**Ce qu'on a vu.** Le commit de rattrapage s'appelait `wip(#N): travail non commité par
l'agent`. Sur #44 c'était le **seul** commit d'un lot de 625 lignes, donc le message que
`master` aurait gardé. Reformulé et poussé en force à la main.

**Ce qu'on en a fait.** `feat(#N): <titre du ticket>` (`fix` si le ticket porte `bug`), et le
filet déclenché marque la PR en draft : ne pas commiter est une anomalie, pas un succès.

## 11 — La vérification ne voyait jamais la combinaison des branches — corrigé

*2026-08-19 · hexa-zero · #45 × #40*

**Ce qu'on a vu.** Chaque ticket était vérifié sur sa branche **seule**. Deux branches vertes
isolément ont produit un `CONFLICTING` côté GitHub, sur deux fichiers qu'aucun des deux
périmètres n'annonçait — un `CLAUDE.md` et un composant voisin.

**La cause.** Un agent touche plus large que le périmètre annoncé ; un ticket décrit une
intention, pas une liste de fichiers. Le risque grandit avec la taille du lot et avec les
piles, où la base d'une PR est une branche non mergée.

**Ce qu'on en a fait.** Passe d'intégration en fin de run : toutes les branches vertes
mergées dans `afk-integration`, puis la porte. Elle rapporte les conflits avec leurs fichiers
et les cassures croisées, et ne touche à aucune PR (`INTEGRATION=0` pour sauter). Elle ne
supprime pas le problème — il faudrait savoir ce qu'un agent va toucher avant qu'il tourne —
elle déplace la découverte du jour du merge à la fin du run.

## 12 — La CI du dépôt n'était jamais consultée — corrigé

*2026-08-20 · hexa-zero*

**Ce qu'on a vu.** Cinq tickets verts côté afk, et la CI **rouge sur les cinq** — un
conteneur resté sur le runner retenait un port, donc le service Postgres ne démarrait pas et
le job mourait avant le `checkout` : aucun test n'avait tourné depuis trois semaines. Afk a
poussé, ouvert les PR et retiré les labels sans jamais demander à GitHub.

**La cause.** `VERIFY_CMD` tourne en local, et rien ne lisait l'autre porte. Le point n'est
pas la panne, c'est le silence : **un ticket peut être livré, étiqueté et mergé alors que la
CI n'a jamais passé dessus.**

**Ce qu'on en a fait.** Après la PR, `gh pr checks --watch` borné par `CI_TIMEOUT`. Rouge →
ticket repassé en `ready-for-human` avec un commentaire. Timeout ou absence de checks →
avertissement, le run continue : une CI en panne renseigne au lieu de figer. (Voir le défaut
29, qui rouvre le sujet par la porte du dernier ticket.)

## 13 — Rien ne détectait un ticket devenu vide — corrigé

*2026-08-21 · hexa-zero · #64 → #65 #66*

**Ce qu'on a vu.** #64 est sorti vert **en ayant fait #65 et #66 en entier**. Sans coupure
manuelle, les deux suivants partaient sur `feat/64`, n'y trouvaient rien à faire, ne
produisaient aucun commit → `aucun commit — l'agent n'a rien produit`, deux essais chacun,
puis `ready-for-human` **pour une raison fausse**. Jusqu'à quatre sessions pour zéro, et deux
tickets étiquetés comme des échecs alors qu'ils étaient livrés.

**La cause.** Le script ne distinguait pas « l'agent a échoué » de « il n'y avait plus rien à
faire » : les deux sortaient en `aucun commit`.

**Ce qu'on en a fait.** « Aucun commit » n'est plus un verdict : la porte tourne alors **sur
la base**. Rouge → l'agent n'a rien produit, comme avant. Verte → troisième résultat,
**`absorbé`** : `in-review` + commentaire, pas de PR, ni rouge ni « vert au 1er essai », et
ses dépendants partent de la base qu'il a lui-même utilisée au lieu de geler derrière un faux
échec.

Corollaire mesuré ensuite : « absorbé » **n'est pas prédictible** depuis le recouvrement des
critères. Deux prédictions, deux fois faux — un ticket dont quatre critères sur six étaient
déjà tenus a quand même produit six fichiers de travail réel. Lancer le successeur plutôt que
le fermer à vue ; la porte tranche mieux.

## 14 — `TIMEOUT` était global alors que la taille d'un ticket ne l'est pas — corrigé

*2026-08-21 · hexa-zero · #64*

**Ce qu'on a vu.** #64 a consommé les 60 minutes entières sans commiter (31 fichiers sales à
58:29), le `timeout` a tiré, le filet a commité, la porte est passée. Résultat : PR en draft
et ticket hors du « vert au premier essai », alors que le travail était complet et que la CI
l'a confirmé.

**La cause.** Un défaut unique dimensionné pour un ticket moyen. Un ticket de refonte —
migration, formule, purge, gardes, tests, docs — n'y rentre pas.

**Ce qu'on en a fait.** Ligne `Timeout: 90m` dans le corps du ticket, symétrique de
`Verify:` : même endroit, même parseur, testé par `check.sh`. Format de `timeout(1)` ; une
valeur d'une autre forme est **ignorée** plutôt que transmise, sinon un ticket mal rédigé
empêcherait la session de démarrer. Le message de coupure rappelle l'existence de la ligne.
Première fois qu'elle a payé : un ticket à 49 min qui, au défaut de 45, aurait été tué et
compté rouge — en tête de la chaîne la plus profonde du lot.

## 15 — Le worktree d'un ticket vert survivait à la mort de l'orchestrateur — corrigé

*2026-08-21 · hexa-zero*

**Ce qu'on a vu.** Tuer l'orchestrateur entre la sortie d'un worker et sa récolte laissait le
worktree en place avec `feat/<n>` **checkout dedans** — ce que le plan refuse ensuite pour
tout run futur sur ce ticket.

**La cause.** `drop_worktree` n'était appelé que par la récolte, donc dans la boucle.

**Ce qu'on en a fait.** `trap … EXIT INT TERM` : tue la **descendance** de chaque worker (le
worker est un sous-shell, `claude` et les commandes de build sont dessous — tuer le
sous-shell seul les laissait orphelins et vivants), puis récolte les worktrees des tickets
verts ou absorbés. Les rouges et les interrompus restent : c'est là qu'on va lire.

## 16 — La passe d'intégration annonçait un verdict sans son périmètre — corrigé

*2026-08-24 · hexa-zero · lot 68-71*

**Ce qu'on a vu.**

```
merge feat/69  ✓
merge feat/70  ✗ CONFLIT
→ vérification … ✓ l'ensemble compile
```

« L'ensemble » ne portait que sur **deux branches sur trois**. Le verdict est exact — il ne
dit simplement pas de quoi il parle, et il tombe *après* la ligne qui l'a amputé. Lu au
bilan, il se lit « les trois branches se combinent », ce qui était précisément la question
ouverte. Confirmé en pire au lot suivant : `afk-integration` portait 6 branches sur 8, et le
rouge annoncé venait d'une cause (défaut 20) sans rapport avec le conflit cité sur la même
ligne — deux échecs indépendants, une seule ligne de rapport.

**Ce qu'on en a fait.** Le verdict porte son périmètre — « l'ensemble compile — PARTIEL : 6/8
branches, sans `feat/110` `feat/113` » — dans la sortie **et** dans `summary.md`, qui liste
les branches réellement mergées. Au passage : un merge **refusé** (arbre sale, base absente)
s'écrit `REFUSÉ` avec la raison de git, plus `CONFLIT` — ce n'est pas la même information et
ça envoyait chercher au mauvais endroit.

## 17 — Bases de test partagées entre worktrees — corrigé

*2026-08-28 · hexa-zero · #82*

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

## 19 — `gh issue list` plafonne à 30 sans le dire — corrigé

*2026-08-31 · hexa-zero*

**Ce qu'on a vu.** Sur un dépôt à 41 tickets ouverts, le plan à blanc affichait 30 tickets et
**6 « bloqueurs ouverts hors run »** qui n'étaient rien d'autre que des tickets tombés hors
de la tranche. Un gel silencieux : pas d'erreur, pas d'avertissement, un plan qui a l'air
complet.

**La cause.** Le listing des tickets étiquetés se faisait sans `--limit`. Le défaut de `gh`
est **30**, et il rend les plus **récents**.

**Ce qu'on en a fait.** `--limit 500`. C'est le premier défaut de la liste qui frappe
**avant** le run, au moment du plan — là où on fait le plus confiance à ce qu'on lit.

## 22 — Rien ne détectait deux tickets qui réclament le même numéro — corrigé

*2026-08-31 · hexa-zero · lot de 8*

**Ce qu'on a vu.** Un lot a produit **trois** ADR `0018-…` et **deux** migrations
`…034_…`. Aucun de ces doublons ne se signale : les noms de fichiers diffèrent, donc git ne
voit pas de conflit ; ça compile ; les tests passent. La porte est muette par construction.

**La cause.** Un numéro séquentiel est un espace de noms partagé, et chaque worktree part de
sa base sans voir ses voisins. Chaque agent a pris le numéro libre qu'il voyait, et il avait
raison.

**Ce qu'on en a fait.** `clashing_numbers` reçoit les fichiers **ajoutés** par les branches
du run et rend une ligne par collision : même répertoire, même préfixe numérique de tête,
plusieurs fichiers. Générique — ADR, migrations, n'importe quelle convention `NNN_nom` —
rejoué à la passe d'intégration, couvert par `check.sh` avec les deux collisions du lot comme
fixture. Réappliqué aux 8 branches, il retrouve exactement ce que la revue à la main avait
trouvé ; sur le lot suivant il s'est tu à raison, ce qui vaut autant.

**Revu quatre fois depuis, et le coût varie de 1 à 25.** Le détecteur tire, mais la
réparation n'est **pas** un `git mv` : un arbre mergé portait **25 renvois** à « ADR 0009 »
dans **10 fichiers**, chacun avec un `§N` qui n'a de sens que contre *son* document. Deux
règles pratiques en sont sorties :

- **le numéro reste à qui le cite le plus** (`git grep -c` tranche en une commande : 12
  renvois contre 1, 9 contre 6) ;
- un `sed` de renumérotation **laisse passer les renvois coupés par un retour à la ligne** —
  `grep -rn "ADR mobile$"` les trouve, et rien d'autre ne le ferait, un numéro d'ADR n'étant
  pas une référence que le compilateur suit.

Ce qui suit du même constat : **plus un agent documente bien, plus une collision coûte cher.**
Le vrai remède n'est pas moins de renvois, c'est de donner le numéro **avant** le run, dans
le corps du ticket, plutôt que de le laisser découvrir.

## 23 — Le bilan annonçait « intégration » deux fois — corrigé

*2026-08-31 · hexa-zero*

**Ce qu'on a vu.** Deux lignes consécutives du même nom, l'une pour le conflit et l'autre
pour le verdict, se lisaient comme deux verdicts contradictoires — d'autant plus depuis que
le verdict porte son périmètre (défaut 16).

**Ce qu'on en a fait.** Une seule ligne, le conflit en suffixe actionnable.

## 25 — Rien ne signale deux branches qui **créent** le même fichier — corrigé

*2026-09-01 · hexa-zero · #95 × #96*

**Ce qu'on a vu.** Deux tickets ont créé `apps/mobile/lib/equipment.ts` — le même besoin vu
des deux côtés de la même liste — avec deux API différentes, toutes deux justes. Les deux
branches sont vertes seules, les deux CI sont vertes, et **aucune porte ne peut voir le
problème** : chacune compile parfaitement sans l'autre. Seule la passe d'intégration l'a dit,
en `CONFLICT (add/add)`, et seulement parce qu'elle a tourné.

**La cause.** Afk **a déjà la matière** : `numbering_clashes` collecte les fichiers ajoutés
par chaque branche verte. Deux choses l'empêchent de servir :

1. `clashing_numbers` ne regarde que les noms qui **commencent par des chiffres**, c'est le
   détecteur du défaut 22 ; un chemin ordinaire n'entre jamais dans son awk ;
2. et surtout son `sort -u` d'entrée **écrase le cas même** qu'on voudrait attraper : deux
   branches qui ajoutent le **même chemin exact** produisent deux lignes identiques,
   dédoublonnées avant tout comptage. Ce qui rend le détecteur de numéros correct est
   exactement ce qui aveugle le détecteur de chemins.

**La piste.** Compter les chemins ajoutés **avant** le `sort -u`, et signaler tout chemin
ajouté par plus d'une branche. Un piège à éviter, sinon le remède fait plus de bruit que le
mal : une branche **empilée** contient les commits de sa base, donc elle « ajoute » aussi les
fichiers de son bloqueur. Il faut diffuser chaque branche contre **sa** base — celle que le
plan imprime déjà et que `<n>.status` écrit — et non contre la base commune.

**Ce qu'on en a fait (2026-09-04).** `same_path_adds` compte les chemins ajoutés **avant**
tout dédoublonnage et signale ceux qu'ajoute plus d'une branche. Le piège annoncé est
évité : chaque branche est diffusée contre **sa** base, lue dans `<n>.status`, et non
contre la base commune — sinon une branche empilée « ajouterait » aussi les fichiers de
son bloqueur. `numbering_clashes` mange la même liste, il ne perd rien.

## 26 — Les fichiers en conflit de l'intégration ne sont écrits nulle part — corrigé

*2026-09-01 · hexa-zero*

**Ce qu'on a vu.** `summary.md` dit « écartées au merge : feat/91 feat/104 feat/96 ». Il ne
dit **pas sur quoi**. `integration-merge.err` ne sert à rien : il est écrasé à chaque branche,
donc il ne porte au mieux que la dernière, et il était **vide** — git rapporte les `CONFLICT`
sur stdout, pas sur stderr. Terminal fermé, il a fallu reconstruire à coups de
`git merge-tree --write-tree --name-only` sur chaque branche, ce qui suppose de deviner
l'ordre de merge d'origine.

**La cause.** L'information existe pourtant : `integration_check` la calcule
(`git diff --name-only --diff-filter=U`), l'imprime sur la console… et la jette.

**Revu deux fois, sur une deuxième sortie.** Même histoire pour les numéros en double du
défaut 22 : l'orchestrateur imprime désormais les **noms de fichiers** en collision, ce qui
suffit à réparer sans chercher, mais `summary.md` — le seul fichier qui survit au terminal —
n'en garde que quatre mots, « + numéros en double ». Le défaut n'est donc plus dans la
détection ni dans l'affichage : il est dans ce qui est **écrit**.

**La piste.** Écrire la liste par branche dans `summary.md` ou dans un
`<branche>-conflict.txt` / `integration-clashes.txt`. C'est la donnée dont la revue a besoin
en premier : elle dit lesquels des conflits sont de la doc et lesquels sont du code, donc
combien la résolution va coûter.

**Ce qu'on en a fait (2026-09-04).** Les fichiers en conflit d'une branche sont gardés
dans `summary.md`, un par ligne sous le verdict d'intégration — avec les numéros et les
chemins en double, et les renvois du défaut 24. Un merge **refusé** y écrit sa raison
plutôt qu'une liste vide. `integration-merge.err` reste ce qu'il est : un tampon, écrasé
à chaque branche.

## 27 — L'intégration merge dans l'ordre d'achèvement et ignore la pile qu'elle a construite — corrigé

*2026-09-01 · hexa-zero · #96 sur #91*

**Ce qu'on a vu.** `integration_check` itère la liste des tickets verts, remplie **dans
l'ordre où ils finissent**. Sur ce run, `feat/96` a donc été mergée **avant `feat/91`, qui
est sa propre base** — afk le savait, il l'avait imprimé deux fois.

**La conséquence.** Honnêtement, l'ordre n'aurait pas sauvé ce run : les deux branches
conflictaient de toute façon avec d'autres. Mais tenter une branche empilée avant sa base est
un conflit **par construction**, gratuitement, et ça brouille le diagnostic — trois branches
écartées se lisent comme trois recouvrements réels alors qu'une des trois n'était qu'un ordre
inversé.

**La piste.** Trier la liste par topologie — une branche après sa base — avant la boucle de
merge.

**Ce qu'on en a fait (2026-09-04).** `merge_order` trie les branches vertes par nombre de
commits depuis la base commune avant la boucle de merge. Une branche empilée en a
strictement plus que la sienne, donc elle passe après — sans avoir à retrier le DAG, que
l'ordonnanceur a déjà fait.

## 28 — `<n>.status` est append-only, sa première ligne dit `result=ko` — corrigé

*2026-09-01 · hexa-zero · #104*

**Ce qu'on a vu.** Le fichier d'état d'un ticket **vert** se lit :

```
result=ko
branch=feat/104
base=origin/master
attempt=1
result=ok
pr=146
```

Le `result=ko` est le défaut prudent écrit au démarrage ; le vrai verdict est **ajouté** à la
fin. Un `cat` — ou un `grep result=` — donne donc `ko` en premier sur un ticket parfaitement
vert, et c'est justement le fichier qu'on ouvre pour savoir ce qui s'est passé quand le
terminal est fermé.

**La piste.** Réécrire le fichier au lieu de l'append, ou nommer le défaut autrement
(`result_initial=`).

**Ce qu'on en a fait (2026-09-04).** La deuxième piste, la plus simple : la valeur écrite
au démarrage s'appelle `result_initial`. `sget` lit la dernière ligne et n'a jamais été
concerné ; c'est le `cat` humain qui l'était. Un `result` absent vaut rouge de toute
façon, `reap` le traite dans sa branche par défaut.

## 29 — `gh pr checks --watch` n'attend pas une CI qui n'existe pas encore — corrigé

*2026-09-01 · hexa-zero · #114*

**Ce qu'on a vu.** `114-ci.txt` tient une ligne, `no checks reported on the 'feat/114'
branch`, et le ticket est classé « aucune CI déclarée ». C'est **faux** : la CI a tourné et
elle est verte, run enregistré 4 minutes plus tôt côté GitHub.

**La cause.** `gh pr checks --watch` ne surveille que des check runs **déjà existants** :
avec zéro, il ne patiente pas, il sort immédiatement. Et la phase CI tourne **en fin de
run**, donc quelques secondes après le dernier `gh pr create` — ce qui expose
structurellement le ticket qui finit en dernier. Deux situations différentes sont rendues par
la même phrase : un dépôt **sans** CI, et une CI **pas encore enregistrée**. La première est
un fait, la seconde se répare en réessayant.

**Fenêtre mesurée : ~4 secondes**, le délai entre `gh pr create` et l'enregistrement du run
par GitHub. Ce qui décide n'est donc pas la durée du dernier ticket — hypothèse écrite puis
démentie au run suivant — mais la **place du dernier PR créé dans la file de surveillance** :
les `gh pr checks` qui le précèdent suffisent en général à couvrir les 4 secondes. C'est
intermittent, pas systématique, et ça rouvre le défaut 12 par une autre porte.

**La piste.** Boucler quelques fois sur `no checks` au lieu de conclure, ou attendre que le
run existe (`gh run list --branch "$b" --event pull_request --limit 1`) avant de lancer
`--watch`. Deux minutes de patience suffisent — il manquait trois secondes.

**Ce qu'on en a fait (2026-09-04).** Quatre essais espacés de `CI_RETRY_WAIT` (10 s) tant
que la sortie dit `no checks`, au lieu de conclure au premier passage. Un dépôt sans CI
paie 30 secondes, en parallèle avec les autres PR ; un dépôt qui en a une la voit.

## 30 — « vert » + « CI non concluante » + porte réduite = rien n'a joué la porte complète — corrigé

*2026-09-01 · hexa-zero · #114*

**Ce qu'on a vu.** Le bilan imprime les deux faits, à trois lignes d'écart, et ne les croise
jamais :

```
  vert   (5) : 100 109 103 111 114
  …
  CI non concluante (1) : 114
```

`summary.md` écrit même la prémisse noir sur blanc — « les tickets marqués ⚠ ont eu une porte
locale RÉDUITE : seule leur CI a joué la porte complète » — sans en tirer la conclusion. #114
est marqué ⚠ **et** sa CI est non concluante : sa seule porte complète est celle qui n'a pas
rendu de verdict, et il reste compté « vert » sans réserve. C'est au lecteur de rapprocher
deux listes de tickets pour s'en apercevoir.

Sur ce ticket-là le trou était théorique — la porte réduite était équivalente à la complète
sur son périmètre. Mais c'est exactement la combinaison qui a laissé passer le débordement du
défaut 21, et afk ne sait pas faire la différence entre les deux cas.

**Vu deux fois de plus, sous une autre forme** : un ticket compté dans `vert (4)` **et** dans
`draft (1)`, trois lots d'affilée. Une PR en draft ne se merge pas, elle n'appartient donc pas
à la même colonne.

**La piste.** Croiser les listes avant d'imprimer : un ticket à porte réduite dont la CI n'a
pas conclu sort dans une catégorie à lui — « vert non prouvé » — ou garde `ready-for-agent`
au lieu de passer en `in-review`. Et sortir de « vert » tout ce qui porte un ⚠.

**Ce qu'on en a fait (2026-09-04).** Les listes sont croisées avant d'être imprimées.
`OK` reste la liste brute des tickets qui ont ouvert une PR ; `GREEN` en retire les
drafts et les tickets à porte réduite dont la CI n'a pas conclu, qui sortent sur leur
propre ligne, **vert non prouvé**. C'est `GREEN` qui s'affiche, et qui compte dans
`RUNS.md`.

## 31 — Une session peut rendre son tour en attendant sa porte, et ne commite pas — corrigé

*2026-09-02 · hexa-zero · #105, aggravé sur #99*

**Ce qu'on a vu.** `.afk/105-1.log` contient **une seule ligne**, et c'est le dernier message
de l'agent : `Gate still running. I'll report once it finishes.` Afk enchaîne « agent n'a pas
commité — je commit », PR en draft, « session anormale : relire avant de sortir du draft ».

**La cause.** #105 était le seul ticket du lot sans ligne `Verify:`, donc sur la porte
**complète** — plusieurs minutes. L'agent l'a lancée lui-même en fond, a rendu son tour en
l'attendant, et sa session s'est terminée là, sur une promesse de rapport qui ne pouvait plus
arriver.

**Ce qui a tenu.** Le filet « agent n'a pas commité » a produit un commit de secours, la PR
est sortie en draft, l'avertissement a demandé une relecture — et le travail était complet.
Mais la branche sort **non mergeable en l'état**, pour deux raisons qui ne sont pas dans le
code : la PR est en draft, et le sujet du commit de secours est le **titre du ticket**, pas
un message au format du dépôt. Le reword change le SHA, donc la PR ne se ferme plus toute
seule au push et il faut la fermer à la main.

**Aggravé au lot suivant : un timeout n'est pas une porte qui traîne.** `#99` sort avec
`timeout 45m` puis `agent n'a pas commité`, et son log est **vide** — la session a été
**coupée**, elle n'a pas rendu son tour. Le bilan écrit pourtant la même chose dans les deux
cas (`draft` + « session anormale ») alors que le risque n'est pas comparable : une session
coupée peut l'être au milieu d'un fichier, et la porte ne dit rien de la complétude,
seulement que ce qui existe compile. Ici c'est la **revue** qui a établi que le travail était
complet, pas afk.

**Les pistes.** La porte est **externe à l'agent** par conception : un agent qui la lance
lui-même fait le travail deux fois, et c'est cette exécution-là qui a mangé son tour. Une
ligne dans le prompt (« ne lance pas la porte, commite ») coûte moins qu'un filet de plus.
Et distinguer au bilan la session **coupée** de la session qui a **rendu son tour** : ce
n'est pas la même relecture.

**Ce qu'on en a fait (2026-09-04).** Les deux pistes. Une ligne du prompt dit à l'agent de
ne pas lancer la porte lui-même — elle est externe par conception, la lancer la fait
tourner deux fois. Et le bilan distingue les trois anomalies qui mettent une PR en
draft : `coupée` (le `timeout` a tiré, la session peut l'avoir été au milieu d'un
fichier), `anormale` (elle s'est arrêtée entre deux actions), `non commité` (le travail
est là, seul le commit manquait). Le corps de la PR porte la même distinction.

## 32 — Un push refusé est rapporté comme une implémentation ratée — corrigé

*2026-09-02 · hexa-zero · #86*

**Ce qu'on a vu.** #86 sort `rouge`, sans PR, « passé en ready-for-human ». Le fichier
`.afk/86-push.txt` dit tout autre chose :

```
! [remote rejected] feat/86 -> feat/86 (refusing to allow an OAuth App to create
  or update workflow `.github/workflows/deploy.yml` without `workflow` scope)
```

**La cause.** Le jeton du conteneur ne porte pas la portée `workflow`, et GitHub refuse à un
jeton d'application OAuth de créer ou modifier un fichier sous `.github/workflows/`. Le
ticket touchait un workflow : le push ne pouvait pas passer, quelle que soit la qualité du
travail.

**L'impact.** La branche est **complète, verte et commitée en local**, et elle sort du run
par la porte des échecs. Quatre conséquences en cascade : pas de PR, donc la phase CI ne la
voit pas ; exclue du merge d'intégration, qui annonce donc un partiel ; rangée au bilan dans
la même colonne qu'un ticket dont le code est faux, sans rien pour les distinguer ; et le
bilan **ment** sur le dernier point — il annonce `→ passés en ready-for-human` alors que
l'étiquetage vient après le push dans la boucle et n'a pas eu lieu. Conséquence : le run
suivant reprendrait le ticket depuis zéro.

**La piste.** Un push refusé n'est pas un essai raté. Ne pas relancer de session — le second
essai échouera identiquement —, ne pas compter la branche rouge, et l'annoncer sur sa propre
ligne du bilan : « poussée refusée (1) : 86 », avec la raison lue dans `<n>-push.txt`. La
branche locale est déjà gardée ; c'est le classement qui trompe.

**Ce qu'on en a fait (2026-09-04).** Un push refusé a sa propre catégorie : ni relance de
session, ni label changé, ni comptage dans les rouges. Sa ligne du bilan reprend la
raison du remote lue dans `<n>-push.txt`, son worktree est gardé comme celui d'un rouge
et sa session reste reprenable. Ses dépendants gèlent quand même — sa branche n'est pas
sur le remote, ils n'ont rien sur quoi s'empiler.

## 33 — La ligne `Verify:` n'est pas validée, et la prose part au `bash -c` — corrigé

*2026-09-04 · jarvis-project · #40 → #54*

Constaté au `afk -n` et reproduit à la main, **avant** de lancer : le run n'a pas eu lieu.

**Ce qu'on a vu.** Les quinze tickets du lot écrivent leur porte comme on l'écrit dans un
ticket bien rédigé — la commande en `code`, puis ce qu'elle ne couvre pas, en français :

```
**Verify:** `ruff check jarvis/ && python -m pytest tests/ -q`, plus un test neuf par point :
```

`meta_line Verify` en tire :

```
** ruff check jarvis/ && python -m pytest tests/ -q, plus un test neuf par point :
```

et c'est ça qui devient la porte. Joué comme afk le joue :

```
$ bash -c "** ruff check jarvis/ && python -m pytest tests/ -q, plus un test neuf par point :"
bash: line 1: c2.sh: command not found
rc=127
```

`**` a globé sur le cwd et bash a tenté d'exécuter le fichier trouvé.

**La cause.** `meta_line` prend un motif de validation en `$2`, et les quatre champs ne
l'emploient pas pareil : `Timeout`, `Model` et `Effort` en passent un (`RE_TIMEOUT`,
`RE_MODEL`, `RE_EFFORT`), `Verify` n'en passe aucun — donc le motif par défaut, `.+`.
Tout ce qui suit le `:` est accepté tel quel. Le commentaire au-dessus de la fonction
énonce pourtant déjà la règle : « Une valeur qui ne passe pas son motif est IGNORÉE
plutôt que passée telle quelle à claude(1) ou timeout(1) ». `Verify` est le seul des
quatre à ne pas l'appliquer, et le seul dont la valeur soit exécutée.

Le `**` vient du gras markdown : le premier `sed` mange `[[:space:]>*+-]*` avant le nom du
champ, mais les deux astérisques fermants sont **après** le `:`, donc hors de sa portée.

**L'impact.** Quinze tickets rouges aux deux essais, en quelques secondes chacun, pour une
raison qui n'a rien à voir avec leur contenu — et le `VERIFY_CMD` du `.afk.env`, écrit
exprès pour ce dépôt, n'est jamais joué une seule fois. Une nuit entière, un lot entier.
Le mode `-n` affiche la valeur extraite, `** ruff check …` : elle est lisible avant de
lancer, mais elle se lit comme un artefact d'affichage, pas comme la commande qui va
tourner.

**La piste.** Donner à `Verify` un motif comme aux trois autres : n'accepter la valeur que
si elle est **entièrement** un seul span backtick (`` `cmd` ``), sinon retomber sur
`VERIFY_CMD`. Une ligne de prose n'est alors plus une porte, c'est une note pour l'agent —
ce qu'elle est. Sur ce lot, les quinze retombent sur `ruff check jarvis/ && python -m
pytest tests/ -q`, qui est la bonne porte.

L'autre bord — réécrire les corps de tickets en commande nue — coûte plus et ne protège
pas le ticket bien rédigé suivant, sur ce dépôt ou sur un autre.

**Ce qu'on en a fait (2026-09-04).** `meta_line` nettoie la valeur avant de la valider :
le gras qui suit le `:` — hors de portée du premier `sed`, qui ne mange que ce qui précède
le nom du champ — puis, si la valeur **commence** par un span backtick, on ne garde que
lui. La prose qui suit est une note pour l'agent, pas une porte. La forme nue du README
(`Verify: pnpm test`) reste acceptée telle quelle : l'imposer aurait cassé tous les
tickets déjà écrits.

Et `Verify` reçoit enfin son motif, `RE_VERIFY`, comme les trois autres champs : la valeur
est refusée si elle finit par `:`. C'est la forme d'une phrase d'introduction, et c'est
exactement celle qui a fini au `bash -c`. Un ticket refusé retombe sur `VERIFY_CMD`.

**Complété le même jour, sur les quinze mêmes tickets.** Le nettoyage ci-dessus en sauvait
onze et en laissait passer trois : `#51`, `#52` et `#54` écrivent une porte qui **commence
en français** et cite ses commandes au milieu (« à la main, `python -m jarvis hub` +
`npm run dev` : … »). Elle ne commence pas par un span, donc le point 2 n'a rien à y garder ;
elle ne finit pas par `:` mais par un point, donc `RE_VERIFY` l'acceptait ; et le `` s/`//g ``
effaçait ses backticks avant que quiconque puisse s'en servir. Les trois repartaient
entières au `bash -c` — `à: command not found`, rouge aux deux essais.

Les backticks ne tombent donc plus que si la valeur **est** le span tout entier, et
`RE_VERIFY` refuse celle qui en garde un : après nettoyage, un backtick résiduel ne peut
plus venir que d'une prose qui cite des commandes. C'est la seule trace qui la distingue
d'une commande, et l'effacer aveuglément la détruisait. Prix payé, assumé : une commande à
substitution `` `cmd` `` à l'ancienne est refusée aussi — elle s'écrit `$(cmd)`.

**Ce que ça ne rattrape pas.** `#42` déclare `` `npm run dev` `` en tête de sa ligne : un
span, en première position, syntaxiquement une commande — acceptée, et c'est un serveur de
développement qui ne rend jamais la main. Le ticket meurt sur `TIMEOUT`, deux fois, budget
plein. Aucun motif ne distingue une commande qui finit d'une commande qui tourne (défaut
14 le disait déjà de `npm test` sans `run`) : ça se corrige dans le ticket, pas ici.

## 34 — Sans CI déclarée, tout ticket à `Verify:` sort « vert non prouvé » — corrigé

*2026-09-04 · jarvis-project · #40 → #54*

**Ce qu'on a vu.** Le lot déclare quinze `Verify:`, et le dépôt ne déclare aucun workflow
GitHub. `UNPROVEN` se remplit sur `CI non concluante ET "${VERIFY[$t]}" != "$VERIFY_CMD"` :
les deux termes sont vrais pour les quinze. Tout ce qui serait vert sortirait « vert non
prouvé », et chaque ligne du bilan porterait le `⚠`.

**La cause.** La comparaison est une égalité de chaînes avec le réglage global, et elle sert
de proxy pour « porte **réduite** ». Un `Verify:` qui ajoute à la porte complète au lieu de
la réduire est classé pareil. Sur un dépôt sans CI, le second terme du `ET` est vrai en
permanence : il ne filtre plus rien.

**L'impact.** La colonne ne distingue plus rien de ce pour quoi elle a été ajoutée (défaut
30) : quinze lignes marquées identiques, et le vrai « vert non prouvé » s'y noierait. Pas de
dégât sur le code, du bruit sur le seul document qu'on lit au réveil.

**La piste.** Le défaut 33 corrigé, les quinze retombent sur `VERIFY_CMD` et la colonne se
vide d'elle-même — c'est probablement tout ce qu'il faut. Reste que sur un dépôt sans
workflow, `CI_TIMEOUT=0` dans le `.afk.env` dit déjà « ne pas consulter » : le classement
pourrait le lire comme « pas de CI attendue » plutôt que comme « CI non concluante », et ne
pas marquer non prouvé ce que personne n'attendait.

**Ce qu'on en a fait (2026-09-04).** « Aucune CI déclarée » sort de `CI_UNKNOWN` pour son
propre tableau, `CI_NONE`. La première est une propriété du **dépôt**, vraie pour tous les
tickets de tous les runs ; la seconde est un verdict qui manque sur ce ticket-là. Seule la
seconde peut rendre un ticket « vert non prouvé ». Quand le run entier n'a aucune CI, le
bilan le dit **une fois**, en nommant les tickets à porte réduite — le dire quinze fois
n'apprend rien au quinzième que le premier n'ait déjà dit.

Le premier terme du `ET` reste une égalité de chaînes avec `VERIFY_CMD` : elle ne
distingue pas une porte réduite d'une porte élargie. Rien ne le permet sans exécuter les
deux, ce qui est le prix qu'on refuse justement de payer.

## 35 — `git merge -q` écrit sur stdout, donc tout ticket qui absorbe une branche meurt en 0s — corrigé

*2026-09-04 · jarvis-project · #46 #48 #50*

**Ce qu'on a vu.** Trois tickets sortis rouges en `0m00s`, `0m02s`, `0m03s`, sans une ligne
de session, sur le même message :

```
    worktree    : Auto-merging CLAUDE.md
  /workspaces/jarvis-project/.afk/wt/50
  afk: line 705: cd: $'Auto-merging CLAUDE.md\n/workspaces/jarvis-project/.afk/wt/50': No such file or directory
    ✗ worktree inaccessible
```

Les trois — et eux seuls — avaient une ligne `absorbe :`. Cinq autres tickets ont gelé
derrière eux : huit des quinze du lot perdus, sur un run par ailleurs vert 7/7.

**La cause.** `make_worktree` rend le chemin du worktree **sur stdout**, et son appelant le
lit par `wt=$(make_worktree …)`. Dans sa boucle d'absorption, `git merge -q --no-edit`
n'est pas silencieux : `-q` tait le diffstat, pas les « Auto-merging <fichier> » du moteur
de fusion, qui sortent sur **stdout**. Ils se retrouvent donc collés devant le chemin, et le
`cd` échoue sur une chaîne à trois lignes. Le déclencheur n'est pas « absorber », c'est
« absorber une branche qui touche un fichier déjà touché par la base » — une fusion sans
recouvrement ne dit rien et passe.

**L'impact.** Un ticket sain noté rouge sans avoir été lancé, et sa descendance gelée. Le
prix est maximal sur un lot empilé : ce sont les tickets les plus tardifs, donc les plus
chers à refaire, et le rouge accuse le worktree plutôt que la fusion.

**Pourquoi `harness.sh` ne l'a pas vu.** Il couvre pourtant le cas (« frères indépendants :
l'un sert de base, l'autre est absorbé »), et il passe **avant comme après** la correction :
ses branches absorbées ne modifient aucun fichier commun, donc la fusion reste muette. Le
cas manquant n'est pas l'absorption, c'est le recouvrement.

**Ce qu'on en a fait (2026-09-04).** La fusion écrit dans `<n>-wt.err` — `>>"$AFK_DIR/$ticket-wt.err" 2>&1` —
où le worktree tient déjà sa trace, plutôt que `>/dev/null` : le fichier fusionné est
exactement ce qu'on veut lire quand une absorption tourne mal. Reste à donner au fixture du
harness deux branches absorbées qui se recouvrent, sans quoi la même classe de fuite
reviendra par un autre `git` bavard.

## 36 — « aucune CI sur ce dépôt » ne descend pas dans `summary.md`, qui continue d'y renvoyer — corrigé

*2026-09-04 · jarvis-project · #73, #75*

**Ce qu'on a vu.** Deux tickets verts, dont #75 porteur d'une ligne `Verify:` strictement
plus large que la porte globale (`ruff && pytest && (cd hub && npm run build)`). La porte a
tourné en entier : 379 tests, puis `vite build` vert. `.afk/summary.md` le marque `ok ⚠` et
affirme « les tickets marqués ⚠ ont eu une porte locale RÉDUITE (ligne `Verify:`) : seule
leur CI a joué la porte complète ». Le dépôt n'a pas de `.github/workflows`.

**La cause.** La phrase de la ligne 1276 est un `printf` inconditionnel dans le bloc qui
écrit `summary.md`. La correction du défaut 34 avait ajouté la contre-phrase — « aucune CI
sur ce dépôt : la porte locale est la seule qui ait joué » — mais en `echo`, ligne 1450,
donc sur stdout : elle atterrit dans `run.log` et jamais dans le bilan. Les deux documents
disent l'inverse l'un de l'autre, et 34 se voulait justement « le bilan le dit une fois ».

**L'impact.** Le seul document que le debrief demande d'ouvrir en premier renvoie à une CI
qui n'existe pas, et présente comme insuffisamment vérifié le ticket qui l'a été le plus.
Sur ce run, ça coûte de rouvrir `75-verify.txt` pour constater que le build avait tourné —
exactement le travail que la ligne `Verify:` était censée éviter.

**Le correctif.** La phrase de `summary.md` est passée sous la même condition que celle du
bilan (`${#CI_NONE[@]} == ${#OK[@]}`) : sur un dépôt sans workflow, le résumé dit lui aussi
que la porte locale est la seule qui ait joué. Et « RÉDUITE » devient « REMPLACÉE » partout
— bilan, résumé, corps de PR : la ligne du ticket remplace la porte globale, qu'elle soit
plus étroite ou plus large, et ça au moins on le sait sans exécuter les deux. Le run 7 du
harness vérifie maintenant `summary.md`, pas seulement stdout.

## 37 — La dernière durée affichée sous un ticket est celle de la porte, pas du ticket — corrigé

*2026-09-07 · hexa-zero*

**Ce qu'on a vu.** Un ticket qui a tourné plus de trente minutes se termine sur
`Time:    2m3.821s`. Soit la mesure est fausse, soit le ticket a fini vite et le run
continue dans le vide.

**La cause.** Ni l'un ni l'autre : cette ligne n'est pas d'`afk`, qui n'imprime jamais de
millisecondes (`fmt_dur` rend `2m03s`). C'est le lanceur de tests du projet — Japa, sur ce
dépôt — et elle chronomètre **la porte**. En parallèle, `reap` annonce la durée du ticket
dans l'en-tête `═══ #N — titre (32m10s) ═══` puis recopie tout son log dessous : trente
lignes plus tard, l'en-tête est hors de l'écran et la dernière durée visible est celle de
la porte.

**Le correctif.** `reap` redit sa mesure **après** le dump, en nommant le ticket et en
précisant que les durées du dessus sont celles de la porte. Rien à changer au calcul, qui
était juste.

## 38 — La base n'est jamais passée à la porte avant le run, et chaque ticket la rediagnostique à ses frais — corrigé

*2026-09-07 · hexa-zero · #169 à #179 (11 tickets, deux runs)*

**Ce qu'on a vu.** Onze tickets lancés sur `origin/develop`, dont six sortis rouges au
premier essai. Les six échouent sur **le même test**, dans un fichier qu'aucun des onze ne
nomme : `apps/backend/tests/functional/map_objects.spec.ts`, qui attend sept objets de map
quand le tableau de la commande d'import en compte dix depuis un commit poussé la veille
directement sur `develop` (donc sans PR, donc sans CI). Un test rouge sur 605.

Les onze branches ont corrigé ce test. Sept portent pour ça un commit à part, avec sept
messages différents (« la palette importe dix objets, plus sept — le test le dit », « the
seeder assertion catches up with the ten versioned map objects », …) ; les quatre autres
l'ont plié dans leur commit de feature. Six ont brûlé un second essai complet pour le
découvrir.

**La cause.** `afk` ne passait la porte sur `BASE_REF` que dans un seul cas : quand la
session n'avait produit **aucun commit** (« aucun commit — je passe la porte sur la base
pour trancher »). Dès que l'agent commite, la porte ne juge plus que `base + ticket`, et
rien ne sépare les deux termes. La machinerie existait donc déjà — elle n'était simplement
jamais appelée en amont, alors que le run paie de toute façon une exécution complète de la
porte à la passe d'intégration.

**L'impact.** La trace accuse le mauvais coupable, et elle le fait onze fois. Le ticket
rouge porte `reason=verify`, son `<n>-fail.txt` nomme un test hors de son périmètre, et le
bilan l'affiche « rouge » : #169 est parti en `ready-for-human` sur un défaut qui n'est pas
le sien. Le prix se paie trois fois — les six seconds essais, l'attention de onze agents
sur un test hors sujet, et sept corrections concurrentes du même fichier à relire une par
une au merge.

**Le correctif.** `base_check` passe la porte une fois sur `BASE_REF`, dans un worktree
détaché, avant le premier worktree de ticket. Verte, elle le dit en une ligne. Rouge, elle
nomme ce qui échoue, garde `.afk/base-verify.txt`, et le fait redire au bilan et dans
`summary.md` : un rouge de ticket dont l'échec y figure aussi n'est pas imputable au
ticket. Le run **continue** — le lanceur est parti se coucher, et un run qui s'arrête sur
une base rouge coûte la nuit entière. Le coût est d'une exécution de porte par run, celle
que la passe d'intégration exécute déjà à la fin. Run 9 du harness.

## 39 — La colonne « Coût » du bilan annonce un cumul et n'affiche que le dernier essai — pas un défaut

*2026-09-07 · hexa-zero · #179*

**Ce qu'on croyait voir.** `summary.md` donne #179 à `$11.0831` sur deux essais quand son
`.afk/179.status` porte deux lignes, `cost=8.9192` puis `cost=11.0831` — donc un ticket à
$20.00 dont le bilan ne montrerait que 55 %.

**Pourquoi c'est faux.** `cost` est déjà cumulé **dans le worker** : il part de 0 et chaque
essai écrit la somme (`awk 'BEGIN{printf "%.4f", a+b}'`). La dernière ligne du `.status`
est donc le total, pas le dernier essai — $11.0831 contient les $8.9192, et le second essai
a coûté $2.16. Le `sget` qui lit la dernière ligne rend exactement ce que la légende
promet, et le harness l'assure depuis le deuxième run : deux sessions à $0.50 sortent
`$1.0000` au résumé.

**Ce qu'il faut en retenir.** Additionner les lignes `cost=` d'un `.status` compte deux
fois. Les chiffres cités dans le défaut 38 avaient été obtenus comme ça, et étaient à peu
près du double.

## 42 — La colonne « Contexte » est vide dès que le chemin du dépôt contient un tiret bas — corrigé

*2026-09-11 · jarvis-project · #148–#152*

**Ce qu'on a vu.** La colonne « Contexte » du bilan à `—` sur les cinq tickets du run, et
sur les trois du run précédent. Huit tickets de suite sans une seule mesure, alors que la
légende sous le tableau explique en trois lignes comment la lire, et que `/afk-debrief`
en fait le premier signal d'un ticket trop gros. Rien dans la sortie ne distingue « aucun
transcript trouvé » de « ce ticket n'avait rien de remarquable » : les deux s'écrivent `—`.

**La cause.** `ctx_of()` reconstruit le nom du répertoire où Claude Code range les
transcripts, `$CLAUDE_CONFIG_DIR/projects/<cwd de la session>`, en remplaçant les
séparateurs du chemin : `sed 's#[/.]#-#g'`. Claude Code remplace aussi le **tiret bas**.
Ici le worktree est `/home/joffrey_guilmeau/…/.afk/wt/152` : afk cherchait
`-home-joffrey_guilmeau-…`, le répertoire s'appelait `-home-joffrey-guilmeau-…`. Le
`[[ -d "$d" ]] || return 0` en tête de la fonction avale l'écart sans un mot. Ça ne
dépend d'aucun dépôt : n'importe quel nom d'utilisateur ou de répertoire portant un
tiret bas éteint la colonne partout.

**Ce qu'on en a fait.** Une classe de caractères de plus : `sed 's#[/._]#-#g'`. Vérifié
en reconstruisant le chemin des cinq worktrees du run, qui tombent tous sur le répertoire
réel, et en rejouant `peak_context` dessus : 178k, 168k, 147k, 185k, 138k. Le découpage
du lot était donc juste — aucun ticket au-dessus d'un cinquième de la fenêtre — mais
c'est une chose qu'on n'a apprise qu'après avoir réparé le thermomètre.

## 43 — Le bilan chronomètre le ticket, jamais ses phases — corrigé

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

**Ce qu'on en a fait (2026-09-13).** Trois `st` dans le worker — `$SECONDS` autour de
`SETUP_CMD`, de chaque `claude -p` et de chaque passage de la porte, les deux derniers
cumulés sur les essais comme le coût — et une colonne « Phases » du résumé qui les rend
`0m58s / 15m52s / 0m38s`. La quatrième phase, l'attente d'un verrou, ne se mesure pas :
elle se déduit, `durée` moins la somme des trois, et la légende le dit avec la valeur de
`JOBS`. Les sous-agents en arrière-plan sont comptés dans `t_session` sans qu'on ait eu à
décider : c'est afk qui chronomètre, du lancement du processus `claude` à sa sortie, là où
`duration_ms` ne couvre que la boucle principale.

## 44 — Le plan gèle un bloqueur hors run que le run réel sait empiler — corrigé

`-n` affiche « gelé — bloqueur non livrable » pour tout ticket dont un bloqueur est
hors du lot mais porte une PR ouverte. Le run réel, lui, le lance sans broncher.

Les deux chemins ne posent pas la même question :

- `deps_state` : `[[ -n "${BRANCH_OF[$b]:-}" ]] && continue` — la
  branche de la PR suffit, le ticket est prêt ;
- le plan (bloc `DRY_RUN`) : `[[ -n "${LIVERED[$b]:-}" ]]` — seul un ticket livré
  *dans ce run* compte, `BRANCH_OF` est ignoré.

Le plan s'auto-contredit dans la même sortie : il vient d'imprimer, à la lecture des
tickets, « · #20 : bloqueur #16 livré hors run (PR ouverte) → base origin/feat/16 ».

Vu sur Trainr le 2026-09-12, en reprenant un run interrompu : les 5 premiers tickets
étaient passés en `in-review` avec leurs PR ouvertes, et le plan du reliquat annonçait
les 4 tickets restants gelés. Rien ne l'était.

Ce que ça coûte : c'est précisément dans cette situation — reprise après interruption,
lot partiellement livré — qu'on consulte le plan avant de relancer. Il dit exactement
l'inverse de ce qui va se passer, et pousse à ne pas relancer.

**Ce qu'on en a fait (2026-09-13).** `LIVERED` est amorcé avec les bloqueurs qui ont déjà
une branche, avant la boucle des vagues : le plan pose désormais la même question que
`deps_state`. Le harness rejoue le lot du quatrième run en `-n` et vérifie les deux moitiés
— la base annoncée est bien `origin/feat/99`, et le mot « gelé » n'apparaît nulle part.

## 45 — Un empilement qui conflicte est rangé « gelé », comme un bloqueur non livré — corrigé

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

**Ce qu'on en a fait (2026-09-13).** Les trois. Le ticket reste dans `SKIP` — ses
dépendants gèlent pour la même raison qu'avant — mais il entre aussi dans `CONFLICT`, et
le bilan écrit **conflit**. Les chemins sont extraits de `<n>-wt.err` au moment où le
merge échoue, dits à l'écran et repris sous le tableau comme ceux de la passe
d'intégration, avec le nom du journal. Et `<n>-wt.err` est dans la légende des logs.
