# Propositions et verdicts

Ce qui a été proposé pour `afk.sh`, ce qui a été décidé, et pourquoi. Une entrée par
proposition, y compris — surtout — celles qu'on refuse : une idée retenue laisse un
commentaire dans le code à côté de ce qu'elle a produit, une idée refusée ne laisse
rien, et elle revient dans trois mois avec les mêmes arguments.

Ici et pas en issues GitHub : le raisonnement s'appuie sur des numéros de ligne et des
invariants de `afk.sh`, il doit dériver avec le code et se lire sans réseau. Une issue
reste le bon endroit dès qu'il faut en discuter à plusieurs ou suivre un état.

Format : titre, verdict, raisonnement. Verdicts employés : **retenu**, **déjà fait**,
**refusé**.

---

## Le jugement autour du run, pas dedans — retenu

*2026-09-03*

Proposé : deux skills, `/afk-preflight` avant le run et `/afk-debrief` après.

L'orchestrateur n'a volontairement aucun LLM : ordonner, lancer, vérifier, pousser,
étiqueter ne demandent aucun jugement. Mais deux moments en demandent, et ils tombent
tous les deux **hors** de la boucle :

- avant : un ticket dont les critères ne sont vérifiables par aucune porte, ou qui sera
  gelé par un bloqueur déjà mergé mais non fermé, coûte `MAX_ATTEMPTS × TIMEOUT` de
  nuit — et celle de ses dépendants. `./afk.sh -n` donne déjà toute la mécanique
  (vagues, bases, gels, porte effective) ; ce qui manquait, c'est la relecture du
  *contenu*, que le script ne peut pas faire.
- après : un rouge ne dit pas de qui c'est la faute. Porte fausse, worktree mal amorcé,
  modèle indisponible, ticket trop gros, vrai échec — cinq causes, cinq fichiers
  différents à lire, cinq suites différentes.

Retenu sous forme de skills et pas de code : les deux sortent un jugement et des
propositions, jamais une action. Aucun des deux ne lance `afk.sh`, ne réétiquette ni ne
merge — sinon c'est du LLM dans la boucle, par la porte de derrière.

## Ce que la session raconte d'elle-même (`--output-format json`) — retenu

*2026-09-03*

Proposé : lancer les sessions en `--output-format json` plutôt qu'en texte, et lire
l'objet rendu.

Trois choses en sortent qu'aucune lecture de log ne donnait :

- `subtype` **nomme** la panne (`error_during_execution`, `error_max_turns`) là où le
  code de retour donnait un chiffre. C'est la différence entre « claude a rendu 1 » et
  une cause.
- `session_id` rend la session reprenable. Le worktree d'un rouge était déjà gardé et
  la session existait déjà : il ne manquait que l'identifiant pour y rentrer. Le bilan
  en fait un `(cd .afk/wt/<n> && claude --resume <id>)` — pour les rouges seulement,
  `--resume` cherchant la session dans le répertoire où elle a tourné, et le worktree
  d'un vert étant jeté.
- `total_cost_usd` et `canonicalModel` donnent le prix et le modèle réel du ticket.

