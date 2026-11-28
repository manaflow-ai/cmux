#!/bin/bash
cd webviews || exit 2
st=0
for c in check:browser-lanes check:fixed-waits check:design-tokens check:catalog-unused check:surface-bypass; do
  echo "=== $c"
  bun run "$c" || { echo "FAILED $c"; st=1; }
done
echo "=== import-order + browser tests"
bun test test/import-order-lint.test.ts test/session-info-section-order-browser.test.tsx test/session-info-changes-narrow-browser.test.tsx || { echo "FAILED tests"; st=1; }
echo "=== check (all pieces)"
bun run check || { echo "FAILED check"; st=1; }
exit $st
