---
name: afk-setup
description: "Configures afk.sh on a project — writes the .afk.env that defines what \"done\" means here (verification gate, dependency install). Run once per repo, after /mattpocock-skills:setup-matt-pocock-skills and before the first ./afk.sh. Triggers: /afk-setup, \"configure afk here\", \"prepare this project for afk\", \"write the .afk.env\"."
---

# /afk-setup

`afk.sh` is bare. Its defaults are cut for a pnpm monorepo; everything else (Python,
PHP, Rust, flat npm, monorepo in two halves) has to declare its own gate.
This skill reads the repo and writes `.afk.env` at its root.

**Only one question matters: which command says "this ticket is done" here?**

Everything else has a correct default. Only write into `.afk.env` what differs.

## 1 — Prerequisites

```bash
test -f docs/agents/issue-tracker.md && grep -qi github docs/agents/issue-tracker.md
```

Missing or non-GitHub → **stop**. Tell the user to run
`/mattpocock-skills:setup-matt-pocock-skills` first: `afk.sh` refuses to start without
it, and triage will not have its labels.

Also flag (without blocking) the absence of `CONTEXT.md` / `CONTEXT-MAP.md` / `docs/adr/`:
the sessions will run with no project memory.

## 2 — Find the gate

Read, in this order — the lower sources are authoritative over the ones above:

1. `package.json` (scripts), `pyproject.toml`, `Cargo.toml`, `composer.json`, `Makefile`
2. **`.github/workflows/*.yml`** — what CI requires is the best available definition of
   "done": it is the gate the PR will have to pass anyway
3. **`CLAUDE.md`** — often a hand-written "Commands" section, with the traps. The most
   reliable of the three.

Aim for **fast and with no external service**. A 15-minute gate killed by `TIMEOUT`, or
one demanding a live Postgres, protects nothing: it fails healthy tickets.

## 3 — The traps that cost a run

| Trap | Symptom | Answer |
|---|---|---|
| **`test` in watch mode** (`vitest`, `jest --watch`, `nodemon`) | the ticket dies on a 45-minute `TIMEOUT`, every time | take `test:run`, or add `--run` / `--watchAll=false` |
| **No lockfile at the root** (monorepo in two halves, Python repo) | `SETUP_CMD="auto"` installs nothing, the fresh worktree has no dependencies | declare `SETUP_CMD` explicitly |
| **Gate requiring a service** (Postgres, Redis, docker compose) | red in a throwaway worktree, for nothing | exclude it from the global gate; the tickets concerned will carry their own `Verify:` line |
| **No tests in the repo** | "green" means nothing | offer at least a typecheck / a compile, and say so plainly |
| **Indispensable gitignored files** (`.env` outside the known paths) | verification fails in the worktree for an off-topic reason | add the paths to `SEED_GLOBS` |

## 4 — Prove the gate before writing it

Non-negotiable. An untested gate is an invented gate:

```bash
timeout 180 bash -c '<the proposed command>'; echo "rc=$?"
```

- `rc=0` → good.
- `rc=124` → **it does not return**. That is the watch trap. Fix it, retry.
- anything else → either the command is wrong, or the repo is already red. Tell the two
  apart before concluding; a repo red on `main` is not a config problem.

## 5 — Propose, then write

Show the proposed `.afk.env` and **wait for approval**. Do not write it unprompted.

```bash
# .afk.env — verification gate for afk.sh
# The command line keeps the last word, hence the "${VAR:-...}".

VERIFY_CMD="${VERIFY_CMD:-<command proven in step 4>}"
```

One comment per line, saying **why** — especially when you have ruled something out
("the worker self-checks need a live database", "`test` is in watch mode").
The file is versioned: it will be reread in six months by someone who does not have
this context.

Then say it should be committed, **do not commit yourself**.

## Variables

Only put in what differs from the default.

| | default | when to override it |
|---|---|---|
| `VERIFY_CMD` | `pnpm typecheck && pnpm test && pnpm lint` | **almost always** — it is the whole point of the file |
| `SETUP_CMD` | deduced from the root lockfile (pnpm/npm/yarn) | no root lockfile, or non-JS dependencies |
| `SEED_GLOBS` | `.env`, `apps/*/.env`, `packages/*/.env` | indispensable gitignored files elsewhere |
| `MEMORY_RE` | root + `apps/*` + `packages/*` | ADR/CONTEXT conventions filed differently |
| `TIMEOUT` | `45m` | repo where tickets are systematically heavier |
| `JOBS` | `1` | never here — it is a run decision, not a project one |

`BASE_BRANCH` is deduced from the remote: do not touch it without a reason.

## What this skill does not do

- It does not run `afk.sh`. A run takes hours, detached; it has no business inside a
  session.
- It does not create the triage labels: `afk.sh` handles that at startup.
- It commits nothing.
