#!/usr/bin/env bash
# Les parseurs décident quel ticket tourne, sous quel label, contre quelle porte et
# sur quelle base. S'ils dérivent, l'orchestrateur lance des tickets dont les
# bloqueurs ne sont pas levés, ou empile une PR sur la mauvaise branche. Donc : test.
set -euo pipefail
cd "$(dirname "$0")"

bash -n afk.sh
AFK_LIB=1 source ./afk.sh

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/docs/agents"
cat > "$t/docs/agents/triage-labels.md" <<'EOF'
| Label in mattpocock/skills | Label in our tracker | Meaning |
| -------------------------- | -------------------- | ------- |
| `needs-triage`             | `triage`             | ...     |
| `ready-for-agent`          | `agent:go`           | ...     |
| `ready-for-human`          | `needs-human`        | ...     |
| `in-review`                | `en-revue`           | ...     |
EOF

pushd "$t" >/dev/null
[[ "$(label_for ready-for-agent)" == "agent:go"    ]] || { echo "FAIL label_for agent"; exit 1; }
[[ "$(label_for ready-for-human)" == "needs-human" ]] || { echo "FAIL label_for human"; exit 1; }
[[ "$(label_for in-review)"       == "en-revue"    ]] || { echo "FAIL label_for in-review"; exit 1; }
popd >/dev/null
[[ -z "$(label_for ready-for-agent)" ]] || { echo "FAIL label_for sans config"; exit 1; }

# ─── blocked_refs ─────────────────────────────────────────────────────────────

got=$(blocked_refs <<'EOF' | tr '\n' ' '
## What to build

Rien à voir ici, on parle de #99 en passant.

## Blocked by

- #12
- #7

## Acceptance criteria

- [ ] pas #42
EOF
)
[[ "$got" == "12 7 " ]] || { echo "FAIL section Blocked by : '$got'"; exit 1; }

got=$(blocked_refs <<<'Blocked by: #3, #4' | tr '\n' ' ')
[[ "$got" == "3 4 " ]] || { echo "FAIL Blocked by inline : '$got'"; exit 1; }

