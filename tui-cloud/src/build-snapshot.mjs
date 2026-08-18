// Build the tui-cloud base snapshot on the Freestyle beta platform.
//
// The beta platform has no Dockerfile-snapshot API; a snapshot is a capture of
// a live VM (memory + disk). So "building the image" means: boot a VM from the
// platform default, provision it (node + cmux TUI + sshd), verify, then
// vm.snapshot(). Clones resume with every service already running.
//
// Usage: node src/build-snapshot.mjs [--keep-vm]
import { client, waitRunning, sh, sleep, createWithRetry } from "./client.mjs";

const CMUX_NPM_VERSION = process.env.CMUX_NPM_VERSION ?? "0.10.0";
const KEEP_VM = process.argv.includes("--keep-vm");

const freestyle = client();
const tag = `tui-cloud-build-${Date.now().toString(36)}`;
let vmId = null;

async function step(name, fn) {
  process.stdout.write(`==> ${name} ... `);
  const t0 = Date.now();
  const out = await fn();
  console.log(`ok (${((Date.now() - t0) / 1000).toFixed(1)}s)${out ? ` ${out}` : ""}`);
  return out;
}

try {
  const { vm, vmId: id } = await createWithRetry(freestyle, {
    slug: tag,
    displayName: "tui-cloud snapshot builder",
    metadata: { product: "tui-cloud", role: "snapshot-builder", tag },
    ipMode: "dualStack", // nodejs.org / npmjs are IPv4-only
    firewall: {
      rules: [
        // outbound everything (package installs)
        { action: "allow", source: {}, destination: { public: true } },
        // inbound ssh, so the same rule set is baked into clones
        { action: "allow", source: { public: true }, destination: { port: 22, protocol: "tcp" } },
      ],
    },
  });
  vmId = id;
  console.log(`builder VM ${vmId}`);

  await step("wait running", () => waitRunning(vm));

  const os = await step("probe OS", () => sh(vm, "cat /etc/os-release | head -2; ps -p 1 -o comm="));
  if (!/ubuntu|debian/i.test(os)) throw new Error(`unsupported base OS:\n${os}`);
  const hasSystemd = /systemd/.test(os.split("\n").pop() ?? "");

  await step("apt packages", () =>
    sh(vm, "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq openssh-server ca-certificates curl xz-utils tmux htop git 2>&1 | tail -2", { timeoutMs: 300_000 }));

  await step("node LTS", async () => {
    const ver = await sh(vm, "curl -fsSL https://nodejs.org/dist/index.json | python3 -c \"import json,sys; print(next(r['version'] for r in json.load(sys.stdin) if r.get('lts')))\"");
    await sh(vm, `cd /tmp && curl -fsSLO https://nodejs.org/dist/${ver}/node-${ver}-linux-x64.tar.xz && tar -xJf node-${ver}-linux-x64.tar.xz -C /usr/local --strip-components=1 && rm node-${ver}-linux-x64.tar.xz`, { timeoutMs: 300_000 });
    return sh(vm, "node --version");
  });

  await step(`cmux TUI ${CMUX_NPM_VERSION} (prebuilt linux-x64 via npm)`, async () => {
    await sh(vm, `npm install -g cmux@${CMUX_NPM_VERSION} 2>&1 | tail -2`, { timeoutMs: 300_000 });
    return sh(vm, "cmux --version");
  });

  await step("sshd configured + running", async () => {
    await sh(vm, "mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -A");
    if (hasSystemd) {
      await sh(vm, "systemctl enable ssh && systemctl restart ssh");
    } else {
      await sh(vm, "pgrep -x sshd >/dev/null || /usr/sbin/sshd");
    }
    return sh(vm, "sshd -T 2>/dev/null | grep -E '^(port|passwordauthentication|pubkeyauthentication) ' | tr '\\n' ' '");
  });

  await step("TUI smoke: headless daemon + iroh route", async () => {
    // Start the daemon the same way `tui-cloud connect` will, then stop it.
    // The snapshot must NOT capture a running daemon: its Noise identity must
    // be generated fresh per clone. freestyle exec has no HOME, so set it.
    const env = { HOME: "/root" };
    await sh(vm, "setsid nohup cmux server start --session smoke --iroh >/var/log/cmux-smoke.log 2>&1 </dev/null & sleep 5; cmux server status --session smoke >/dev/null", { timeoutMs: 120_000, env });
    const status = await sh(vm, "cmux server status --session smoke 2>&1 | head -20", { env });
    await sh(vm, "cmux server stop --session smoke 2>&1 || true", { env });
    // Wipe ALL daemon state (Noise identity, sockets) so every clone mints its
    // own identity on first start instead of sharing the builder's.
    await sh(vm, "rm -rf /root/.local/state/cmux /tmp/cmux-tui-0", { env });
    return status.split("\n").slice(0, 2).join(" | ");
  });

  const snapshot = await step("snapshot (memory+disk)", async () => {
    const r = await vm.snapshot({ slug: `tui-cloud-base-${Date.now().toString(36)}`, displayName: `tui-cloud base (cmux ${CMUX_NPM_VERSION})` });
    return r.snapshotId;
  });

  console.log(`\nSNAPSHOT READY: ${snapshot}`);
  console.log(`use: node src/cli.mjs create --snapshot ${snapshot}`);
} finally {
  if (vmId && !KEEP_VM) {
    const fs2 = client();
    await fs2.vms.delete(vmId).catch((e) => console.error(`cleanup: ${e.message}`));
    console.log("builder VM deleted");
  } else if (vmId) {
    console.log(`builder VM kept: ${vmId}`);
  }
}
