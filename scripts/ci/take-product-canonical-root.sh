#!/usr/bin/env bash
# take-product-canonical-root.sh <receipt>
#
# Print the canonical build root a downloaded app-host product was compiled
# at, after holding that root for the rest of this job on an owned Mac.
#
# A job that recompiles against a downloaded product (app-host-test-rerun.yml)
# must build at the paths the product was compiled at: its swiftmodules carry
# absolute paths into <root>/src and <root>/derived-data-compile-admission. The
# receipt's `derived` names that DerivedData, at /private/tmp/cmux-ci or, for
# an owned Mac's second compile slot, /private/tmp/cmux-ci-<n> (see
# restore-app-host-test-product.sh, which reads it the same way). A receipt
# without a canonical `derived` keeps CMUX_CI_CANONICAL_ROOT, which glaeda
# exports on an owned Mac and which is unset on Blacksmith.
#
# On an owned Mac several jobs share the roots. glaeda's helper holds this
# root's lock until the job ends, so nothing here touches a root another job
# is compiling or testing in. Ephemeral runners have no helper and no
# neighbours. CMUX_CI_CANONICAL_ROOT_HELPER overrides the helper for tests.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <cmux-test-products.json>" >&2
  exit 64
fi
receipt="$1"

producer_derived="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("derived", ""))' "$receipt")"
case "$producer_derived" in
  /private/tmp/cmux-ci/derived-data-compile-admission \
  | /private/tmp/cmux-ci-[0-9]/derived-data-compile-admission \
  | /private/tmp/cmux-ci-[0-9][0-9]/derived-data-compile-admission)
    root="${producer_derived%/derived-data-compile-admission}"
    ;;
  *)
    root="${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}"
    ;;
esac
case "$root" in
  /private/tmp/cmux-ci | /private/tmp/cmux-ci-[0-9] | /private/tmp/cmux-ci-[0-9][0-9]) ;;
  *)
    echo "take-product-canonical-root: unexpected canonical root $root" >&2
    exit 1
    ;;
esac

helper="${CMUX_CI_CANONICAL_ROOT_HELPER:-/Users/Shared/cmux-build-fleet/bin/glaeda-canonical-root}"
if [ -x "$helper" ]; then
  if ! "$helper" take "$root" --wait 1800 >/dev/null; then
    echo "take-product-canonical-root: could not hold $root for this job" >&2
    exit 1
  fi
fi
echo "$root"