got=$(blocked_refs <<<'## Blocked by

None — can start immediately' | tr '\n' ' ')
[[ -z "$got" ]] || { echo "FAIL 'None' : '$got'"; exit 1; }

# ─── verify_override ──────────────────────────────────────────────────────────
# Une porte de monorepo sur un ticket d'app est une contradiction : le ticket doit
# pouvoir restreindre sa propre vérification.

got=$(verify_override <<'EOF'
## What to build

Verify: pnpm turbo typecheck --filter=@hexa-zero/backend

## Acceptance criteria
EOF
)
[[ "$got" == "pnpm turbo typecheck --filter=@hexa-zero/backend" ]] || { echo "FAIL Verify: simple : '$got'"; exit 1; }

got=$(verify_override <<<'- `Verify`: pnpm lint')
[[ "$got" == "pnpm lint" ]] || { echo "FAIL Verify: puce + backticks : '$got'"; exit 1; }

got=$(verify_override <<<'verify:   npm test   ')
[[ "$got" == "npm test" ]] || { echo "FAIL Verify: casse et espaces : '$got'"; exit 1; }

got=$(verify_override <<<'Rien à déclarer ici.')
[[ -z "$got" ]] || { echo "FAIL Verify: absent : '$got'"; exit 1; }

got=$(verify_override <<<'Verify:')
[[ -z "$got" ]] || { echo "FAIL Verify: vide : '$got'"; exit 1; }

# ─── timeout_override ─────────────────────────────────────────────────────────
# TIMEOUT est global, la taille d'un ticket ne l'est pas. Une valeur mal formée doit
# être ignorée plutôt que transmise : timeout(1) refuserait de lancer la session, et
# un ticket mal rédigé coûterait un run entier.

got=$(timeout_override <<'EOF'
## What to build

Timeout: 90m

## Acceptance criteria
EOF
)
[[ "$got" == "90m" ]] || { echo "FAIL Timeout: simple : '$got'"; exit 1; }

got=$(timeout_override <<<'- `Timeout`: 2h')
[[ "$got" == "2h" ]] || { echo "FAIL Timeout: puce + backticks : '$got'"; exit 1; }

got=$(timeout_override <<<'timeout:   3600   ')
[[ "$got" == "3600" ]] || { echo "FAIL Timeout: casse et espaces : '$got'"; exit 1; }

got=$(timeout_override <<<'Rien à déclarer ici.')
[[ -z "$got" ]] || { echo "FAIL Timeout: absent : '$got'"; exit 1; }

got=$(timeout_override <<<'Timeout: quand ce sera fini')
[[ -z "$got" ]] || { echo "FAIL Timeout: mal formé doit être ignoré : '$got'"; exit 1; }

got=$(timeout_override <<<'Timeout: 90m si tout va bien')
[[ -z "$got" ]] || { echo "FAIL Timeout: durée noyée dans une phrase : '$got'"; exit 1; }

# gh rend les corps de ticket en CRLF : sans strip, la durée sortirait avec un \r et
# timeout(1) refuserait de démarrer.
got=$(printf 'Timeout: 90m\r\n' | timeout_override)
[[ "$got" == "90m" ]] || { echo "FAIL Timeout: CRLF : '$got'"; exit 1; }
got=$(printf 'Verify: pnpm lint\r\n' | verify_override)
[[ "$got" == "pnpm lint" ]] || { echo "FAIL Verify: CRLF : '$got'"; exit 1; }

# ─── deepest_branch ───────────────────────────────────────────────────────────
# La base d'une PR empilée doit être le bloqueur topologiquement le plus profond.
# L'ordre de listage de l'API ne l'est pas : prendre la dernière ne marchait que
# parce que nos arêtes avaient été créées dans l'ordre.

r="$t/repo"; mkdir -p "$r"
pushd "$r" >/dev/null
git init -qb main .
git -c user.email=a@b -c user.name=c commit -q --allow-empty -m base
git checkout -qb B; git -c user.email=a@b -c user.name=c commit -q --allow-empty -m b
git checkout -qb C; git -c user.email=a@b -c user.name=c commit -q --allow-empty -m c
git checkout -q main
git checkout -qb D; git -c user.email=a@b -c user.name=c commit -q --allow-empty -m d

[[ "$(deepest_branch B C)" == "C" ]] || { echo "FAIL deepest B C"; exit 1; }
[[ "$(deepest_branch C B)" == "C" ]] || { echo "FAIL deepest C B — l'ordre ne doit pas compter"; exit 1; }
[[ "$(deepest_branch B)"   == "B" ]] || { echo "FAIL deepest singleton"; exit 1; }
# Frères indépendants : aucune ne domine, on retombe sur la dernière listée.
[[ "$(deepest_branch C D)" == "D" ]] || { echo "FAIL deepest frères"; exit 1; }
# Branche absente (dry run : rien n'est créé) : même repli, sans planter.
[[ "$(deepest_branch B absente)" == "absente" ]] || { echo "FAIL deepest ref absente"; exit 1; }
# Une base n'est pas forcément une branche locale : origin/<x> pour un bloqueur livré
# hors run. Avec refs/heads/ seul, elle passait pour absente et déclenchait le repli.
git update-ref refs/remotes/origin/main refs/heads/main
[[ "$(deepest_branch B origin/main)" == "B" ]] || { echo "FAIL deepest ref distant"; exit 1; }
popd >/dev/null

# ── peak_context ──────────────────────────────────────────────────────────────
# Le contexte d'une requête = frais + écrit au cache + lu au cache ; on garde le max
# sur la session. Deux pièges valent ce test : "input_tokens" ne doit pas être compté
# à l'intérieur de "cache_read_input_tokens" (le guillemet ouvrant les sépare), et une
# regex passée en argument à une fonction awk s'évalue en booléen — le parseur rendait
# 3 au lieu de 139988 avant qu'on la passe en chaîne.
ctx_fixture() {
  cat <<'EOF'
{"type":"user","message":{"role":"user","content":"go"}}
{"message":{"role":"assistant","usage":{"input_tokens":4,"cache_creation_input_tokens":20000,"cache_read_input_tokens":0,"output_tokens":120}}}
{"message":{"role":"assistant","usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":98000,"output_tokens":300}}}
{"message":{"role":"assistant","usage":{"input_tokens":1,"cache_creation_input_tokens":500,"cache_read_input_tokens":50000,"output_tokens":80}}}
EOF
}
got=$(ctx_fixture | peak_context)
[[ "$got" == "99002" ]] || { echo "FAIL peak_context : '$got' au lieu de 99002"; exit 1; }
# Le pic n'est pas le dernier tour : une session peut redescendre après un compactage.
[[ "$(ctx_fixture | tail -1 | peak_context)" == "50501" ]] || { echo "FAIL peak_context tour seul"; exit 1; }
# Un transcript sans usage (session morte avant la première réponse) ne rend rien,
# et surtout pas 0 : la colonne du bilan doit afficher "—", pas "0k".
[[ -z "$(printf '{"type":"user"}\n' | peak_context)" ]] || { echo "FAIL peak_context vide"; exit 1; }
[[ -z "$(printf '' | peak_context)" ]] || { echo "FAIL peak_context stdin vide"; exit 1; }

