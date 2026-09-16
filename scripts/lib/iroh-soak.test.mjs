import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const gate = readFileSync(new URL('../run-iroh-release-gate.sh', import.meta.url), 'utf8');

test('relay-only app gates constrain both current Iroh endpoints before launch', () => {
  const beforeLaunch = gate.split('cmux_attach_ensure_mac "$TAG"')[0];
  assert.match(beforeLaunch, /defaults write "\$MAC_BUNDLE_ID" cmux\.iroh\.v2\.force-relay -bool "\$FORCE_RELAY"/);
  assert.match(beforeLaunch, /"\$IOS_BUNDLE_ID" cmux\.iroh\.v2\.config\.CMUX_IROH_V2_FORCE_RELAY -string "\$FORCE_RELAY"/);
  assert.match(gate, /defaults delete "\$MAC_BUNDLE_ID" cmux\.iroh\.v2\.force-relay/);
});
