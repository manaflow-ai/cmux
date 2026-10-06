/**
 * Development-only idle-pause end to end (plans/cmux-next/cloud-automation.md 29). Refuses every
 * origin except the dev API. Steps:
 *  1. Pre-check (read only): stop before any write if a machine this run did not create exists
 *     on the team (it could be idle-paused while the team policy is on).
 *  2. Create M1 (goes idle) and M2 (a person keeps using it); wait until both are bound.
 *  3. idle_seconds=60 on M1 and M2 only; 15 s dev heartbeat on both (a pause is decided when a
 *     report is applied).
 *  4. M2: a person's attached client sends input every 20 s. M1: one input, then nothing.
 *  5. Flip team policy cloud.idlePause=true; wait until M1 is paused; check M2 still runs.
 *  6. Always: restore the policy (rollback to the pre-test version, else clear the key) within
 *     10 minutes of the flip, confirm with team.policy.get, delete both machines by id.
 * Every API request and response is logged to <out-dir>/requests.jsonl (no tokens).
 *
 * Usage (from web/): bun scripts/cmux-vm-image/dev-idle-e2e.ts --out-dir <dir>
 */
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Freestyle } from "freestyle";
import { API_ORIGINS } from "../../../images/cmux-vm/guest/vm-agent";
import { assertDevOrigin, readEnvFile } from "./dev-e2e";
import { argValue, freestyleApiKey, run, type Vm } from "./guest";

const ORIGIN = API_ORIGINS.dev;
const STACK = "https://api.stack-auth.com";
const DEV_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895";
const IDLE_SECONDS = 60;
const HARD_LIMIT_MS = 10 * 60_000;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The guest side of "a person": attach a tui client to the first terminal, send input, detach. */
export const PERSON_PY = String.raw`
import json, socket, sys, threading, time
sock_path = open("/etc/cmux/daemon-socket").read().strip()
s = socket.socket(socket.AF_UNIX); s.connect(sock_path)
f = s.makefile("rwb"); lock = threading.Lock(); replies = {}; cond = threading.Condition(lock)
def reader():
    for line in f:
        msg = json.loads(line)
        if "id" in msg:
            with cond: replies[msg["id"]] = msg; cond.notify_all()
threading.Thread(target=reader, daemon=True).start()
n = [0]
def rpc(obj):
    n[0] += 1; obj["id"] = n[0]
    f.write((json.dumps(obj) + "\n").encode()); f.flush()
    with cond:
        cond.wait_for(lambda: obj["id"] in replies, timeout=10)
        return replies.get(obj["id"])
tree = rpc({"cmd": "list-workspaces"})["data"]
surface = next(t["surface"] for w in tree["workspaces"] for sc in w["screens"] for p in sc["panes"] for t in p["tabs"] if t["kind"] == "pty")
rpc({"cmd": "set-client-info", "name": "e2e-person", "kind": "tui"})
rpc({"cmd": "attach-surface", "surface": surface})
mode = sys.argv[1]
count = 1 if mode == "once" else int(sys.argv[3]) // int(sys.argv[2])
for i in range(count):
    r = rpc({"cmd": "send", "surface": surface, "text": "true\r"})
    print(json.dumps({"sent_at_ms": int(time.time() * 1000), "ok": bool(r and r.get("ok"))}), flush=True)
    if mode != "once": time.sleep(int(sys.argv[2]))
s.close()
`;

class Log {
  constructor(private readonly file: string) {}
  write(entry: Record<string, unknown>): void {
    appendFileSync(this.file, `${JSON.stringify({ at: new Date().toISOString(), ...entry })}\n`);
  }
}

