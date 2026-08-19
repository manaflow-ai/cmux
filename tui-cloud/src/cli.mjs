#!/usr/bin/env node
// tui-cloud — single-tenant cmux TUI cloud on Freestyle beta VMs.
//
//   tui-cloud build-snapshot        Provision a VM, bake node + cmux TUI, snapshot it
//   tui-cloud create [--snapshot <id>] [--slug <name>]
//   tui-cloud list
//   tui-cloud destroy <idOrSlug>
//   tui-cloud connect <idOrSlug>    Enroll this Mac and open the remote cmux TUI
//   tui-cloud exec <idOrSlug> <cmd...>
//
// Connect path: no freestyle PTYs, no SSH reachability needed. The VM runs a
// headless `cmux server` with iroh (NAT traversal); this Mac enrolls as a
// device over an invitation the CLI auto-approves (single tenant).
import { spawn, spawnSync } from "node:child_process";
import { writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hostname } from "node:os";
import { client, waitRunning, sh, sleep, createWithRetry, ensureCmuxDaemon } from "./client.mjs";

const CMUX_NPM_VERSION = process.env.CMUX_NPM_VERSION ?? "0.10.0";
const SESSION = process.env.TUI_CLOUD_SESSION ?? "main";
// freestyle exec has an empty environment; cmux-tui needs HOME for its state dir.
const CMUX_ENV = { HOME: "/root" };

const [cmd, ...args] = process.argv.slice(2);
const freestyle = client();

function usage() {
  console.log(`usage: tui-cloud <command>

  install                   register the provider in ~/.config/cmux/cmux-tui.json
  uninstall                 remove the provider registration
  build-snapshot            bake the base snapshot (node + cmux TUI) on a fresh VM
  create [--snapshot id] [--slug name]
  list
  destroy <idOrSlug>
  connect <idOrSlug>        enroll + open the remote TUI on this Mac
  exec <idOrSlug> <cmd...>  run a command in the VM

env: TUI_CLOUD_SECRETS (default ~/.secrets/freestyle-beta.env), CMUX_NPM_VERSION, TUI_CLOUD_SESSION`);
}

function opt(name) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
}

async function resolveVm(idOrSlug) {
  const d = await freestyle.vms.get(idOrSlug);
  return freestyle.vms.ref(d.id);
}

async function latestSnapshot() {
  const { snapshots } = await freestyle.vms.snapshots.list({ limit: 100 });
  const mine = snapshots
    .filter((s) => (s.slug ?? "").startsWith("tui-cloud-base-"))
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return mine[0] ?? null;
}

async function ensureDaemon(vm) {
  await ensureCmuxDaemon(vm, { session: SESSION });
}

