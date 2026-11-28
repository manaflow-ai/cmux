#!/usr/bin/env bun
/**
 * The two staging VMs behind the stable tailnet node's real-VM move (stable-node-vm-move.sh,
 * .github/workflows/tailnet-stable-node-move.yml).
 *
 *   up    sign in as the staging agent test account, sweep this check's machines older than 3 h, create
 *         `cmux-test-<run>-tailnet-move-a` and `-b`, and on each: a static tailscaled in userspace mode (its own
 *         socket and state dir, never the image's tailscaled) joined to the run's throwaway headscale with that
 *         VM's own single-use ephemeral key (written 0600 through fs/write, deleted after `tailscale up`), and
 *         an echo on :7000 that answers "<A|B>:" + what it read (stable_node's `echo` mode). Writes
 *         {a:{machine,ip},b:{machine,ip}} to --json. With --key-b-cmd CMD, B's key is made late: CMD runs
 *         (bash -c) once B's exec answers and must write --key-b, so a short-lived key (cmux's mint-key: 10 min)
 *         starts its clock at the join, not before a staging boot that can take as long.
 *   down  on every machine this run made: `tailscale logout`, then delete the machine (found by name, so a
 *         separate `if: always()` step cleans up after a failed `up`).
 *
 * Usage:
 *   bun scripts/cmux-next/tailnet-move-vms.ts up --run ID --login-server URL --key-a FILE --key-b FILE [--key-b-cmd CMD] --json OUT
 *   bun scripts/cmux-next/tailnet-move-vms.ts down --run ID
 * Env: CMUX_DOGFOOD_STACK_EMAIL, CMUX_DOGFOOD_STACK_PASSWORD, PRODUCT_TEAM (optional).
 */
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { Api, CHAT_START_SIZE, directExec, listAllMachines, passwordSignIn, resolveBackend, STACK, waitMachine, type Exec } from "./cloud-journey";

const NAME_PREFIX = "cmux-test-";
const CHECK_MARK = "-tailnet-move";
const SWEEP_AFTER_MS = 3 * 60 * 60 * 1000;
const DIR = "/var/lib/cmux-tailnet-move";
const SOCK = "/run/cmux-tailnet-move.sock";
const KEY = "/var/tmp/cmux-tailnet-move.key";

const arg = (name: string): string | undefined => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
};
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
const asRoot = (cmd: string) => `if [ "$(id -u)" = 0 ]; then sh -c ${shq(cmd)}; else sudo -n sh -c ${shq(cmd)}; fi`;
const secrets: string[] = [];
const redact = (s: string) => secrets.reduce((acc, x) => (x ? acc.split(x).join("[redacted]") : acc), s).replace(/(tskey|hskey)-[A-Za-z0-9_-]+/g, "$1-[redacted]");
const say = (s: string) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${redact(s)}`);

async function must(exec: Exec, cmd: string, timeoutMs = 120_000): Promise<string> {
  const r = await exec(cmd, timeoutMs);
  if (r.code !== 0) throw new Error(`exit ${r.code}: ${redact((r.stderr || r.stdout).trim().slice(-800))}`);
  return r.stdout.trim();
}

async function signIn(run: string): Promise<Api> {
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD are required (never a skip)");
  secrets.push(password);
  const backend = resolveBackend(arg("--target") ?? "staging");
  const api = new Api(backend.api, process.env.PRODUCT_TEAM || undefined);
  const s = await passwordSignIn(STACK[backend.stack], email, password);
  secrets.push(s.access, s.refresh);
  api.bearer = s.access;
  await api.op("user.ensure", {}, `tailnet-move-${run}-ensure`);
  return api;
}

const machineName = (run: string, side: "a" | "b") => `${NAME_PREFIX}${run}${CHECK_MARK}-${side}`.slice(0, 64);
const live = (r: any) => r?.status !== "deleted" && r?.status !== "deleting";
const idOf = (r: any) => String(r?.id ?? r?.machine_id);

/**
 * cloud.machine.create under its idempotency key. The ops API can hold the create past op()'s 60 s fetch
 * (run 45591326173: "The operation timed out." with both creates in flight); the same key may be sent again,
 * and a machine that landed meanwhile is found by its name.
 */
async function createMachine(api: Api, name: string, key: string, label: string): Promise<string> {
  const t0 = Date.now();
  for (let attempt = 1; ; attempt++) {
    try {
      const created = await api.op("cloud.machine.create", { name, size: CHAT_START_SIZE }, key);
      return String(created?.machine?.id ?? created?.machine ?? created?.machine_id ?? created?.id);
    } catch (e) {
      const msg = redact(String((e as Error)?.message ?? e));
      const found = (await listAllMachines((p) => api.read("cloud.machine.list", p)).catch(() => [] as any[])).find((r) => r?.name === name && live(r));
      say(`${label}: create attempt ${attempt} after ${Math.round((Date.now() - t0) / 1000)} s: ${msg.slice(0, 200)}${found ? `; ${idOf(found)} exists (${found.status})` : ""}`);
      if (found) return idOf(found);
      if (attempt >= 6) throw new Error(`${name}: cloud.machine.create never answered in ${attempt} tries: ${msg.slice(0, 300)}`);
      await new Promise((res) => setTimeout(res, 5000));
    }
  }
}

const ECHO = `import socket, sys, threading
NAME = sys.argv[1].encode()
def serve(c):
    with c:
        while True:
            d = c.recv(4096)
            if not d:
                return
            c.sendall(NAME + b":" + d)
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 7000))
s.listen(128)
while True:
    c, _ = s.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
