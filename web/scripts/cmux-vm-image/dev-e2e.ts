/**
 * Development-only end to end of a cmux-next Cloud machine through the development API
 * (plans/cmux-next/cloud-automation.md 24). Refuses every origin except the dev API.
 *
 * Usage (from web/): bun scripts/cmux-vm-image/dev-e2e.ts --out-dir <dir>
 *   [--credentials ~/.secrets/cmuxterm-dev.env] [--freestyle-key-file <path>] [--keep]
 *
 * Steps, each timed and recorded in <out-dir>/e2e.json:
 *   signin (Stack password, dogfood account) -> user.ensure -> install.register (an ES256 key
 *   made here, kind cli) -> install token (challenge + token) -> cloud.machine.create ->
 *   bound (status running and host set) -> VM evidence (agent journal, bound.json keys,
 *   per-clone machine-id) -> first report applied -> change report -> heartbeat on a 15 s dev
 *   override -> connect_info -> link_token -> pause -> start -> report after start (resume) ->
 *   delete. Report steps need an agent that logs report results (auto5 or later).
 * The machine this run created is recorded in <out-dir>/machines.tsv and deleted at the end by
 * its exact id (also on failure) unless --keep. Nothing else is deleted. Secrets are read from
 * files and never printed.
 */
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { API_ORIGINS, HOST_JOURNAL, HOST_UNIT, signMessage } from "./host-agent";
import { argValue, freestyleApiKey, run, type Vm } from "./guest";
import { Freestyle } from "freestyle";

const ORIGIN = API_ORIGINS.dev;
const STACK_API = "https://api.stack-auth.com";
/** The development Stack project (backend/apps/api/wrangler.jsonc, ENVIRONMENT=development). */
const DEV_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895";
const DEV_TEAM = "team_f77575bdfd932388f2e3";
/** The backend's provider name for a machine (cloud-driver.ts: prefix + vm id with _ as -). */
const providerName = (machine: string) => `cmuxnp-dev-cld-${machine.replace("_", "-")}`;

type Step = { step: string; ok: boolean; ms: number; detail: string };

export function assertDevOrigin(origin: string): void {
  if (origin !== API_ORIGINS.dev) throw new Error(`dev-e2e refuses ${origin}: development only (${API_ORIGINS.dev})`);
}

/** KEY=value lines; values never leave this process. */
export function readEnvFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
    if (!m) continue;
    out[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, "$2");
  }
  return out;
}

class Runner {
  readonly steps: Step[] = [];
  constructor(private readonly outDir: string) {}
  async step<T>(name: string, fn: () => Promise<{ value: T; detail: string }>): Promise<T> {
    const t0 = Date.now();
    try {
      const { value, detail } = await fn();
      this.record({ step: name, ok: true, ms: Date.now() - t0, detail });
      return value;
    } catch (error) {
      this.record({ step: name, ok: false, ms: Date.now() - t0, detail: String((error as Error).message ?? error).slice(0, 400) });
      throw error;
    }
  }
  record(s: Step): void {
    this.steps.push(s);
    console.log(`${s.ok ? "PASS" : "FAIL"} ${s.step} ${s.ms} ms :: ${s.detail}`);
    writeFileSync(path.join(this.outDir, "e2e.json"), `${JSON.stringify({ origin: ORIGIN, steps: this.steps }, null, 2)}\n`);
  }
}

async function post(url: string, body: unknown, headers: Record<string, string> = {}): Promise<{ status: number; body: any }> {
  const origin = new URL(url).origin;
  if (origin !== STACK_API) assertDevOrigin(origin);
  const res = await fetch(url, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body), signal: AbortSignal.timeout(30_000) });
  const text = await res.text();
  let parsed: any = {};
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = { raw: text.slice(0, 200) };
  }
  return { status: res.status, body: parsed };
}

