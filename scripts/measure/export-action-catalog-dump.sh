#!/usr/bin/env bash
# Regenerates plans/cmux-next/action-catalog.json, the Swift dump of the action catalog
# that cmux-action-catalog's swift_parity test (english_catalog_equals_the_swift_dump)
# compares with the Rust catalog, on a fleet step (never on a laptop).
# ActionCatalogDumpTests writes it in a Debug test build under CMUX_UPDATE_ACTION_SURFACES=1;
# no other reviewed fleet script runs that suite. Standalone: no autofix calls it.
#   cmux-ci run --class exclusive --script scripts/measure/export-action-catalog-dump.sh \
#     --ref <sha on feat-cmux-next> --key <key> --artifact .build/action-catalog.patch
#   cmux-ci artifact <step id> action-catalog.patch
#   git apply --allow-empty action-catalog.patch   # no diff when the dump was current
# The dump is what the app decodes from its pinned CCmuxAppFFI, so run it where the pin
# holds the Rust catalog under test.
set -euo pipefail
# cmux-ci-warm-contract: swiftpm-v1
# shellcheck source=scripts/cmux-next/lib/warm-swiftpm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/warm-swiftpm.sh"
root="$(git rev-parse --show-toplevel)"
dump=plans/cmux-next/action-catalog.json
cmux_next_warm_build "$root/Packages/macOS/CmuxNext"
# The dump is written before its test compares it, so another failing test of the suite still
# leaves it current; as in regenerate-action-exports.sh the step then warns and still passes,
# because the fleet returns an artifact only from a step that passed.
status=0
CMUX_UPDATE_ACTION_SURFACES=1 swift test ${cmux_next_swift_args[@]+"${cmux_next_swift_args[@]}"} \
  --package-path "$root/Packages/macOS/CmuxNext" --skip-build --filter ActionCatalogDumpTests || status=$?
mkdir -p "$root/.build"
# A one-line header first: the fleet's artifact store refuses a 0-byte file.
{
  echo "export-action-catalog-dump.sh at $(git -C "$root" rev-parse HEAD): the dump's diff (none when no diff follows)"
  git -C "$root" diff --binary -- "$dump"
} > "$root/.build/action-catalog.patch"
git -C "$root" diff --stat -- "$dump"
echo "patch: .build/action-catalog.patch ($(wc -l < "$root/.build/action-catalog.patch" | tr -d ' ') lines)"
(( status == 0 )) || echo "::warning::ActionCatalogDumpTests failed (exit $status); the dump was still regenerated"
