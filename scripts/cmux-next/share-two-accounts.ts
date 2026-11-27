// One manual staging run. The browser and the native owner driver take their timestamps
// with this Bun process's monotonic clock. Remote journal timestamps never enter a sample.
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { http, passwordSignIn, STACK, STACK_API } from "./cloud-journey.ts";

const REQUIRED = 20;
type Owner = {
  prompt(text: string): Promise<number>;
  waitGuest(text: string): Promise<number>;
  revoke(): Promise<number>;
};
type Guest = {
  waitUpdate(text: string): Promise<number>;
  send(text: string): Promise<number>;
  waitCutoff(): Promise<number>;
};
type Event = { at_ms: number; side: "owner" | "guest" | "job"; action: string; sample?: number };
export function measurements() {
  return { updates: [] as number[], delivered: null as number | null, cutoff: null as number | null, events: [] as Event[] };
}
type Measurements = ReturnType<typeof measurements>;
function event(m: Measurements, side: Event["side"], action: string, at_ms = performance.now(), sample?: number) {
  m.events.push({ at_ms, side, action, sample });
}
function elapsed(start: number, end: number) {
  if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) throw new Error("Invalid observation interval");
  return end - start;
}

export async function measure(owner: Owner, guest: Guest, m: Measurements, stage: (s: string) => void) {
  const run = randomUUID().slice(0, 8);
  for (let i = 1; i <= REQUIRED; i++) {
    stage(`owner update ${i} of ${REQUIRED}`);
    const marker = `Sharing check ${run} / ${String(i).padStart(2, "0")}.`;
    const [seen, sent] = await Promise.all([guest.waitUpdate(marker), owner.prompt(marker)]);
    m.updates.push(elapsed(sent, seen));
    event(m, "owner", "sent update", sent, i);
    event(m, "guest", "rendered update", seen, i);
  }
  stage("guest Talk message reaching the owner chat");
  const message = `Guest reply ${run}.`;
  const [received, typed] = await Promise.all([owner.waitGuest(message), guest.send(message)]);
  m.delivered = elapsed(typed, received);
  event(m, "guest", "sent Talk message", typed);
  event(m, "owner", "received Talk message", received);
  stage("guest cutoff after owner revoke");
  const [ended, revoked] = await Promise.all([guest.waitCutoff(), owner.revoke()]);
  m.cutoff = elapsed(revoked, ended);
  event(m, "owner", "revoked share", revoked);
  event(m, "guest", "rendered ended page", ended);
}

function latency(samples: number[]) {
  if (!samples.length) return { p50_ms: null, p95_ms: null, max_ms: null, within_1s: false };
  const result = spawnSync(process.env.SHARE_LATENCY_REPORT!, [], {
    input: samples.join("\n") + "\n", encoding: "utf8", timeout: 5000,
  });
  if (result.status !== 0) throw new Error("Shared latency reporter failed");
  return JSON.parse(result.stdout) as { p50_ms: number; p95_ms: number; max_ms: number; within_1s: boolean };
}

export function publish(out: string, m: Measurements, errors: string[]) {
  const update = latency(m.updates);
  const cutoff = m.cutoff !== null && latency([m.cutoff]).within_1s;
  const within = { update_p95: m.updates.length >= REQUIRED && update.within_1s, revoke: cutoff };
  const result = {
    status: errors.length || !within.update_p95 || !within.revoke || m.delivered === null ? "failed" : "passed",
    update_ms: { n: m.updates.length, p50: update.p50_ms, p95: update.p95_ms, max: update.max_ms, samples: m.updates },
    guest_typed_delivered: m.delivered !== null, guest_typed_delivered_ms: m.delivered,
    revoke_cutoff_ms: m.cutoff, within_1s: within, errors,
  };
  const json = JSON.stringify(result, null, 2);
  const summary = `## Two-account staging sharing\n\n\`\`\`json\n${json}\n\`\`\`\n`;
  writeFileSync(join(out, "share-two-accounts.json"), json + "\n");
  writeFileSync(join(out, "journey.json"), JSON.stringify(m.events.sort((a, b) => a.at_ms - b.at_ms), null, 2) + "\n");
  writeFileSync(join(out, "summary.md"), summary);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);
  return result;
}

