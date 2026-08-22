---
name: afk-setup
description: "Configure afk.sh sur un projet — écrit le .afk.env qui définit ce que « fini » veut dire ici (porte de vérification, installation des deps). À lancer une fois par repo, après /mattpocock-skills:setup-matt-pocock-skills et avant le premier ./afk.sh. Déclencheurs : /afk-setup, « configure afk ici », « prépare ce projet pour afk », « écris le .afk.env »."
---

# /afk-setup

`afk.sh` est nu. Ses défauts sont taillés pour un monorepo pnpm ; tout le reste
(Python, PHP, Rust, npm plat, monorepo à deux moitiés) doit déclarer sa propre porte.
Ce skill lit le repo et écrit `.afk.env` à sa racine.

**Une seule question compte : quelle commande dit « ce ticket est fini » ici ?**

Tout le reste a un défaut correct. N'écris dans `.afk.env` que ce qui diffère.

## 1 — Prérequis

```bash
test -f docs/agents/issue-tracker.md && grep -qi github docs/agents/issue-tracker.md
```

Absent ou non-GitHub → **arrête-toi**. Dis à l'utilisateur de lancer
`/mattpocock-skills:setup-matt-pocock-skills` d'abord : `afk.sh` refuse de démarrer
sans ça, et le triage n'aura pas ses labels.

Signale aussi (sans bloquer) l'absence de `CONTEXT.md` / `CONTEXT-MAP.md` / `docs/adr/` :
les sessions tourneront sans mémoire de projet.

## 2 — Trouver la porte

Lis, dans cet ordre — les sources plus bas font autorité sur celles du dessus :

1. `package.json` (scripts), `pyproject.toml`, `Cargo.toml`, `composer.json`, `Makefile`
2. **`.github/workflows/*.yml`** — ce que la CI exige est la meilleure définition de
   « fini » disponible : c'est la porte que la PR devra passer de toute façon
3. **`CLAUDE.md`** — souvent une section « Commandes » écrite à la main, avec les
   pièges. La plus fiable des trois.

Vise **rapide et sans service externe**. Une porte de 15 min tuée par `TIMEOUT` ou qui
réclame un Postgres vivant ne protège rien : elle fait échouer des tickets sains.

## 3 — Les pièges qui coûtent un run

| Piège | Symptôme | Réponse |
|---|---|---|
| **`test` en mode watch** (`vitest`, `jest --watch`, `nodemon`) | le ticket meurt sur `TIMEOUT` 45 min, chaque fois | prendre `test:run`, ou ajouter `--run` / `--watchAll=false` |
| **Pas de lockfile à la racine** (monorepo à deux moitiés, repo Python) | `SETUP_CMD="auto"` n'installe rien, le worktree neuf n'a aucune dépendance | déclarer `SETUP_CMD` explicitement |
| **Porte qui exige un service** (Postgres, Redis, docker compose) | rouge dans un worktree jetable, pour rien | l'exclure de la porte globale ; les tickets concernés porteront leur propre ligne `Verify:` |
| **Aucun test dans le repo** | « vert » ne veut rien dire | proposer au moins un typecheck / une compilation, et le dire franchement |
| **Fichiers gitignorés indispensables** (`.env` hors des chemins connus) | la vérification échoue dans le worktree pour une raison hors sujet | ajouter les chemins à `SEED_GLOBS` |

## 4 — Éprouver la porte avant de l'écrire

Non négociable. Une porte non testée est une porte inventée :

```bash
timeout 180 bash -c '<la commande proposée>'; echo "rc=$?"
```

- `rc=0` → bon.
- `rc=124` → **elle ne rend pas la main**. C'est le piège du watch. Corrige, retente.
- autre → soit la commande est fausse, soit le repo est déjà rouge. Distingue les deux
  avant de conclure ; un repo rouge à `main` n'est pas un problème de config.

## 5 — Proposer, puis écrire

Montre le `.afk.env` proposé et **attends validation**. Ne l'écris pas d'office.

```bash
# .afk.env — porte de vérification pour afk.sh
# La ligne de commande garde le dernier mot, d'où le "${VAR:-...}".

VERIFY_CMD="${VERIFY_CMD:-<commande éprouvée à l'étape 4>}"
```

Un commentaire par ligne, disant **pourquoi** — surtout quand tu as écarté quelque
chose (« les selfchecks du worker exigent une base vivante », « `test` est en watch »).
Le fichier est versionné : il sera relu dans six mois par quelqu'un qui n'a pas ce
contexte.

Dis ensuite qu'il faut le commiter, **ne commite pas toi-même**.

## Variables

Ne mets que ce qui diffère du défaut.

| | défaut | quand le surcharger |
|---|---|---|
| `VERIFY_CMD` | `pnpm typecheck && pnpm test && pnpm lint` | **presque toujours** — c'est la raison d'être du fichier |
| `SETUP_CMD` | déduit du lockfile racine (pnpm/npm/yarn) | pas de lockfile racine, ou deps non-JS |
| `SEED_GLOBS` | `.env`, `apps/*/.env`, `packages/*/.env` | fichiers gitignorés indispensables ailleurs |
| `MEMORY_RE` | racine + `apps/*` + `packages/*` | conventions ADR/CONTEXT rangées autrement |
| `TIMEOUT` | `45m` | repo où les tickets sont systématiquement plus lourds |
| `JOBS` | `1` | jamais ici — c'est une décision de run, pas de projet |

`BASE_BRANCH` se déduit du remote : n'y touche pas sans raison.

## Ce que ce skill ne fait pas

- Il ne lance pas `afk.sh`. Un run dure des heures en détaché, ça n'a rien à faire
  dans une session.
- Il ne crée pas les labels de triage : `afk.sh` s'en charge au démarrage.
- Il ne commite rien.
