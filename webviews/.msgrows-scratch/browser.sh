#!/usr/bin/env bash
cd "$(dirname "$0")/.."
export CMUX_BROWSER_TESTS=1
for t in test/transcript-chevron-after-label.test.ts test/received-message-steady-tone-browser.test.ts test/incoming-message-disclosure-browser.test.ts test/message-preview-browser.test.ts test/transcript-received-line.test.ts test/transcript-row-pitch-browser.test.ts test/transcript-icon-column.test.ts; do
  echo "=== $t"; bun test "$t" 2>&1 | grep -E "\(pass\)|\(fail\)|error:|Expected|Received| pass$| fail$|skip" | head -40
done