class Api {
  constructor(private readonly token: string, private readonly log: Log) {}
  private async post(p: string, body: Record<string, unknown>): Promise<{ status: number; body: any }> {
    const res = await fetch(`${ORIGIN}${p}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${this.token}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(30_000) });
    const parsed = (await res.json().catch(() => ({}))) as any;
    this.log.write({ request: { path: p, ...body }, status: res.status, response: JSON.stringify(parsed).slice(0, 2000) });
    return { status: res.status, body: parsed };
  }
  async op(op: string, params: unknown, key?: string): Promise<any> {
    const r = await this.post("/v1/ops", { op, params, ...(key ? { idempotency_key: key } : {}) });
    if (r.status !== 200 || r.body.ok !== true) throw new Error(`${op}: HTTP ${r.status} ${JSON.stringify(r.body.error ?? r.body).slice(0, 300)}`);
    return r.body.value;
  }
  async read(op: string, params: unknown): Promise<any> {
    const r = await this.post("/v1/read", { op, params });
    if (r.status !== 200) throw new Error(`${op}: HTTP ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`);
    return r.body.value;
  }
}

async function signin(credentials: Record<string, string>): Promise<string> {
  const res = await fetch(`${STACK}/api/v1/auth/password/sign-in`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-stack-access-type": "client", "x-stack-project-id": DEV_STACK_PROJECT, "x-stack-publishable-client-key": credentials.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ?? "" },
    body: JSON.stringify({ email: credentials.CMUX_DOGFOOD_STACK_EMAIL, password: credentials.CMUX_DOGFOOD_STACK_PASSWORD }),
  });
  const body = (await res.json()) as { access_token?: string };
  if (!body.access_token) throw new Error(`Stack sign-in HTTP ${res.status}`);
  return body.access_token;
}

async function listMachines(api: Api): Promise<any[]> {
  const all: any[] = [];
  let cursor: string | undefined;
  do {
    const v = await api.read("cloud.machine.list", { limit: 100, ...(cursor ? { cursor } : {}) });
    all.push(...v.machines);
    cursor = v.next_cursor ?? undefined;
  } while (cursor);
  return all;
}

async function waitStatus(api: Api, machine: string, want: (m: any) => boolean, budgetMs: number): Promise<any> {
  const t0 = Date.now();
  let last: any = null;
  while (Date.now() - t0 < budgetMs) {
    last = await api.read("cloud.machine.get", { machine });
    if (want(last)) return last;
    await sleep(2_000);
  }
  throw new Error(`timed out; last status ${last?.status}`);
}

const providerName = (machine: string) => `cmuxnp-dev-cld-${machine.replace("_", "-")}`;
async function vmFor(fs: Freestyle, machine: string): Promise<Vm> {
  const data = await fs.vms.get(providerName(machine));
  return fs.vms.ref(data.id) as unknown as Vm;
}

const HEARTBEAT_15S = "mkdir -p /etc/systemd/system/cmux-vm-agent.service.d && printf '[Service]\\nEnvironment=CMUX_VM_AGENT_HEARTBEAT_MS=15000\\n' > /etc/systemd/system/cmux-vm-agent.service.d/e2e.conf && systemctl daemon-reload && systemctl restart cmux-vm-agent.service && echo heartbeat-15s";
const putPerson = `printf '%s' '${Buffer.from(PERSON_PY).toString("base64")}' | base64 -d > /root/person.py`;

export async function main(argv = process.argv): Promise<number> {
  assertDevOrigin(ORIGIN);
  const outDir = path.resolve(argValue("--out-dir", argv) ?? `cmux-dev-idle-e2e-${Date.now()}`);
  mkdirSync(outDir, { recursive: true });
  const log = new Log(path.join(outDir, "requests.jsonl"));
  const result: Record<string, unknown> = { origin: ORIGIN };
  const save = () => writeFileSync(path.join(outDir, "result.json"), `${JSON.stringify(result, null, 2)}\n`);
  const api = new Api(await signin(readEnvFile(readFileSync(path.join(os.homedir(), ".secrets/cmuxterm-dev.env"), "utf8"))), log);
  const fs = new Freestyle({ apiKey: freestyleApiKey({ FREESTYLE_API_KEY_FILE: path.join(os.homedir(), ".secrets/freestyle-cmux-next-dev-20261004.key") }) });
  const tag = `idle-${Date.now().toString(36)}`;
  const created: string[] = [];
  let flippedAt = 0;
  let restoreFrom: number | null = null;
  try {
    await api.op("user.ensure", {}, `${tag}-ensure`);
    const before = await listMachines(api);
    result.precheck = before.map((m) => ({ id: m.id, status: m.status, idle_seconds: m.idle_policy?.idle_seconds }));
    save();
    if (before.length > 0) {
      result.stopped = "the team has machines this run did not create; no policy flip";
      save();
      return 3;
    }
    for (const name of ["m1-idle", "m2-person"]) {
      const v = await api.op("cloud.machine.create", { name: `cmuxnp ${tag} ${name}`, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `${tag}-${name}`);
      created.push(v.machine.id);
      appendFileSync(path.join(outDir, "machines.tsv"), `${v.machine.id}\t${name}\tcreated\t${new Date().toISOString()}\n`);
    }
    const [m1, m2] = created;
    for (const m of created) await waitStatus(api, m, (x) => x.status === "running" && Boolean(x.host), 180_000);
    for (const m of created) await api.op("cloud.machine.idle_policy.set", { machine: m, idle_seconds: IDLE_SECONDS }, `${tag}-idle-${m}`);
    const vm1 = await vmFor(fs, m1);
    const vm2 = await vmFor(fs, m2);
    for (const vm of [vm1, vm2]) {
      const r = await run(vm, `${HEARTBEAT_15S} && ${putPerson} && echo person-ready`);
      if (!r.stdout.includes("person-ready")) throw new Error(`guest setup failed: ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
    }
    await run(vm2, "setsid nohup python3 /root/person.py keep 20 420 >/root/person.log 2>&1 < /dev/null & echo started");
    const once = await run(vm1, "python3 /root/person.py once");
    const sent = JSON.parse(once.stdout.trim().split("\n").at(-1) ?? "{}") as { sent_at_ms?: number; ok?: boolean };
    if (!sent.ok || !sent.sent_at_ms) throw new Error(`M1 input failed: ${once.stdout.slice(-200)} ${once.stderr.slice(-200)}`);
    result.m1_last_input_ms = sent.sent_at_ms;
    restoreFrom = (await api.read("team.policy.get", {})).policy.version as number;
    result.policy_before = restoreFrom;
    await api.op("team.policy.update", { changes: [{ key: "cloud.idlePause", value: { value: true, mode: "default" } }], expected_version: restoreFrom, reason: "cmux-next cloud-automation idle-pause e2e (restored within 10 minutes)" }, `${tag}-policy-on`);
    flippedAt = Date.now();
    result.policy_flipped_at = new Date(flippedAt).toISOString();
    save();
    const paused = await waitStatus(api, m1, (x) => x.status === "paused" || x.status === "pausing", Math.min(6 * 60_000, HARD_LIMIT_MS - 90_000));
    const pausedAt = Date.now();
    result.m1 = { status: paused.status, pause_reason: paused.pause_reason, paused_after_last_input_s: (pausedAt - sent.sent_at_ms) / 1000, paused_after_flip_s: (pausedAt - flippedAt) / 1000 };
    await sleep(Math.min(60_000, Math.max(0, flippedAt + HARD_LIMIT_MS - 120_000 - Date.now())));
    const m2now = await api.read("cloud.machine.get", { machine: m2 });
    result.m2 = { status: m2now.status, pause_reason: m2now.pause_reason ?? null, checked_after_flip_s: (Date.now() - flippedAt) / 1000 };
    save();
    return paused && m2now.status === "running" ? 0 : 1;
  } catch (error) {
    result.error = String((error as Error).message ?? error);
    return 1;
  } finally {
    if (flippedAt && restoreFrom !== null) {
      const current = (await api.read("team.policy.get", {}).catch(() => null))?.policy?.version as number | undefined;
      try {
        result.restore = await api.op("team.policy.rollback", { version: restoreFrom, expected_version: current ?? restoreFrom + 1, reason: "restore after cmux-next idle-pause e2e" }, `${tag}-policy-restore`);
      } catch (error) {
        result.restore_rollback_error = String((error as Error).message);
        result.restore = await api.op("team.policy.update", { changes: [{ key: "cloud.idlePause", value: null }], expected_version: current ?? restoreFrom + 1, reason: "restore after cmux-next idle-pause e2e (clear key)" }, `${tag}-policy-clear`).catch((e) => `clear failed: ${String(e)}`);
      }
      result.restored_after_flip_s = (Date.now() - flippedAt) / 1000;
      result.policy_after = (await api.read("team.policy.get", {}).catch((e) => ({ error: String(e) }))).policy ?? null;
    }
    for (const m of created) {
      await api.op("cloud.machine.delete", { machine: m }, `${tag}-delete-${m}`).then(
        () => appendFileSync(path.join(outDir, "machines.tsv"), `${m}\t-\tdeleted\t${new Date().toISOString()}\n`),
        (e) => appendFileSync(path.join(outDir, "machines.tsv"), `${m}\t-\tdelete-failed ${String(e).slice(0, 80)}\t${new Date().toISOString()}\n`),
      );
    }
    save();
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