# ─── clashing_numbers ─────────────────────────────────────────────────────────
# Le cas réel qui a motivé le parseur : sur un lot de 8 tickets, trois avaient pris
# `docs/adr/0018-…` et deux la migration `…034_…`. Aucun conflit git, ça compilait, les
# tests passaient.
clash_fixture() {
  cat <<'EOF'
docs/adr/0018-la-borne-d-un-pas-de-tir-est-en-metres.md
docs/adr/0018-un-palier-de-badge-acquis-ne-se-retire-pas.md
docs/adr/0018-les-critiques-sortent-du-detail-par-leur-propre-route.md
docs/adr/0017-les-objets-de-la-map-deviennent-une-donnee.md
apps/backend/database/migrations/1768621000034_officiel_remplace_mis_en_avant.ts
apps/backend/database/migrations/1768621000034_badge_tiers_land_on_1_5_25_50.ts
apps/backend/database/migrations/1768621000033_create_map_objects_table.ts
apps/backend/resources/map-objects/plot/center.png
apps/mobile/components/ui/PagedFooter.tsx
EOF
}
got=$(clash_fixture | clashing_numbers)
[[ $(wc -l <<<"$got") == 2 ]] || { echo "FAIL clashing_numbers : 2 collisions attendues"; printf '%s\n' "$got"; exit 1; }
grep -q '^0018\* dans docs/adr/ ' <<<"$got" || { echo "FAIL clashing_numbers ADR"; exit 1; }
grep -q '^1768621000034\* dans apps/backend/database/migrations/ ' <<<"$got" || { echo "FAIL clashing_numbers migration"; exit 1; }
# Un numéro libre ne se signale pas, et un fichier sans préfixe numérique n'entre pas.
grep -q '0017' <<<"$got" && { echo "FAIL clashing_numbers faux positif 0017"; exit 1; }
grep -qi 'pagedfooter\|center.png' <<<"$got" && { echo "FAIL clashing_numbers sans préfixe"; exit 1; }
# Le même chemin listé deux fois (deux branches qui ajoutent le MÊME fichier) n'est pas
# une collision : c'est un merge, et il se résout tout seul.
[[ -z "$(printf 'docs/adr/0018-a.md\ndocs/adr/0018-a.md\n' | clashing_numbers)" ]] ||
  { echo "FAIL clashing_numbers doublon strict"; exit 1; }
# Racine du dépôt : pas de répertoire, la ligne doit rester lisible.
printf '0001-x.md\n0001-y.md\n' | clashing_numbers | grep -q 'dans \./' ||
  { echo "FAIL clashing_numbers racine"; exit 1; }
[[ -z "$(printf '' | clashing_numbers)" ]] || { echo "FAIL clashing_numbers stdin vide"; exit 1; }

echo "ok"
