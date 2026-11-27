import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const gate = readFileSync(new URL('../run-iroh-release-gate.sh', import.meta.url), 'utf8');

test('relay-only app gates constrain both current Iroh endpoints before launch', () => {
  const beforeLaunch = gate.split('cmux_attach_ensure_mac "$TAG"')[0];
  assert.match(beforeLaunch, /defaults write "\$MAC_BUNDLE_ID" cmux\.iroh\.v2\.force-relay -bool "\$FORCE_RELAY_BOOLEAN"/);
  assert.match(beforeLaunch, /"\$IOS_BUNDLE_ID" cmux\.iroh\.v2\.config\.CMUX_IROH_V2_FORCE_RELAY -string "\$FORCE_RELAY"/);
  assert.match(gate, /defaults delete "\$MAC_BUNDLE_ID" cmux\.iroh\.v2\.force-relay/);
});

test('path setup uses valid defaults booleans and matching simulator policy', () => {
  const setup = gate.slice(gate.indexOf('# Both endpoints read the mode'), gate.indexOf('# The driver owns this unique tag'));
  for (const [mode, mac, ios] of [['relayOnly', 'true', '1'], ['automatic', 'false', '0']]) {
    const result = spawnSync('bash', ['-c', `
      set -euo pipefail
      defaults() {
        if [[ "\${4:-}" == -bool && "\${5:-}" != true && "\${5:-}" != false ]]; then
          echo 'invalid defaults boolean' >&2; return 64
        fi
        printf '%s\\n' "$*"
      }
      xcrun() { printf '%s\\n' "$*"; }
      RAW_MODE="$1"; MAC_BUNDLE_ID=mac; IOS_BUNDLE_ID=ios
      SIMULATOR_ID=owned-simulator; PRESENCE_BASE_URL=''
      eval "$SETUP"
    `, 'soak-path-test', mode], { encoding: 'utf8', env: { ...process.env, SETUP: setup } });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.stdout.includes(`write mac cmux.iroh.v2.force-relay -bool ${mac}`));
    assert.ok(result.stdout.includes(`spawn owned-simulator defaults write ios cmux.iroh.v2.config.CMUX_IROH_V2_FORCE_RELAY -string ${ios}`));
  }
});