class Api {
  constructor(private bearer: string) {}
  use(bearer: string) {
    this.bearer = bearer;
  }
  async op(op: string, params: unknown, key?: string): Promise<any> {
    const r = await post(`${ORIGIN}/v1/ops`, { op, params, ...(key ? { idempotency_key: key } : {}) }, { authorization: `Bearer ${this.bearer}` });
    if (r.status !== 200 || r.body.ok !== true) throw new Error(`${op}: HTTP ${r.status} ${JSON.stringify(r.body.error ?? r.body).slice(0, 300)}`);
    return r.body.value;
  }
  async read(op: string, params: unknown): Promise<any> {
    const r = await post(`${ORIGIN}/v1/read`, { op, params }, { authorization: `Bearer ${this.bearer}` });
    if (r.status !== 200) throw new Error(`${op}: HTTP ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`);
    return r.body.value;
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Test-side wait (bounded) for a machine field; the product itself never polls. */
async function waitMachine(api: Api, machine: string, want: (m: any) => boolean, budgetMs: number): Promise<any> {
  const t0 = Date.now();
  let last: any = null;
  while (Date.now() - t0 < budgetMs) {
    last = await api.read("cloud.machine.get", { machine });
    if (want(last)) return last;
    await sleep(500);
  }
  throw new Error(`timed out after ${budgetMs} ms; last status ${last?.status} host ${last?.host}`);
}

export type DevChannel = { snapshot: string; snapshot_id: string };

/** images/cmux-vm/channels/dev.json: the image the development Worker is meant to boot. */
export function readDevChannel(file = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../images/cmux-vm/channels/dev.json")): DevChannel {
  const raw = JSON.parse(readFileSync(file, "utf8")) as Partial<DevChannel>;
  if (typeof raw.snapshot !== "string" || typeof raw.snapshot_id !== "string") throw new Error(`${file}: needs snapshot and snapshot_id`);
  return { snapshot: raw.snapshot, snapshot_id: raw.snapshot_id };
}

/** null when the provider VM record says it booted the channel's snapshot; else the mismatch. */
export function bootedSnapshotProblem(vm: { snapshotId?: string | null; sourceSnapshotSlugAtCreate?: string | null }, channel: DevChannel): string | null {
  if (!vm.snapshotId) return "the provider VM record has no snapshotId";
  if (vm.snapshotId !== channel.snapshot_id) return `booted ${vm.snapshotId} (${vm.sourceSnapshotSlugAtCreate ?? "no slug"}), channels/dev.json names ${channel.snapshot_id} (${channel.snapshot})`;
  if (vm.sourceSnapshotSlugAtCreate && vm.sourceSnapshotSlugAtCreate !== channel.snapshot) return `snapshot id matches, but its slug at create ${vm.sourceSnapshotSlugAtCreate} differs from ${channel.snapshot}`;
  return null;
}

/** The backend names the provider VM by slug, so the slug addresses it directly (read and exec only). */
async function vmFor(fs: Freestyle, machine: string): Promise<Vm> {
  const name = providerName(machine);
  const data = await fs.vms.get(name);
  if (data.slug !== name) throw new Error(`provider VM ${name} not found`);
  return fs.vms.ref(data.id) as unknown as Vm;
}

const AGENT_LOG = HOST_JOURNAL;

export async function main(argv = process.argv): Promise<number> {
  assertDevOrigin(ORIGIN);
  const outDir = path.resolve(argValue("--out-dir", argv) ?? `cmux-dev-e2e-${Date.now()}`);
  mkdirSync(outDir, { recursive: true });
  const creds = readEnvFile(readFileSync(argValue("--credentials", argv) ?? path.join(os.homedir(), ".secrets/cmuxterm-dev.env"), "utf8"));
  const keyFile = argValue("--freestyle-key-file", argv) ?? path.join(os.homedir(), ".secrets/freestyle-cmux-next-dev-20261004.key");
  const fs = new Freestyle({ apiKey: freestyleApiKey({ FREESTYLE_API_KEY_FILE: keyFile }) });
  const R = new Runner(outDir);
  const api = new Api("");
  let machine: string | null = null;
  const tag = `e2e-${Date.now().toString(36)}`;
  try {
    const session = await R.step("signin", async () => {
      const r = await post(`${STACK_API}/api/v1/auth/password/sign-in`, { email: creds.CMUX_DOGFOOD_STACK_EMAIL, password: creds.CMUX_DOGFOOD_STACK_PASSWORD }, {
        "x-stack-access-type": "client",
        "x-stack-project-id": DEV_STACK_PROJECT,
        ...(creds.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ? { "x-stack-publishable-client-key": creds.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY } : {}),
      });
      if (r.status !== 200 || typeof r.body.access_token !== "string") throw new Error(`Stack sign-in HTTP ${r.status} ${String(r.body.code ?? "")}`);
      return { value: r.body.access_token as string, detail: "Stack session" };
    });
    api.use(session);
    const user = await R.step("user.ensure", async () => {
      const v = await api.op("user.ensure", {}, `${tag}-ensure`);
      return { value: v, detail: `user ${v.id ?? v.user?.id ?? "?"}` };
    });
    const created = await R.step("cloud.machine.create", async () => {
      const v = await api.op("cloud.machine.create", { name: `cmuxnp e2e ${tag}`, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `${tag}-create`);
      machine = v.machine.id as string;
      appendFileSync(path.join(outDir, "machines.tsv"), `${machine}\t${tag}\tcreated\t${new Date().toISOString()}\n`);
      return { value: v.machine, detail: `${machine} status ${v.machine.status}` };
    });
    const bound = await R.step("bound (running, host set)", async () => {
      const m = await waitMachine(api, created.id, (x) => x.status === "running" && Boolean(x.host), 180_000);
      return { value: m, detail: `host ${m.host}, daemon ${m.image?.daemon_version}` };
    });
    const vm = await R.step("provider VM", async () => ({ value: await vmFor(fs, created.id), detail: providerName(created.id) }));
    await R.step("booted the dev channel's snapshot", async () => {
      const channel = readDevChannel();
      const data = (await fs.vms.get(providerName(created.id))) as { snapshotId?: string | null; sourceSnapshotSlugAtCreate?: string | null };
      const problem = bootedSnapshotProblem(data, channel);
      if (problem) throw new Error(problem);
      return { value: null, detail: `${data.snapshotId} (${data.sourceSnapshotSlugAtCreate ?? channel.snapshot}) = channels/dev.json` };
    });
    await R.step("VM agent evidence (bind, keys, machine-id)", async () => {
      const r = await run(vm, `${AGENT_LOG} | grep -E 'bind:|machine-id|heartbeat' | head -5; jq -r 'keys|join(",")' /var/lib/cmux/bound.json; stat -c %a /var/lib/cmux/bound.json /var/lib/cmux/install/key.json; ${AGENT_LOG} | grep -q 'new machine-id=' && echo machine-id-per-clone`);
      if (r.code !== 0 || !/bind: bound/.test(r.stdout)) throw new Error(r.stdout.trim().slice(-300) || r.stderr.slice(-300));
      return { value: null, detail: r.stdout.trim().split("\n").join(" | ") };
    });
    const hasReportLog = true /* the Rust cloud role logs every report result */;
    /** Test-side wait for an agent log line, optionally only lines logged at or after `sinceUnix`. */
    const journalWait = async (pattern: string, budgetMs: number, sinceUnix?: number): Promise<string> => {
      const t0 = Date.now();
      const since = sinceUnix ? ` --since=@${sinceUnix}` : "";
      while (Date.now() - t0 < budgetMs) {
        const r = await run(vm, `${AGENT_LOG}${since} | grep -E ${JSON.stringify(pattern)} | tail -1`);
        if (r.stdout.trim()) return r.stdout.trim();
        await sleep(1000);
      }
      throw new Error(`no agent log line /${pattern}/ within ${budgetMs} ms`);
    };
    if (hasReportLog) {
      await R.step("first status.report applied", async () => ({ value: null, detail: await journalWait("report (start|bind) applied", 30_000) }));
      await R.step("change report (activity line on the agent socket)", async () => {
        const sentAt = Math.floor(Date.now() / 1000);
        const line = JSON.stringify({ activity: { active_sessions: 1, last_user_input_at: Date.now() } });
        const sent = await run(vm, `ls -l /run/cmux-vm-agent/; python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect("/run/cmux-vm-agent/agent.sock"); s.sendall(sys.argv[1].encode()+b"\\n"); s.close(); print("sent")' '${line}'`);
        if (!sent.stdout.includes("sent")) throw new Error(`socket send failed: ${sent.stdout.trim().slice(-200)} ${sent.stderr.slice(-300)}`);
        try {
          // auto5 names only the latest reason (a resume can relabel the change report); later agents log
          // every reason (change+resume). Either way the next report carries the latest activity.
          return { value: null, detail: await journalWait("report [a-z+]*(change|resume)[a-z+]* (applied|held)", 30_000, sentAt) };
        } catch (error) {
          const tail = await run(vm, `${AGENT_LOG} | tail -6`);
          // The whole agent journal (no secret is logged) for the diagnosis; the VM is deleted after.
          const full = await run(vm, `journalctl -m -u ${HOST_UNIT} --no-pager -o short-precise | grep -v -E 'sudo|pam_unix'`);
          writeFileSync(path.join(outDir, "agent-journal.txt"), full.stdout);
          throw new Error(`${(error as Error).message}; agent log: ${tail.stdout.trim().split("\n").join(" | ")}`);
        }
      });
      await R.step("heartbeat on a 15 s test interval (dev override)", async () => {
        await run(vm, "mkdir -p /etc/systemd/system/cmux-host.service.d && printf '[Service]\\nEnvironment=CMUX_VM_AGENT_HEARTBEAT_MS=15000\\n' > /etc/systemd/system/cmux-host.service.d/e2e.conf && systemctl daemon-reload && systemctl restart cmux-host.service");
        const restartedAt = Math.floor(Date.now() / 1000);
        // Every provider exec steps the guest clock, which fires the resume timer and re-arms the
        // heartbeat (cloud-automation.md 26). So: no exec for 40 s (the restart exec itself causes one resume report about 10 s later), then one read.
        await sleep(40_000);
        const r = await run(vm, `${AGENT_LOG} --since=@${restartedAt} | grep -E 'heartbeat test override|report ' | tail -6`);
        if (!/heartbeat test override: 15000/.test(r.stdout) || !/report [a-z+]*heartbeat[a-z+]* (applied|held)/.test(r.stdout)) throw new Error(`no heartbeat report: ${r.stdout.trim().split("\n").join(" | ")}`);
        return { value: null, detail: r.stdout.trim().split("\n").join(" | ") };
      });
    } else {
      R.record({ step: "report steps (first, change, heartbeat)", ok: false, ms: 0, detail: "SKIPPED: this snapshot's agent does not log report results (needs auto5 or later)" });
    }
    const install = await R.step("install.register + token", async () => {
      const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
      const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
      const inst = await api.op("install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: `cmuxnp e2e ${tag}`, device_name: "cmuxnp e2e", platform: "macos" }, `${tag}-install`);
      const userId = inst.user ?? user.id;
      const ch = await post(`${ORIGIN}/v1/auth/challenge`, { user: userId, install: inst.id });
      if (ch.status !== 200) throw new Error(`challenge HTTP ${ch.status} ${JSON.stringify(ch.body).slice(0, 200)}`);
      const signature = await signMessage(pair.privateKey, `${ch.body.message_prefix}${ch.body.nonce}`);
      const tok = await post(`${ORIGIN}/v1/auth/token`, { user: userId, install: inst.id, nonce: ch.body.nonce, signature });
      if (tok.status !== 200) throw new Error(`token HTTP ${tok.status} ${JSON.stringify(tok.body).slice(0, 200)}`);
      return { value: { id: inst.id as string, token: tok.body.access_token as string }, detail: `${inst.id} token minted (grant ${tok.body.grant})` };
    });
    const installApi = new Api(install.token);
    await R.step("connect_info", async () => {
      const v = await installApi.read("cloud.machine.connect_info", { machine: created.id });
      return { value: v, detail: `host ${v.host} epoch ${v.epoch} state ${v.state} services ${v.services} daemon ${JSON.stringify(v.daemon)}` };
    });
    await R.step("activity capability reported (agent subscribed to vm-activity-v1)", async () => {
      // The bind carries no `activity`; the first report after the watcher connects does, and the
      // daemon change reaches connect_info. Test-side wait, bounded.
      const t0 = Date.now();
      let caps: string[] = [];
      while (Date.now() - t0 < 30_000) {
        caps = ((await installApi.read("cloud.machine.connect_info", { machine: created.id })).daemon?.capabilities ?? []) as string[];
        if (caps.includes("activity")) return { value: null, detail: `daemon capabilities ${JSON.stringify(caps)}` };
        await sleep(2_000);
      }
      throw new Error(`no activity capability after 30 s: ${JSON.stringify(caps)}`);
    });
    await R.step("link_token", async () => {
      const v = await installApi.op("cloud.machine.link_token", { host: bound.host, services: ["daemon"] });
      return { value: v, detail: `expires_at ${v.expires_at} epoch ${v.epoch} services ${v.services}` };
    });
    await R.step("pause", async () => {
      await api.op("cloud.machine.pause", { machine: created.id }, `${tag}-pause`);
      const m = await waitMachine(api, created.id, (x) => x.status === "paused", 120_000);
      return { value: m, detail: `status ${m.status}` };
    });
    const startedAt = Math.floor(Date.now() / 1000);
    await R.step("start", async () => {
      await api.op("cloud.machine.start", { machine: created.id }, `${tag}-start`);
      const m = await waitMachine(api, created.id, (x) => x.status === "running", 120_000);
      return { value: m, detail: `status ${m.status}` };
    });
    if (hasReportLog) {
      await R.step("report after start (resume, OnClockChange)", async () => {
        // No exec for 15 s: a resume report logged before our first read came from the provider's
        // resume clock step, not from an exec (every exec also steps the clock).
        await sleep(15_000);
        const readAt = Date.now() / 1000;
        const r = await run(vm, `${AGENT_LOG.replace("-o cat", "-o short-unix")} --since=@${startedAt} | grep -E 'report [a-z+]*resume[a-z+]* (applied|held)' | head -1`);
        const ts = Number(r.stdout.trim().split(/\s+/)[0]);
        if (!(ts > 0) || ts >= readAt) throw new Error(`no resume report before the first read: ${r.stdout.trim().slice(0, 200)}`);
        return { value: null, detail: `${r.stdout.trim()} (logged ${(ts - startedAt).toFixed(1)} s after start, before any exec)` };
      });
    }
    await R.step("VM after start (agent alive)", async () => {
      const r = await run(vm, `systemctl is-active ${HOST_UNIT}; ${AGENT_LOG} | tail -3`);
      if (!/^active/.test(r.stdout)) throw new Error(r.stdout.trim().slice(-300));
      return { value: null, detail: r.stdout.trim().split("\n").join(" | ") };
    });
    return R.steps.every((s) => s.ok) ? 0 : 1;
  } catch {
    return 1;
  } finally {
    if (machine && !argv.includes("--keep")) {
      const id: string = machine;
      await R.step("delete (this run's machine, by id)", async () => {
        await api.op("cloud.machine.delete", { machine: id }, `${tag}-delete`);
        appendFileSync(path.join(outDir, "machines.tsv"), `${id}\t${tag}\tdeleted\t${new Date().toISOString()}\n`);
        return { value: null, detail: id };
      }).catch(() => undefined);
    }
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