Prix : `.afk/<n>-<essai>.log` devient un objet et n'est plus lisible à l'œil. Assumé —
le log de session n'était pas ce qu'on lisait pour diagnostiquer (c'est `<n>-fail.txt`),
et ce qu'il contenait est mieux servi par un `--resume`. La variante qui gardait les
deux (`stream-json` + un awk qui sépare le texte de l'objet final) a été écartée : elle
ajoute un parseur pour conserver un fichier que personne n'ouvre.

`jval` et `jmodels` lisent par `grep`, sans jq : la sortie d'erreur de la session
atterrit dans le même fichier, un parseur JSON strict refuserait de le lire — et `jq`
n'est pas dans les binaires exigés au démarrage.

## Modèle de repli quand le principal est indisponible — retenu

*2026-09-03*

Proposé : `--fallback-model`.

Un run AFK n'a personne devant lui. Sans repli, une indisponibilité passagère du modèle
sort la session en erreur, le ticket brûle ses deux essais en quelques secondes et part
en `ready-for-human` pour une raison qui n'a rien à voir avec lui — puis le suivant, et
la file entière y passe. Le drapeau ne marche qu'avec `--print`, donc exactement ici.

Le risque du repli, c'est qu'il est silencieux : une nuit peut changer de modèle sans
le dire, et le taux de vert du lendemain se lit alors sur une base fausse. C'est pour
ça, et pas pour le coût, que le bilan a gagné une colonne « modèle » — le repli n'est
acceptable qu'à condition d'être visible. Même famille que le `gh issue list` plafonné
à 30 sans le dire, ou que le cache de build qui rend un ✓ sans compiler.

## Modèle et effort par ticket — retenu

*2026-09-03*

Proposé : lignes `Model:` et `Effort:` dans le corps d'un ticket.

Même argument que `Verify:` et `Timeout:`, et c'est la raison de le retenir : le
réglage global est taillé pour le ticket moyen, et celui qui écrit le ticket est le
seul à savoir avant qu'il ne tourne que celui-ci n'est pas moyen. Une correction de
typo n'a pas besoin du modèle d'une refonte.

Les quatre lignes ne différant que par leur nom et par ce qu'elles acceptent comme
valeur, les deux parseurs existants ont été remplacés par un seul (`meta_line`) — deux
champs de plus n'ont donc coûté aucune fonction. Leurs motifs de validation vivent à
côté de lui (`RE_TIMEOUT`, `RE_MODEL`, `RE_EFFORT`) et sont sourcés par `check.sh` :
un motif recopié dans le test ne vérifierait que lui-même.

`RE_MODEL` n'est pas une liste de noms connus — elle serait périmée au prochain modèle.
Il interdit seulement ce qui n'est pas un nom. Un nom bien formé mais faux fait échouer
la session tout de suite, exactement comme une ligne `Verify:` qui ne compile pas :
c'est la même surface de confiance.

## Journal de découvertes entre tickets d'une même lignée — retenu, autrement

*2026-09-02*

Proposé : à la fin d'un ticket vert, l'agent écrit un résumé (`DISCOVERY.md`,
`.afk/findings/<n>.md`) de ce qui dépasse son périmètre ; à l'ouverture d'un ticket
dépendant, l'orchestrateur remonte le DAG et concatène les fichiers de ses ancêtres
dans son prompt.

Le problème est réel, il a coûté deux fois : le ticket absorbé, qui brûle ses deux
essais à redécouvrir seul que son travail est fait, et le contrat typé renommé par un
dépendant qui n'a pas lu l'ADR de son prédécesseur.

Mais les deux moitiés du mécanisme existent déjà. La capture : le prompt impose depuis
le début d'écrire toute décision non triviale dans un `CONTEXT.md` ou une ADR, et le
worker gronde quand rien n'a été touché. Le filtrage par le DAG : `launch()` crée le
worktree du dépendant **depuis la branche de son bloqueur**, donc l'ADR du
prédécesseur est déjà sur le disque, et la base ne contient que les ancêtres.
`.afk/findings/` aurait recopié dans un fichier éphémère ce qui est déjà commité.

Ce qui manquait n'était pas la capture, c'était le pointeur : l'agent démarre en
session neuve et ne sait pas quels fichiers ses ancêtres ont touchés. Retenu sous la
forme d'une section du prompt (`inherited_note`) construite d'un
`git diff --name-only "$BASE_REF...$head0"`, filtrée par `MEMORY_RE` pour la liste
« à lire avant de coder ». Aucun format imposé à l'agent, aucun fichier à produire.

Corollaire, et c'est la raison de ne pas passer par un fichier : plusieurs bloqueurs
directs se fusionnent tout seuls. `launch()` prend la branche dominante comme base et
**merge les autres par-dessus** dans le worktree, donc `head0` porte le travail de tous
les bloqueurs et le diff les couvre tous. Un `.discovery.md` recopié aurait posé la
question de l'ordre d'écriture et du dernier qui gagne ; un merge git ne la pose pas —
et si deux frères se recouvrent vraiment, le merge échoue et le dépendant est gelé
plutôt que lancé sur une moitié du travail. Le cinquième run du harness couvre ce cas
(deux frères indépendants, un dépendant commun) : le losange du premier run ne
l'atteignait pas, sa base contenant toujours déjà l'autre branche.

## Rapatriement des logs d'échec sur l'issue GitHub — déjà fait

*2026-09-02*

Proposé : en cas d'échec de la porte, poster le log d'erreur en commentaire de
l'issue, pour diagnostiquer au réveil depuis GitHub sans ouvrir de terminal.

C'est le comportement actuel. Après `MAX_ATTEMPTS`, le worker poste les 40 dernières
lignes de `<n>-fail.txt` sur l'issue et repasse le ticket en `ready-for-human` ; la
phase CI fait de même quand la CI du dépôt est rouge alors que la porte locale était
verte.

## Enrichir la reprise du log d'échec précédent — déjà fait

*2026-09-02*

Proposé : à la tentative 2, injecter dans le prompt le log de l'échec précédent (ou
les derniers commentaires de l'issue) pour que l'agent puisse pivoter.

C'est le bloc `--- REPRISE (essai n) ---` de `build_prompt`, qui injecte les 60
dernières lignes de `<n>-fail.txt`. Volontairement le log local et pas les
commentaires de l'issue : c'est la même information, sans un appel réseau.

## Registre de sockets, orchestrateur → worker — refusé

*2026-09-02*

Proposé : chaque worker publie son `CLAUDE_CODE_MESSAGING_SOCKET` dans
`.afk/<n>.socket`, avec `crossSessionInbound: "accept"` dans son `--settings`, pour
que l'orchestrateur puisse parler à une session en cours.

Les trois cas d'usage cités ne peuvent pas arriver :

- « un bloqueur passe au rouge pendant que son dépendant travaille » — `deps_state`
  ne rend `0` (prêt) que quand tous les bloqueurs du run sont verts. Un dépendant
  n'est jamais vivant en même temps que son bloqueur.
- « la CI d'une PR empilée casse pendant que le ticket suivant travaille dessus » —
  `ci_phase` tourne après `schedule`, plus aucun worker n'est en vie.
- « arrêt gracieux sur INT » — le travail n'est pas perdu : `result=ko` est écrit dès
  l'entrée du worker, donc `finish()` garde le worktree, arbre sale compris.

Gain restant : un `git add -A` de plus sur interruption. Prix : un fichier de
settings par worker, un socket, un chemin d'entrée de plus dans une session en
`bypassPermissions`, et la journalisation de chaque message injecté pour garder des
logs reproductibles. À reconsidérer seulement si l'ordonnanceur cesse d'attendre les
bloqueurs — c'est-à-dire s'il change de nature.

## Messagerie entre workers concurrents — refusé

*2026-09-02*

Le DAG garantit que deux workers lancés en même temps sont indépendants : ils n'ont
rien à se dire. Ce qu'ils partagent vraiment est une ressource, pas une information
(le Postgres de test, les ports, la RAM), et ça se règle par `flock` — `VERIFY_LOCK`
et le verrou `install` — pas par une négociation entre agents.

## Capture de mémoire par un LLM (claude-mem et assimilés) — refusé

*2026-09-02*

Le découpage en tickets *est* le système de mémoire : un ticket = une session neuve =
un périmètre. Les ADR et `CONTEXT.md` en sont la trace durable, écrite par l'agent qui
a pris la décision. Ajouter une capture LLM par-dessus met du bruit dans une boucle
gardée volontairement sans LLM — l'orchestrateur ordonne, lance, vérifie, pousse,
étiquette, et rien de tout ça ne demande de jugement.
