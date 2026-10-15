---
name: afk-setup
description: "Configures afk.sh on a project — writes the .afk.env that defines what \"done\" means here (verification gate, dependency install). Run once per repo, after /mattpocock-skills:setup-matt-pocock-skills and before the first ./afk.sh. Triggers: /afk-setup, \"configure afk here\"."
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

Also flag (without blocking) the absence of a glossary (`GLOSSARY.md` / `GLOSSARY-MAP.md`, or
`CONTEXT.md` / `CONTEXT-MAP.md` before mattpocock-skills 1.3) and of `docs/adr/`:
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
| **Gate needing a service already running** (a Postgres, a Redis started by hand) | red in a throwaway worktree, for nothing | have the gate start it itself (`docker compose run --rm …`: afk runs one gate at a time, `VERIFY_LOCK`, and prunes its networks), or leave it out of the global gate and give the tickets concerned their own `Verify:` line |
| **No tests in the repo** | "green" means nothing | offer at least a typecheck / a compile, and say so plainly |
| **Indispensable gitignored files** (`.env` outside the known paths) | verification fails in the worktree for an off-topic reason | add the paths to `SEED_GLOBS` |

## 4 — Prove the gate before writing it

Non-negotiable. An untested gate is an invented gate. This is the one rule for proving a
command that afk will run; `/afk-preflight` and `/afk-wave` prove theirs by it:

```bash
timeout 180 bash -c '<the proposed command>'; echo "rc=$?"
```

- `rc=0` → good.
- `rc=124` → **it never returns** (`vitest` without `run`, `jest --watch`, `nodemon`). That
  is the watch trap: the ticket would die on `TIMEOUT` for a reason that is not its own.
  Fix it, retry.
- anything else → either the command is wrong, or the repo is already red. Tell the two
  apart before concluding; a repo red on `main` is not a config problem.

## 5 — Propose, then write

Show the proposed `.afk.env` and **wait for approval** before writing it.

```bash
# .afk.env — verification gate for afk.sh
# The command line keeps the last word, hence the "${VAR:-...}".

VERIFY_CMD="${VERIFY_CMD:-<command proven in step 4>}"
```

One comment per line, saying **why** — especially when you have ruled something out
("the worker self-checks need a live database", "`test` is in watch mode").
The file is versioned: it will be reread in six months by someone who does not have
this context.

Then tell the user to commit it: the commit is theirs.

## Variables

Only put in what differs from the default. The defaults are in the table of the
README's "Usage" section, next to `afk.sh`: read them there, not from memory.

| | when to override it |
|---|---|
| `VERIFY_CMD` | **almost always** — it is the whole point of the file |
| `SETUP_CMD` | no root lockfile, or non-JS dependencies |
| `SEED_GLOBS` | indispensable gitignored files elsewhere |
| `MEMORY_RE` | ADR/glossary conventions filed differently |
| `INTEGRATION_VERIFY_CMD` | the gate caches its results (`turbo`, `nx`, `pytest` cache): put the uncached form here, run once per run on the merged branches |
| `AFK_BUILD_CMD` | the tickets are built somewhere else than a local `claude -p` (contract in the README, "Building elsewhere") |
| `TIMEOUT` | repo where tickets are systematically heavier |
| `JOBS` | never here — it is a run decision, not a project one |
| `CLAUDE_CONFIG_DIR` | several Claude accounts on the machine — this repo's sessions must log in and bill on the right one, whatever the shell exports |

`BASE_BRANCH` defaults to the remote's default branch. A repo prepared by `/afk-spec`
already sets it to the landing branch; keep that value.
