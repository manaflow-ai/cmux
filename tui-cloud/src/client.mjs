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
