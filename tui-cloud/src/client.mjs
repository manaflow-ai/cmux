// Freestyle beta client for the single-tenant account.
//
// Credentials come from ~/.secrets/freestyle-beta.env (FREESTYLE_API_KEY,
// FREESTYLE_API_URL). That file is the user's own beta account; every VM and
// snapshot this product creates lives there. No multi-tenancy.
import { readFileSync } from "node:fs";
import { Freestyle } from "freestyle";

const DEFAULT_SECRETS = `${process.env.HOME}/.secrets/freestyle-beta.env`;

export function loadEnv(path = process.env.TUI_CLOUD_SECRETS ?? DEFAULT_SECRETS) {
  const out = {};
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    out[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return out;
}

let cached;
export function client() {
  if (cached) return cached;
  const env = loadEnv();
  if (!env.FREESTYLE_API_KEY) throw new Error("FREESTYLE_API_KEY missing from secrets");
  cached = new Freestyle({
    apiKey: env.FREESTYLE_API_KEY,
    baseUrl: env.FREESTYLE_API_URL || undefined, // SDK default is the beta API
  });
  return cached;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Freestyle returns 429 "server is at capacity" when the fleet is full; it is
// transient. Retry VM creation with backoff before surfacing it.
export async function createWithRetry(freestyle, options, { attempts = 6 } = {}) {
  let lastErr;
  for (let i = 0; i < attempts; i++) {
    try {
      return await freestyle.vms.create(options);
    } catch (err) {
      lastErr = err;
      if (err?.code !== "TOO_MANY_REQUESTS" && err?.status !== 429) throw err;
      const wait = Math.min(15_000 * (i + 1), 60_000);
      console.log(`  (capacity 429, retry ${i + 1}/${attempts} in ${wait / 1000}s)`);
      await sleep(wait);
    }
  }
  throw lastErr;
}

export async function waitRunning(vm, { timeoutMs = 180_000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const d = await vm.data();
    if (d.state === "running") return d;
    if (d.state !== "starting" && d.state !== "paused" && d.state !== "pausing") {
      throw new Error(`VM entered unexpected state ${d.state}`);
    }
    if (Date.now() > deadline) throw new Error(`VM not running after ${timeoutMs}ms (state ${d.state})`);
    await sleep(2000);
  }
}

// Run an exec that must succeed; returns stdout trimmed.
// Freestyle exec starts with an EMPTY environment (not even HOME), so callers
// pass env explicitly for anything that needs it.
export async function sh(vm, command, { timeoutMs = 300_000, env } = {}) {
  const r = await vm.exec({ command, timeoutMs, env });
  if (r.statusCode !== 0) {
    throw new Error(`exec failed (${r.statusCode}): ${command}\n${r.stderr ?? ""}\n${r.stdout ?? ""}`);
  }
  return (r.stdout ?? "").trim();
}

export const CMUX_ENV = { HOME: "/root" };

// Bring up the headless cmux daemon (iroh) inside a VM, tolerating slow first
// boots and state dirs wedged by abrupt daemon kills.
//
// Failure shapes seen in the wild:
//  - first-ever boot needs >5s (identity mint + iroh relay dial)
//  - "could not verify previous remote daemon authorization finalization"
//  - "pane references missing surface N"
// Both wedge shapes are fixed only by resetting the daemon identity. Losing
// the identity is safe here: the provider re-enrolls automatically.
export async function ensureCmuxDaemon(vm, { session = "main", log = () => {} } = {}) {
  const up = async () => {
    const p = await vm.exec({ command: `cmux server status --session ${session} >/dev/null 2>&1; echo $?`, env: CMUX_ENV });
    return (p.stdout ?? "").trim() === "0";
  };
  const startOnce = async () => {
    // `server start` runs foreground: detach with setsid or the exec reaps it.
    await sh(vm, `setsid nohup cmux server start --session ${session} --iroh >/var/log/cmux-tui.log 2>&1 </dev/null &`, { env: CMUX_ENV });
    for (let i = 0; i < 45; i++) {
      await sleep(2000);
      if (await up()) return true;
      // Bail early when the daemon process died instead of polling the full window.
      // The bracket pattern keeps pgrep from matching the probing shell itself.
      if (i >= 2) {
        const proc = await vm.exec({ command: "pgrep -f '[s]erver start' >/dev/null 2>&1; echo $?", env: CMUX_ENV });
        if ((proc.stdout ?? "").trim() !== "0") return false;
      }
    }
    return false;
  };

  if (await up()) return;
  if (await startOnce()) return;
  const tail1 = ((await vm.exec({ command: "tail -5 /var/log/cmux-tui.log 2>/dev/null", env: CMUX_ENV })).stdout ?? "").trim();
  log(`daemon start failed (${tail1.split("\n").pop() ?? "no log"}); resetting identity`);
  await sh(vm, "rm -rf /root/.local/state/cmux /root/.local/state/cmux-tui /tmp/cmux-tui-0 /var/log/cmux-tui.log", { env: CMUX_ENV });
  if (await startOnce()) return;
  const tail2 = ((await vm.exec({ command: "tail -5 /var/log/cmux-tui.log 2>/dev/null", env: CMUX_ENV })).stdout ?? "").trim();
  throw new Error(`cmux daemon did not start after identity reset: ${tail2}`);
}