export function options(args: string[]) {
  const cleanup = args[0] === "--cleanup";
  const rest = cleanup ? args.slice(1) : args;
  if (rest.length !== 2 || rest[0] !== "--out" || !rest[1] || rest[1].startsWith("--"))
    throw new Error("Usage: share-two-accounts.ts [--cleanup] --out DIR");
  return { cleanup, out: rest[1] };
}
export function pair(role: "OWNER" | "GUEST", env: NodeJS.ProcessEnv) {
  const email = env[`${role}_STACK_EMAIL`];
  const password = env[`${role}_STACK_PASSWORD`];
  if (!email || !password) throw new Error(`Missing staging ${role.toLowerCase()} Stack email or password`);
  return { email, password };
}

async function signIn(role: "owner" | "guest", account: ReturnType<typeof pair>) {
  const stack = STACK.dev;
  try {
    const { access } = await passwordSignIn(stack, account.email, account.password);
    const who = await http("GET", `${STACK_API}/api/v1/users/me`, undefined, {
      "x-stack-access-type": "client", "x-stack-project-id": stack.project,
      "x-stack-publishable-client-key": stack.clientKey, "x-stack-access-token": access,
    }, 15000);
    if (who.status !== 200 || !who.body?.id) throw new Error();
    return { access, id: who.body.id as string };
  } catch { throw new Error(`Staging ${role} account sign-in or identity check failed`); }
}

async function main() {
  const { out, cleanup } = options(process.argv.slice(2));
  const { GITHUB_RUN_ID: id, GITHUB_RUN_ATTEMPT: attempt, CMUX_BIN: cmux } = process.env;
  if (!id || !attempt || !/^\d+$/.test(id) || !/^\d+$/.test(attempt)) throw new Error("Missing Actions run ID or attempt");
  const tag = `share-${id}-${attempt}`;
  mkdirSync(out, { recursive: true });
  const pending = join(out, "owner-pending");
  const { openOwner, cleanupOwnerMachine } = await import("./share-two-accounts-owner.ts");
  if (cleanup) {
    if (existsSync(pending)) {
      const owner = await signIn("owner", pair("OWNER", process.env));
      await cleanupOwnerMachine(owner.access, tag);
      unlinkSync(pending);
    }
    return;
  }
  const { createGuest } = await import("./share-two-accounts-guest.ts");
  const m = measurements();
  const errors: string[] = [];
  let owner: Awaited<ReturnType<typeof openOwner>> | undefined;
  let guest: Awaited<ReturnType<typeof createGuest>> | undefined;
  let stage = "account preflight";
  const start = (name: string) => { stage = name; event(m, "job", name); };
  try {
    if (!cmux || !process.env.SHARE_LATENCY_REPORT) throw new Error("Missing owner CLI or latency reporter");
    const a = pair("OWNER", process.env);
    const b = pair("GUEST", process.env);
    for (const key of ["OWNER_STACK_EMAIL", "OWNER_STACK_PASSWORD", "GUEST_STACK_EMAIL", "GUEST_STACK_PASSWORD"]) {
      delete process.env[key];
    }
    start("sign in as owner and guest");
    const [ownerAuth, guestAuth] = await Promise.all([signIn("owner", a), signIn("guest", b)]);
    if (ownerAuth.id === guestAuth.id) throw new Error("Staging sign-ins returned the same account");
    start("open owner chat and create Talk link");
    writeFileSync(pending, tag, { mode: 0o600 });
    owner = await openOwner({ stackToken: ownerAuth.access, tag, cmux });
    start("guest joins by link");
    guest = await createGuest(out, guestAuth.access, owner.url);
    await measure(owner, guest, m, start);
  } catch (error) {
    errors.push(`${stage}: ${(error as Error).message}`);
  } finally {
    if (guest) {
      try { await guest.close(); } catch { errors.push("Guest recording or browser cleanup failed"); }
    }
    if (owner) {
      try { await owner.close(); unlinkSync(pending); }
      catch { errors.push("Owner cleanup failed; retry in the always cleanup step"); }
    }
  }
  const result = publish(out, m, errors);
  if (result.status === "failed") {
    throw new Error(errors.join("; ") || "Sharing exceeded the 1000 ms p95 update or revoke bound");
  }
}
if (import.meta.main) main().catch(error => { console.error(error.message); process.exitCode = 1; });
