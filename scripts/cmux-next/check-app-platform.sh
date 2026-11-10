#!/usr/bin/env bash
# App platform gate: runtime, generator, the @cmux/app-test harness and sample apps (bun; no Cargo, no app build).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
host="$root/cmux-tui/crates/cmux-app-host"
bun "$host/js/build.ts" --check
bun "$host/tools/gen-cmux-global.ts" --check
bun "$root/samples/apps/build.ts" --check
# The copyable examples (examples/extensions/*): each dist/main.js is its src/main.ts packed.
for example in "$root"/examples/extensions/*/; do bun "$host/tools/pack.ts" "$example" --check; done
(cd "$host/js" && bun test)
(cd "$host/app-test" && bun test)
(cd "$root/samples/apps" && bun test)
"$root/scripts/cmux-next/sync-app-runtime.sh" --check
# Zero first-party privilege (docs/app-store-platonic-ideal.md 5): every first-party app runs its
# own tests as a fork with only the public SDK; known gaps are listed in fork-check-gaps.json.
bun "$root/first-party-apps/fork-check.ts"
echo "app platform checks passed"