const commands = {
  // Write machine_provider.command into ~/.config/cmux/cmux-tui.json so a
  // plain `cmux` (or `npx cmux`) starts with the Freestyle VM rail.
  async install() {
    const { readFileSync, writeFileSync, mkdirSync } = await import("node:fs");
    const configDir = `${process.env.HOME}/.config/cmux`;
    const configPath = `${configDir}/cmux-tui.json`;
    let config = {};
    try { config = JSON.parse(readFileSync(configPath, "utf8")); }
    catch (e) { if (e?.code !== "ENOENT") throw new Error(`cannot parse ${configPath}: ${e.message}`); }
    if (Array.isArray(config.machines) && config.machines.length > 0) {
      throw new Error(`${configPath} has a static machines array; provider mode rejects it. Remove it first.`);
    }
    const providerPath = new URL("./provider.mjs", import.meta.url).pathname;
    config.machine_provider = { ...(config.machine_provider ?? {}), command: [providerPath] };
    mkdirSync(configDir, { recursive: true });
    writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
    console.log(`installed: ${configPath}`);
    console.log(`  machine_provider.command = ["${providerPath}"]`);
    console.log(`open the TUI with: cmux   (or npx cmux)`);
  },

  async uninstall() {
    const { readFileSync, writeFileSync } = await import("node:fs");
    const configPath = `${process.env.HOME}/.config/cmux/cmux-tui.json`;
    let config = {};
    try { config = JSON.parse(readFileSync(configPath, "utf8")); }
    catch { console.log("nothing to uninstall"); return; }
    if (config.machine_provider) delete config.machine_provider.command;
    writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
    console.log(`removed machine_provider.command from ${configPath}`);
  },

  async "build-snapshot"() {
    const child = spawn(process.execPath, [new URL("./build-snapshot.mjs", import.meta.url).pathname, ...args], {
      stdio: "inherit",
    });
    child.on("exit", (code) => process.exit(code ?? 0));
  },

  async create() {
    const snapshotId = opt("snapshot") ?? (await latestSnapshot())?.id;
    if (!snapshotId) throw new Error("no tui-cloud-base snapshot found; run `tui-cloud build-snapshot` first");
    const slug = opt("slug") ?? `tc-${Date.now().toString(36)}`;
    const { vm, vmId } = await createWithRetry(freestyle, {
      snapshotId,
      slug,
      displayName: `tui-cloud ${slug}`,
      metadata: { product: "tui-cloud", role: "instance" },
      ipMode: "dualStack",
      firewall: {
        rules: [
          { action: "allow", source: {}, destination: { public: true } },
          { action: "allow", source: { public: true }, destination: { port: 22, protocol: "tcp" } },
        ],
      },
    });
    console.log(`vm ${vmId} (slug ${slug}) booting from ${snapshotId}`);
    const d = await waitRunning(vm);
    await ensureDaemon(vm);
    console.log(`ready: ${vmId}`);
    console.log(`  ipv6: ${d.publicIpv6}`);
    console.log(`  connect: tui-cloud connect ${slug}`);
  },

  async list() {
    const { vms } = await freestyle.vms.list({ metadata: "product:tui-cloud", limit: 100 });
    if (vms.length === 0) return console.log("no tui-cloud VMs");
    for (const v of vms) {
      console.log(`${v.id}  ${v.state.padEnd(8)}  ${(v.slug ?? "-").padEnd(20)}  ${v.publicIpv6 ?? ""}  ${v.createdAt}`);
    }
  },

  async destroy() {
    const id = args[0];
    if (!id) throw new Error("destroy <idOrSlug>");
    const vm = await resolveVm(id);
    await vm.delete();
    console.log(`deleted ${id}`);
  },

  async exec() {
    const [id, ...cmdParts] = args;
    if (!id || cmdParts.length === 0) throw new Error("exec <idOrSlug> <cmd...>");
    const vm = await resolveVm(id);
    const r = await vm.exec({ command: cmdParts.join(" "), timeoutMs: 300_000 });
    if (r.stdout) process.stdout.write(r.stdout);
    if (r.stderr) process.stderr.write(r.stderr);
    process.exit(r.statusCode ?? 1);
  },

  async connect() {
    const id = args[0];
    if (!id) throw new Error("connect <idOrSlug>");
    const vm = await resolveVm(id);
    await ensureDaemon(vm);

    // Mint a single-device invitation on the daemon.
    const out = await sh(vm, `cmux remote enroll create --session ${SESSION} 2>&1`, { timeoutMs: 60_000, env: CMUX_ENV });
    const invite = out.match(/cmux:\/\/enroll\/\S+/)?.[0];
    if (!invite) throw new Error(`no invite URI in enroll output:\n${out}`);

    const inviteFile = join(tmpdir(), `tui-cloud-invite-${Date.now().toString(36)}.txt`);
    writeFileSync(inviteFile, invite + "\n", { mode: 0o600 });

    // Auto-approve: poll the daemon's pending list and approve the first
    // claimant. Single tenant, so any claimant is this Mac.
    const approveLoop = (async () => {
      for (let i = 0; i < 60; i++) {
        await sleep(2000);
        try {
          const pending = await sh(vm, `cmux remote enroll pending --session ${SESSION} --json 2>/dev/null || echo '[]'`, { timeoutMs: 30_000, env: CMUX_ENV });
          const ids = [...pending.matchAll(/"invitation_id"\s*:\s*"([^"]+)"/g)].map((m) => m[1]);
          for (const pid of ids) {
            await sh(vm, `cmux remote enroll approve ${pid} --session ${SESSION} 2>&1`, { timeoutMs: 30_000, env: CMUX_ENV });
            console.error(`\n[approved invitation ${pid}]`);
            return;
          }
        } catch { /* keep polling */ }
      }
    })();

    console.log("opening remote cmux TUI (auto-approving this device)...");
    // Local client: the platform binary directly. npx would hit the user's
    // min-release-age freshness gate on cmux (published < 7 days ago).
    const localBin = new URL(`../node_modules/cmux-tui-darwin-arm64/bin/cmux-tui`, import.meta.url).pathname;
    const headless = args.includes("--headless");
    const clientArgs = ["remote", "connect", "--invite-file", inviteFile, "--device-name", hostname()];
    if (headless) clientArgs.push("--headless", "--json");
    const child = spawn(localBin, clientArgs, { stdio: "inherit" });
    child.on("exit", (code) => {
      unlinkSync(inviteFile, () => {});
      approveLoop.catch(() => {});
      process.exit(code ?? 0);
    });
  },
};

try {
  if (!cmd || cmd === "help" || cmd === "--help") usage();
  else if (!commands[cmd]) { usage(); process.exit(2); }
  else await commands[cmd]();
} catch (err) {
  console.error(`error: ${err?.message ?? err}`);
  process.exit(1);
}