`;

async function backend(api: Api, run: string, side: "a" | "b", loginServer: string, key: () => string, tarball: string): Promise<{ machine: string; ip: string }> {
  const name = machineName(run, side);
  const label = side.toUpperCase();
  const t0 = Date.now();
  const machine = await createMachine(api, name, `tailnet-move-${run}-${side}`, label);
  await waitMachine(api, machine, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
  const exec = directExec(api, machine, { secrets });
  for (let i = 0; ; i++) {
    const r = await exec("true", 30_000).catch((e) => ({ code: -1, stdout: "", stderr: String((e as Error).message) }));
    if (r.code === 0) break;
    if (i >= 40) throw new Error(`${name}: exec never answered: ${r.stderr.slice(0, 300)}`);
    await new Promise((res) => setTimeout(res, 3000));
  }
  say(`${label}: ${name} ${machine} running, exec answers (${Math.round((Date.now() - t0) / 1000)} s)`);
  const facts = await must(exec, "uname -m; command -v python3 || echo no-python3; command -v curl || echo no-curl; id -un");
  say(`${label}: ${facts.replace(/\n/g, " | ")}`);
  const arch = facts.startsWith("aarch64") ? "arm64" : "amd64";
  const url = tarball.replace(/_amd64\.tgz$/, `_${arch}.tgz`);
  await must(exec, asRoot(`set -e; rm -rf ${DIR}; mkdir -p ${DIR}/bin ${DIR}/state; chmod 700 ${DIR}
    curl -fsSL --retry 5 ${shq(url)} | tar -xz -C ${DIR}/bin --strip-components=1
    printf %s ${shq(ECHO)} > ${DIR}/echo.py
    (setsid nohup ${DIR}/bin/tailscaled --tun=userspace-networking --statedir=${DIR}/state --socket=${SOCK} --port=0 >${DIR}/tailscaled.log 2>&1 </dev/null &)
    (setsid nohup python3 ${DIR}/echo.py ${label} >${DIR}/echo.log 2>&1 </dev/null &)
    for i in $(seq 1 50); do [ -S ${SOCK} ] && break; sleep 0.2; done; test -S ${SOCK}`), 180_000);
  // The key goes over the API's file write, never a command line, 0600, and is gone after `tailscale up`.
  const k = key();
  const w = await api.raw("POST", `/v1/cloud/machines/${machine}/fs/write`, { path: KEY, dataBase64: Buffer.from(k).toString("base64"), mode: 0o600 }, 60_000);
  if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`${name}: fs/write key: HTTP ${w.status} ${String(w.body?.error?.code ?? "")}`);
  const up = await exec(asRoot(`chmod 600 ${KEY}; ${DIR}/bin/tailscale --socket=${SOCK} up --login-server=${shq(loginServer)} --auth-key=file:${KEY} --hostname=backend-${side} --accept-dns=false --timeout=120s; rc=$?; rm -f ${KEY}; exit $rc`), 180_000);
  if (up.code !== 0) {
    const log = await exec(asRoot(`tail -30 ${DIR}/tailscaled.log`), 30_000).catch(() => ({ stdout: "" }));
    throw new Error(`${name}: tailscale up exit ${up.code}: ${redact((up.stderr || up.stdout).slice(-600))}\n${redact(String(log.stdout).slice(-1500))}`);
  }
  const ip = (await must(exec, asRoot(`${DIR}/bin/tailscale --socket=${SOCK} ip -4`))).split("\n")[0].trim();
  const local = await must(exec, `python3 -c 'import socket;s=socket.create_connection(("127.0.0.1",7000),5);s.sendall(b"hi");print(s.recv(64).decode())'`);
  if (local !== `${label}:hi`) throw new Error(`${name}: echo answered ${JSON.stringify(local)}`);
  say(`${label}: joined as backend-${side} ${ip}; echo answers ${local} (${Math.round((Date.now() - t0) / 1000)} s from create)`);
  return { machine, ip };
}

async function up(run: string): Promise<void> {
  const loginServer = arg("--login-server");
  const keyA = arg("--key-a");
  const keyB = arg("--key-b");
  const out = arg("--json");
  const tarball = arg("--tarball");
  if (!loginServer || !keyA || !keyB || !out || !tarball) throw new Error("up needs --login-server --key-a --key-b --json --tarball");
  const keyBCmd = arg("--key-b-cmd");
  const readKey = (file: string): string => {
    const k = readFileSync(file, "utf8").trim();
    if (!k) throw new Error(`${file} holds no key`);
    secrets.push(k);
    if (process.env.GITHUB_ACTIONS) console.log(`::add-mask::${k}`);
    return k;
  };
  const ka = readKey(keyA);
  const kb = keyBCmd ? undefined : readKey(keyB);
  const keyBNow = (): string => {
    if (kb !== undefined) return kb;
    const t = Date.now();
    const r = spawnSync("bash", ["-c", keyBCmd!], { stdio: ["ignore", "inherit", "inherit"], timeout: 60_000 });
    if (r.status !== 0) throw new Error(`--key-b-cmd exit ${r.status ?? r.signal}`);
    const k = readKey(keyB);
    say(`B: key made by --key-b-cmd once B answered (${Date.now() - t} ms)`);
    return k;
  };
  const api = await signIn(run);
  const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
  const old = rows.filter((r) => String(r?.name ?? "").startsWith(NAME_PREFIX) && String(r?.name ?? "").includes(CHECK_MARK) && live(r) && typeof r.created_at === "number" && Date.now() - r.created_at > SWEEP_AFTER_MS);
  for (const r of old) await api.deleteMachine(idOf(r), `tailnet-move-sweep-${idOf(r)}`).catch(() => undefined);
  say(`signed in; swept ${old.length} check machines older than 3 h`);
  const [a, b] = await Promise.all([backend(api, run, "a", loginServer, () => ka, tarball), backend(api, run, "b", loginServer, keyBNow, tarball)]);
  writeFileSync(out, JSON.stringify({ a, b }) + "\n");
}

async function down(run: string): Promise<void> {
  const api = await signIn(run);
  const rows = (await listAllMachines((p) => api.read("cloud.machine.list", p))).filter((r) => live(r) && (r?.name === machineName(run, "a") || r?.name === machineName(run, "b")));
  for (const r of rows) {
    const exec = directExec(api, idOf(r), { secrets });
    const lo = await exec(asRoot(`[ -S ${SOCK} ] && ${DIR}/bin/tailscale --socket=${SOCK} logout; rm -f ${KEY}; true`), 60_000).catch((e) => ({ code: -1, stdout: "", stderr: String((e as Error).message) }));
    await api.deleteMachine(idOf(r), `tailnet-move-${run}-delete-${idOf(r)}`);
    say(`${r.name} ${idOf(r)}: logout exit ${lo.code}, deleted`);
  }
  if (rows.length === 0) say("no machines of this run to delete");
}

const cmd = process.argv[2];
const run = arg("--run");
try {
  if (!run) throw new Error("--run ID is required");
  if (cmd === "up") await up(run);
  else if (cmd === "down") await down(run);
  else throw new Error("usage: tailnet-move-vms.ts up|down --run ID ...");
  process.exit(0);
} catch (e) {
  console.error(`tailnet-move-vms ${cmd}: ${redact(String((e as Error)?.message ?? e).slice(0, 3000))}`);
  process.exit(1);
}
