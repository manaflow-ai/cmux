const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const electron = require('electron');
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'cmux-desktop-test-'));
const env = {...process.env, CMUX_DESKTOP_TEST_PROFILE:profile};
delete env.ELECTRON_RUN_AS_NODE;
for (const flags of [[], ['--restore-session']]) {
  const scale = process.env.CMUX_TEST_DEVICE_SCALE;
  const result = spawnSync(electron, [...(scale ? [`--force-device-scale-factor=${scale}`] : []), path.join(__dirname, 'desktop-smoke.cjs'), ...flags], {env, stdio:'inherit', timeout:65000, windowsHide:true});
  if (result.error || result.status !== 0) {
    console.error(result.error || `Desktop test exit ${result.status}; profile retained at ${profile}`);
    process.exit(1);
  }
}
// Only remove the disposable profile allocated by this test runner.
const resolved = path.resolve(profile);
if (path.dirname(resolved) === path.resolve(os.tmpdir()) && path.basename(resolved).startsWith('cmux-desktop-test-')) {
  fs.rmSync(resolved, {recursive:true, force:true, maxRetries:5, retryDelay:200});
}
