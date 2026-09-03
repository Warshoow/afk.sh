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

Les défauts 1 à 32 ont été constatés avant que ce fichier existe. Ils sont repris ici
depuis le journal tenu dans le dépôt où ils sont sortis — `docs/agents/afk.md` de
hexa-zero, qui garde le détail long, les mesures et les leçons de découpage. Ici on ne
garde que le défaut. Le **18** manque : c'était un problème de ce dépôt-là (un fichier
généré et gitignoré, donc absent d'un worktree neuf, qui faisait échouer sa porte), il
n'a rien à voir avec afk et il apparaît seulement comme révélateur du défaut 20.

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
