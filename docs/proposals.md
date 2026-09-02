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
