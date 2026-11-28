#!/usr/bin/env bun
/** Published-NIGHTLY recovery, with a real Claude conversation in a fresh staging account.
 * No result is a pass until the guest's journal, native conversation and old-source fence agree.
 * owned.json and all raw journals stay private; evidence.json contains only measurements.
 */
import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, openSync, closeSync, readFileSync, realpathSync, renameSync, statSync, watch, writeFileSync } from "node:fs";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { Api, CHAT_START_SIZE, directExec, freshAccountSignUp, http, INSTALLER_SWIFT, listAllMachines, loginPrograms, passwordSignIn, resolveBackend, STACK, waitPreflight, waitRunning } from "./cloud-journey.ts";
import { mintInstallToken, Socket, type InstallState } from "./auto-journey.ts";

const PRODUCT = "96ee46878c55c81ed64316b870a01cf6e3f2c71f";
const TAKEOVER = "The machine this chat ran on went away";
const SHA = /^[0-9a-f]{40}$/;
const HASH = /^[0-9a-f]{64}$/;
const MAX_WAIT = 20_000;
const arg = (name: string) => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
const shq = (s: string) => `'${s.replace(/'/g, `'"'"'`)}'`;
const hash = (s: string | Buffer) => createHash("sha256").update(s).digest("hex");
const fileHash = (p: string) => hash(readFileSync(p));
function check(ok: unknown, why: string): asserts ok { if (!ok) throw new Error(why); }
function writeJson(p: string, value: unknown) {
  mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 });
  const tmp = `${p}.tmp`;
  writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
  renameSync(tmp, p);
}
export type RuntimeReceipt = { path: string; sha256: string };
export type NightlyProvenance = {
  source_sha: string; daemon_source_sha: string; contains_sha: string; workflow_run: number;
  app_build: string; artifact_sha256: string; binary_path: string; binary_sha256: string;
  runtime_binaries: Record<string, RuntimeReceipt>; published: true; app_signature_verified: true;
  feed_url: string; artifact_url: string;
};
export function validateProvenance(value: any): NightlyProvenance {
  check(value && SHA.test(value.source_sha) && SHA.test(value.daemon_source_sha), "full 40-hex app and daemon sources required");
  check(value.contains_sha === PRODUCT, "provenance must contain the journal-replica product merge");
  check(value.published === true && value.app_signature_verified === true, "verified published app required");
  check(Number.isSafeInteger(Number(value.workflow_run)) && Number(value.workflow_run) > 0 && /^\d{3,20}$/.test(value.app_build), "numbered publication and workflow required");
  check(HASH.test(value.artifact_sha256) && HASH.test(value.binary_sha256), "artifact and daemon sha256 required");
  check(path.isAbsolute(value.binary_path ?? "") && value.runtime_binaries?.["cmux-tui"]?.path === value.binary_path, "binary path must be bound by runtime receipt");
  check(value.runtime_binaries["cmux-tui"].sha256 === value.binary_sha256, "daemon hashes disagree");
  check(value.feed_url === "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", "unexpected publication feed");
  check(typeof value.artifact_url === "string" && value.artifact_url.startsWith("https://"), "artifact URL required");
  for (const entry of Object.values(value.runtime_binaries) as RuntimeReceipt[]) {
    check(path.isAbsolute(entry.path ?? "") && HASH.test(entry.sha256), "invalid runtime entry");
  }
  return value;
}
export function verifyRuntimeFiles(p: NightlyProvenance, binary: string) {
  check(realpathSync(binary) === realpathSync(p.binary_path), "launched binary differs from publication receipt");
  for (const name of ["cmux-tui", "acpmux", "cmux-tui-host", "cmux-holder", "cmux-cloud"]) {
    check(!existsSync(path.join(path.dirname(binary), name)) || p.runtime_binaries[name], `published companion receipt missing: ${name}`);
  }
  for (const [name, entry] of Object.entries(p.runtime_binaries)) {
    check(existsSync(entry.path) && statSync(entry.path).isFile(), `published companion missing: ${name}`);
    check(fileHash(entry.path) === entry.sha256, `published companion changed: ${name}`);
  }
}
export type EventTuple = { seq: number; kind: string; msg: any };
export function eventTuples(events: any[]): EventTuple[] {
  return events.map(e => {
    const r = e.record ?? e;
    check(Number.isSafeInteger(e.seq) && e.seq > 0 && typeof r.kind === "string" && "msg" in r, "malformed journal event");
    return { seq: e.seq, kind: r.kind, msg: r.msg };
  });
}
// JSON objects are semantic maps; insertion order must not make two identical journals differ.
function canonical(v: any): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (v && typeof v === "object") return `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
  return JSON.stringify(v);
}
export function assertJournalPrefix(source: EventTuple[], restored: EventTuple[], through: number) {
  check(Number.isSafeInteger(through) && through > 256, "snapshot must span multiple event pages");
  const a = source.filter(e => e.seq <= through), b = restored.filter(e => e.seq <= through);
  check(a.length === through && a.every((e, i) => e.seq === i + 1), "source prefix is incomplete");
  check(canonical(a) === canonical(b), "restored native journal prefix differs");
  return hash(canonical(a));
}
export function assertSnapshot(answer: any, previous: number, nativeId: string) {
  const m = answer?.manifest;
  check(Number.isSafeInteger(answer?.snapshot) && answer.snapshot > previous, "renewal snapshot did not advance");
  check(m?.harness === "claude" && m.harnessSessionId === nativeId && !!nativeId, "snapshot lost native identity");
  check(m.openTurn?.tool?.name && typeof m.openTurn.tool.args === "string", "snapshot lost the running tool");
  check(Array.isArray(m.queue) && m.queue.length === 0, "a queued prompt forced the snapshot");
  check(Array.isArray(m.native) && m.native.some((f: any) => f.label === "claude-project" && f.chunks?.length), "snapshot has no native conversation");
  check(Number.isSafeInteger(m.lastSeq) && m.lastSeq > 256, "snapshot must span multiple event pages");
  return m;
}
export function assertMarker(text: string, nonce: string) {
  check(text === `${nonce}\n`, "shell execution marker missing or replayed");
}
export function assertRecovered(events: EventTuple[], through: number, nonce: string) {
  check(!events.some(e => e.kind === "resume_failed"), "native conversation resume failed");
  const continuation = events.filter(e => e.seq > through && e.kind === "user_message");
  check(continuation.length === 1 && continuation[0].msg?.text?.startsWith(TAKEOVER), "expected exactly one takeover continuation");
  const tail = events.filter(e => e.seq > continuation[0].seq);
  const ends = tail.filter(e => e.kind === "turn_result");
  check(ends.length === 1 && ends[0].msg?.status === "completed", "takeover turn did not finish successfully");
  check(!tail.some(e => e.kind === "tool_call"), "recovery launched a tool instead of answering from native history");
  const text = tail.filter(e => e.seq < ends[0].seq && e.kind === "agent_message_chunk").map(e => e.msg?.params?.update?.content?.text ?? e.msg?.text ?? "").join("");
  check(text.trim() === `recovered ${nonce}`, "real agent did not answer the recovery prompt");
}

/** Read all pages in one observed store range; never interpret a truncated page as completion. */
export async function storeEvents(read: (after: number) => Promise<any>, after: number): Promise<EventTuple[]> {
  const all: EventTuple[] = [];
  for (let page = 0; page < 1000; page++) {
    const r = await read(after), events = eventTuples(r.events);
    check(Number.isSafeInteger(r.lastSeq) && r.lastSeq >= after, "invalid store journal boundary");
    check(events.every((e, i) => e.seq === after + i + 1), "store journal page has gaps or duplicates");
    all.push(...events);
    if (events.length) after = events.at(-1)!.seq;
    if (after >= r.lastSeq) return all;
    check(events.length > 0, "store journal pagination made no progress");
  }
  throw new Error("store journal page bound exceeded");
}
export function claudeLoginFromEnv(env = process.env) {
  const token = env.CLAUDE_CODE_OAUTH_TOKEN?.trim();
  check(token && /^sk-ant-oat01-[\x21-\x7e]{20,}$/.test(token), "Claude setup-token login required");
  return token;
}
export async function waitStore(api: Pick<Api, "origin" | "bearer">, id: string, after: number, timeoutMs = MAX_WAIT) {
  check(id && Number.isSafeInteger(after) && after >= 0, "non-negative integer store cursor required");
  check(Number.isFinite(timeoutMs) && timeoutMs > 0 && timeoutMs <= MAX_WAIT, "invalid wait bound");
  const r = await http("GET", `${api.origin}/v1/auto-sessions/${encodeURIComponent(id)}/wait?after=${after}&timeoutMs=${Math.floor(timeoutMs)}`, undefined, { authorization: `Bearer ${api.bearer}` }, timeoutMs + 5000);
  check(r.status === 200 && r.body.session, `store wait HTTP ${r.status}`);
  return r.body.session;
}
async function get(api: Api, route: string) {
  const r = await api.raw("GET", `/v1/auto-sessions${route}`);
  check(r.status === 200, `Auto store GET HTTP ${r.status}`);
  return r.body;
}
async function untilStore(api: Api, id: string, want: (v: any) => boolean, budget: number) {
  let v = (await get(api, `/${id}`)).session;
  const deadline = Date.now() + budget;
  while (!want(v)) {
    const left = deadline - Date.now();
    check(left > 0, "Auto store condition deadline expired");
    v = await waitStore(api, id, v.version, Math.min(MAX_WAIT, left));
  }
  return v;
}
async function journal(call: (m: string, p: any) => Promise<any>, id: string) {
  const result: EventTuple[] = [];
  for (let after = 0, page = 0; page < 1000; page++) {
    const r = await call("_acpmux/events", { sessionId: id, afterSeq: after, limit: 256 });
    const events = eventTuples(r.events);
    result.push(...events);
    if (!r.hasMore) return result;
    check(events.length > 0 && events.at(-1)!.seq > after, "journal pagination made no progress");
    after = events.at(-1)!.seq;
  }
  throw new Error("journal page bound exceeded");
}

type ProcessIdentity = { pid: number; parent: number; started: string; command: string };
type Owned = { version: 1; tag: string; api: string; access?: string; identity?: { email: string; password: string }; install?: string; machine?: string; machineName: string; installName: string; processes: ProcessIdentity[]; cleaned?: boolean };
function processTable(): ProcessIdentity[] {
  const p = spawnSync("ps", ["-axo", "pid=,ppid=,lstart=,command="], { encoding: "utf8", timeout: 10_000 });
  check(p.status === 0, "cannot read process identities");
  return p.stdout.split("\n").flatMap(line => {
    const m = /^\s*(\d+)\s+(\d+)\s+(.{24})\s+(.+)$/.exec(line);
    return m ? [{ pid: Number(m[1]), parent: Number(m[2]), started: m[3], command: m[4] }] : [];
  });
}
export function sameProcess(a: ProcessIdentity, b: ProcessIdentity) { return a.pid === b.pid && a.started === b.started && a.command === b.command; }
export function descendants(root: number, table = processTable()) {
  const first = table.find(p => p.pid === root);
  if (!first) return [];
  const rows = [first], ids = new Set([root]);
  for (let i = 0; i < rows.length; i++) {
    for (const p of table) if (p.parent === rows[i].pid && !ids.has(p.pid)) { rows.push(p); ids.add(p.pid); }
  }
  return rows;
}
function signalOwned(p: ProcessIdentity, signal: NodeJS.Signals) {
  const live = processTable().find(x => x.pid === p.pid);
  if (!live) return;
  check(sameProcess(live, p), "refusing signal: process identity changed");
  process.kill(p.pid, signal);
}
function runtimeProcesses(rows: ProcessIdentity[], receipt: NightlyProvenance) {
  const found: { pid: number; name: string; sha256: string }[] = [];
  for (const p of rows) {
    // lsof's txt entries are mapped executable files, not argv labels. Require a signed
    // bundled executable's actual bytes, including a copied host/holder when split.
    const r = spawnSync("lsof", ["-a", "-p", String(p.pid), "-d", "txt", "-Fn"], { encoding: "utf8", timeout: 10_000 });
    check(r.status === 0, "cannot inspect owned process executable");
    const files = r.stdout.split("\n").filter(s => s.startsWith("n/")).map(s => s.slice(1));
    for (const file of files) {
      const name = path.basename(file);
      if (!["cmux-tui", "acpmux", "cmux-tui-host", "cmux-holder", "cmux-cloud"].includes(name)) continue;
      check(receipt.runtime_binaries[name], `unbound running companion: ${name}`);
      const sha256 = fileHash(file);
      check(sha256 === receipt.runtime_binaries[name].sha256, `running companion differs from NIGHTLY: ${name}`);
      found.push({ pid: p.pid, name, sha256 });
    }
  }
  check(found.length > 0, "no published engine process observed");
  return found;
}
/** A delete acknowledgement or a `deleting` row is not terminal cleanup evidence. */
export async function confirmDeleted(read: () => Promise<{ status: string } | null>, remove: () => Promise<unknown>, wait = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms))) {
  let row = await read();
  if (!row || row.status === "deleted") return;
  try { await remove(); } catch { /* The operation may have applied; reconcile its row. */ }
  for (const delay of [0, 1000, 2000, 4000, 8000, 16000, 30000]) {
    if (delay) await wait(delay);
    row = await read();
    if (!row || row.status === "deleted") return;
  }
  throw new Error("owned machine deletion not terminal");
}
async function cleanup(out: string) {
  const file = path.join(out, "owned.json");
  if (!existsSync(file)) return;
  const owned: Owned = JSON.parse(readFileSync(file, "utf8"));
  check(owned.version === 1 && owned.tag.startsWith("rfd0080-") && owned.api === resolveBackend("staging").api, "invalid cleanup ownership receipt");
  if (owned.cleaned) return;
  const failures: string[] = [];
  // Stop only identities recorded as descendants of this run's child. A reused PID is refused.
  for (const p of [...owned.processes].reverse()) {
    try { signalOwned(p, "SIGKILL"); } catch { failures.push(`process ${p.pid}`); }
  }
  if (owned.access) {
    const api = new Api(owned.api); api.bearer = owned.access;
    // Cancellation can leave a cleanup step running after the original access token expires.
    // This private receipt holds only the fresh account created by this run.
    if (owned.identity) {
      try { api.bearer = (await passwordSignIn(STACK[resolveBackend("staging").stack], owned.identity.email, owned.identity.password)).access; }
      catch { failures.push("cleanup account sign-in"); }
    }
    // A cut create/register may have applied. Reconcile only this unique run's exact name.
    try {
      if (!owned.machine) {
        const rows = await listAllMachines(params => api.read("cloud.machine.list", params));
        const matches = rows.filter((m: any) => m.name === owned.machineName && m.status !== "deleted");
        check(matches.length <= 1, "ambiguous owned machine");
        if (matches[0]) owned.machine = matches[0].id;
      }
      if (owned.machine) await confirmDeleted(async () => {
        try { return await api.read("cloud.machine.get", { machine: owned.machine }, 10_000); }
        catch (e) { if (/HTTP 404|cloud\.machine\.not_found/.test(String((e as Error).message))) return null; throw e; }
      }, () => api.deleteMachine(owned.machine!, `${owned.tag}-delete`, 60_000));
      delete owned.machine;
    } catch { failures.push("machine delete/reconcile"); }
    try {
      if (!owned.install) {
        const r = await api.read("install.list", {});
        const matches = (r.installs ?? []).filter((i: any) => i.name === owned.installName);
        check(matches.length <= 1, "ambiguous owned install");
        if (matches[0]) owned.install = matches[0].id;
      }
      if (owned.install) {
        try { await api.op("install.revoke", { install: owned.install }, `${owned.tag}-revoke`); } catch { /* Read back an ambiguous reply. */ }
        const r = await api.read("install.list", {});
        check(Array.isArray(r.installs), "install cleanup readback malformed");
        const remaining = r.installs.find((i: any) => i.id === owned.install);
        check(!remaining || remaining.revoked_at != null, "owned install revoke not confirmed");
      }
      delete owned.install;
    } catch { failures.push("install revoke/reconcile"); }
  }
  owned.cleaned = failures.length === 0;
  writeJson(file, owned);
  writeJson(path.join(out, "cleanup.json"), { cleaned: owned.cleaned, failures });
  check(owned.cleaned, `cleanup incomplete: ${failures.join(", ")}`);
}

/** Run a read on the guest's own unix socket. No chat creation, prompt, relay or projection. */
export function guestReadProgram(id: string, nativeId: string, marker: string) {
  return `python3 - <<'RFD0080_READ'\n${String.raw`
import hashlib,json,os,pathlib,socket,struct
sid,native,marker = INPUT
home=pathlib.Path('/home/cmux')
paths=[home/'.cmux/acpmux/acpmux.sock',home/'.acpmux/acpmux.sock']
sock=next((p for p in paths if p.exists()),None)
assert sock, 'guest daemon socket missing'
s=socket.socket(socket.AF_UNIX);s.settimeout(25);s.connect(str(sock));f=s.makefile('r');n=0
def call(method,params):
    global n
    n+=1;s.sendall((json.dumps({'jsonrpc':'2.0','id':n,'method':method,'params':params})+'\n').encode())
    while True:
        line=f.readline()
        assert line, 'guest socket closed'
        r=json.loads(line)
        if r.get('id')==n:
            assert 'error' not in r, 'guest RPC refused'
            return r['result']
hello=call('initialize',{'protocolVersion':1,'clientCapabilities':{}})
engine=hello.get('_meta',{}).get('acpmux',{})
pid,uid,gid=struct.unpack('3i',s.getsockopt(socket.SOL_SOCKET,socket.SO_PEERCRED,12))
exe=pathlib.Path('/proc')/str(pid)/'exe'
engine_receipt={'build':engine.get('build'),'version':engine.get('version'),'sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'pid':pid}
info=call('_acpmux/info',{'sessionId':sid})
assert info.get('agentSessionId')==native, 'guest native identity differs'
assert info.get('autoSession',{}).get('here') is True, 'guest is not the local holder'
events=[];after=0
for page in range(1000):
    r=call('_acpmux/events',{'sessionId':sid,'afterSeq':after,'limit':256})
    events.extend(r['events'])
    if not r.get('hasMore'): break
    assert r['events'] and r['events'][-1]['seq']>after, 'guest journal page stalled'
    after=r['events'][-1]['seq']
else: raise RuntimeError('guest page bound exceeded')
cwd=pathlib.Path(info['cwd']);expected=home/'Projects/auto'/sid
assert cwd==expected, 'guest recovery folder differs'
fpath=home/'.claude/projects'/''.join(c if c.isascii() and c.isalnum() else '-' for c in str(cwd))/(native+'.jsonl')
data=fpath.read_bytes();assert len(data)>=32768, 'guest native history too small'
print(json.dumps({'engine':engine_receipt,'nativeId':native,'nativeBytes':len(data),'nativeSha256':hashlib.sha256(data).hexdigest(),'marker':(cwd/marker).read_text(),'events':events,'here':True}))
`.replace("INPUT", JSON.stringify([id, nativeId, marker]))}\nRFD0080_READ`;
}

async function main() {
  const out = path.resolve(arg("--out") ?? "auto-journal-nightly-recovery-out");
  check(!existsSync(out), "recovery output must be new"); mkdirSync(out, { recursive: true, mode: 0o700 });
  const backend = resolveBackend(arg("--backend") ?? "staging");
  check(backend.name === "staging" && process.platform === "darwin", "requires staging on a managed Mac");
  const owned: Owned = { version: 1, tag: `rfd0080-${randomUUID()}`, api: backend.api, machineName: "", installName: "", processes: [] };
  owned.machineName = owned.installName = owned.tag;
  const keep = () => writeJson(path.join(out, "owned.json"), owned);
  keep();
  const evidence: any = { status: "fail", product_merge: PRODUCT, checks: {}, cleanup: false };
  let stage = "publication", child: ChildProcess | undefined, sock: Socket | undefined;
  const secrets: string[] = [];
  try {
    const binary = path.resolve(arg("--cmux-tui") ?? "");
    const provenance = validateProvenance(JSON.parse(readFileSync(arg("--provenance") ?? "", "utf8")));
    verifyRuntimeFiles(provenance, binary);
    evidence.publication = provenance;
    const token = claudeLoginFromEnv(); secrets.push(token);
    stage = "fresh-account";
    const account = await freshAccountSignUp(backend.stack); secrets.push(account.access, account.refresh, account.password);
    owned.access = account.access; owned.identity = { email: account.email, password: account.password }; keep();
    const api = new Api(backend.api); api.bearer = account.access;
    const user = await api.op("user.ensure", {}, `${owned.tag}-user`);
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
    const pub = await crypto.subtle.exportKey("jwk", pair.publicKey);
    const inst = await api.op("install.register", { public_jwk: { kty: "EC", crv: "P-256", x: pub.x, y: pub.y }, kind: "cli", name: owned.installName, device_name: owned.tag, platform: "macos" }, `${owned.tag}-install`);
    owned.install = inst.id; keep();
    const state: InstallState = { api: backend.api, user: inst.user ?? user.id ?? user.user?.id, install: inst.id, jwk: await crypto.subtle.exportKey("jwk", pair.privateKey), ...(inst.team ? { team: inst.team } : {}) };
    await mintInstallToken(state);
    stage = "owned-machine";
    const made = await api.op("cloud.machine.create", { name: owned.machineName, size: CHAT_START_SIZE }, `${owned.tag}-machine`);
    owned.machine = made.machine.id; keep();
    const machine = owned.machine!;
    const running = await waitRunning(api, machine, 300_000);
    evidence.cloud = { machine, image: { id: running.image?.id, daemon_version: running.image?.daemon_version } };
    check(running.image?.daemon_version, "Cloud daemon version receipt missing");
    const selected = await get(api, "/machine");
    const put = await api.raw("PUT", "/v1/auto-sessions/machine", { team: selected.team, machine });
    check(put.status === 200 && (await get(api, "/machine")).machine === machine, "owned Auto machine not assigned");
    const exec = directExec(api, machine, { secrets });
    const programs = loginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), "claude");
    await waitPreflight(exec, programs.preflight, "owner");
    const credential = `/home/cmux/.cmux/credential-transfer/${owned.tag}.txt`;
    const transfer = await api.raw("POST", `/v1/cloud/machines/${machine}/fs/write`, { path: credential, dataBase64: Buffer.from(token).toString("base64"), mode: 0o600 });
    check(transfer.status >= 200 && transfer.status < 300 && transfer.body?.ok !== false, "guest login transfer failed");
    check((await exec(programs.install(credential))).code === 0, "guest login installer refused");
    stage = "published-daemon";
    const home = path.join(out, "home"), work = path.join(home, "work");
    mkdirSync(work, { recursive: true });
    // A plain folder is a supported snapshot source. No network clone or invented remote.
    const nonce = randomUUID(), marker = "execution-marker.txt";
    writeFileSync(path.join(work, "silent.py"), `import os,time\nwith open(${JSON.stringify(marker)},'a') as f:\n f.write(${JSON.stringify(nonce + "\n")});f.flush();os.fsync(f.fileno())\ntime.sleep(600)\n`);
    const settings = path.join(home, ".config/cmux/cmux-next.json");
    writeJson(settings, { cloud: { autoCloud: true } });
    const stateFile = path.join(out, "install-state.json"); writeJson(stateFile, state);
    const stub = path.join(home, "bin/cmux"); mkdirSync(path.dirname(stub), { recursive: true });
    writeFileSync(stub, `#!/bin/sh\n[ "$1 $2 $3" = "--json auth token" ] || exit 2\nexec ${shq(process.execPath)} ${shq(path.join(path.dirname(fileURLToPath(import.meta.url)), "auto-journey.ts"))} --mint-token ${shq(stateFile)}\n`, { mode: 0o700 });
    const socket = path.join(os.tmpdir(), `rfd-${randomUUID().slice(0, 8)}.sock`);
    const daemonHome = path.join(home, ".acpmux"); mkdirSync(daemonHome, { recursive: true, mode: 0o700 });
    // Carry only OS setup into the isolated daemon, never a runner's other credentials,
    // session identity, model route or host-executable override.
    const env: Record<string, string> = {};
    for (const key of ["TMPDIR", "LANG", "LC_ALL", "SHELL", "USER", "LOGNAME", "SSL_CERT_FILE", "SSL_CERT_DIR"]) {
      if (process.env[key]) env[key] = process.env[key]!;
    }
    Object.assign(env, { HOME: home, ACPMUX_HOME: daemonHome, CMUX_BIN: stub, ACPMUX_SOCKET: socket, CMUX_NEXT_CONFIG_FILE: settings, CLAUDE_CODE_OAUTH_TOKEN: token, PATH: `${path.dirname(stub)}:${process.env.PATH ?? "/usr/bin:/bin"}` });
    const fd = openSync(path.join(out, "daemon.log"), "a", 0o600);
    child = spawn(binary, ["acp", "daemon", "run"], { env, stdio: ["ignore", fd, fd], detached: true }); closeSync(fd);
    check(child.pid, "daemon did not spawn");
    owned.processes = descendants(child.pid); check(owned.processes.length, "cannot record owned daemon"); keep();
    await new Promise<void>((resolve, reject) => {
      const done = (e?: Error) => { clearTimeout(timer); watcher.close(); child!.off("exit", exited); e ? reject(e) : resolve(); };
      const exited = () => done(new Error("owned daemon exited before socket"));
      const watcher = watch(path.dirname(socket), () => { if (existsSync(socket)) done(); });
      const timer = setTimeout(() => done(new Error("daemon socket deadline")), 120_000);
      child!.once("exit", exited); if (existsSync(socket)) done();
    });
    sock = await Socket.open(socket); const S = sock;
    await S.call("initialize", { protocolVersion: 1, clientCapabilities: {} });
    const created = await S.call("session/new", { cwd: work, mcpServers: [], _meta: { acpmux: { harness: "claude", policy: "approve-all" } } });
    const id = created.sessionId; check(typeof id === "string" && /^[a-zA-Z0-9_.-]+$/.test(id), "invalid session id"); evidence.session = id;
    await S.call("_acpmux/auto_session/set", { sessionId: id, auto: true });
    stage = "substantial-native-history";
    await S.call("session/prompt", { sessionId: id, prompt: [{ type: "text", text: "This is an isolated recovery test. Without tools, output exactly 700 numbered lines. Every line must contain its number and the words 'journal recovery retains the complete native conversation across a silent running tool'. Do not summarize or use ellipses." }] }, 240_000);
    const info = await S.call("_acpmux/info", { sessionId: id });
    const nativeId = info.agentSessionId; check(typeof nativeId === "string" && /^[a-zA-Z0-9_-]+$/.test(nativeId), "real Claude native identity missing");
    const nativeFile = path.join(home, ".claude/projects", work.replace(/[^a-zA-Z0-9]/g, "-"), `${nativeId}.jsonl`);
    check(statSync(nativeFile).size >= 32768, "native history is not substantial");
    evidence.native = { id: nativeId, source_bytes: statSync(nativeFile).size };
    const before = await untilStore(api, id, v => v.holder?.startsWith("device:") && v.snapshot > 0 && v.lastSeq > 256, 90_000);
    stage = "silent-running-tool";
    let promptFinished = false;
    // This promise stays pending while the shell sleeps; it is deliberately not awaited before snapshots.
    const prompt = S.call("session/prompt", { sessionId: id, prompt: [{ type: "text", text: `Execute 'python3 silent.py' once in the foreground with a 600000ms timeout. It must remain silent. Do not launch it in the background. If this turn is interrupted and resumed, NEVER execute this script again: answer exactly 'recovered ${nonce}' instead.` }] }, 900_000).then(() => { promptFinished = true; }, () => { promptFinished = true; });
    void prompt;
    // Store long polls are the wake source, including lease renewals during the quiet tool.
    let view = before;
    const deadline = Date.now() + 120_000;
    let baseline: any;
    while (!baseline) {
      check(Date.now() < deadline && !promptFinished, "silent tool did not remain running");
      view = await waitStore(api, id, view.version);
      if (!existsSync(path.join(work, marker))) continue;
      assertMarker(readFileSync(path.join(work, marker), "utf8"), nonce);
      const snap = await get(api, `/${id}/snapshot`);
      if (snap.manifest?.openTurn?.tool) { assertSnapshot(snap, 0, nativeId); baseline = snap; }
    }
    const snapshots = [baseline];
    for (let n = 0; n < 2; n++) {
      await untilStore(api, id, v => v.snapshot > snapshots.at(-1).snapshot, 60_000);
      const snap = await get(api, `/${id}/snapshot`);
      const m = assertSnapshot(snap, snapshots.at(-1).snapshot, nativeId);
      check(m.lastSeq === baseline.manifest.lastSeq && canonical(m.openTurn) === canonical(baseline.manifest.openTurn), "tool was not silent across renewal snapshots");
      check(!promptFinished, "source turn ended before renewal snapshots");
      snapshots.push(snap);
    }
    const manifest = snapshots.at(-1).manifest;
    const source = await journal((m, p) => S.call(m, p), id);
    check((await S.call("_acpmux/info", { sessionId: id })).status === "running", "source is not RUNNING");
    assertMarker(readFileSync(path.join(work, marker), "utf8"), nonce);
    evidence.snapshots = snapshots.map(s => ({ snapshot: s.snapshot, at: s.manifest.at, last_seq: s.manifest.lastSeq, open_tool: s.manifest.openTurn.tool.name }));
    stage = "lease-expiry";
    owned.processes = descendants(child.pid); keep();
    evidence.runtime = runtimeProcesses(owned.processes, provenance);
    const frozenAt = Date.now();
    // Stop parents before children, then discover children born during that first pass.
    // Persist every identity before signalling so cancellation cleanup can thaw it.
    const stopped = new Set<number>();
    for (let pass = 0; ; pass++) {
      check(pass < 8, "owned process tree did not quiesce");
      const rows = descendants(child.pid);
      const pending = rows.filter(p => !stopped.has(p.pid));
      if (!pending.length) break;
      for (const p of pending) {
        if (!owned.processes.some(old => sameProcess(old, p))) owned.processes.push(p);
        keep(); signalOwned(p, "SIGSTOP"); stopped.add(p.pid);
      }
    }
    const takeover = await untilStore(api, id, v => v.holder === `vm:${machine}` && v.epoch > before.epoch && v.leaseExpiresAt > 0, 180_000);
    check(Date.now() - frozenAt >= 35_000, "takeover occurred without lease-expiry boundary");
    evidence.takeover = { holder: takeover.holder, epoch: takeover.epoch, elapsed_ms: Date.now() - frozenAt };
    stage = "guest-continuation";
    // The store only wakes this wait. The verdict below reads the guest daemon's journal.
    let completed = false, cursor = takeover;
    const continuationEvents: EventTuple[] = [];
    const finishBy = Date.now() + 180_000;
    while (!completed) {
      continuationEvents.push(...await storeEvents(after => get(api, `/${id}/events?after=${after}&limit=256`), continuationEvents.at(-1)?.seq ?? manifest.lastSeq));
      const continued = continuationEvents.find(e => e.kind === "user_message" && e.msg?.text?.startsWith(TAKEOVER));
      completed = !!continued && continuationEvents.some(e => e.seq > continued.seq && e.kind === "turn_result");
      if (!completed) { check(Date.now() < finishBy, "guest continuation deadline"); cursor = await waitStore(api, id, cursor.version); }
    }
    const remote = await exec(guestReadProgram(id, nativeId, marker), 120_000);
    check(remote.code === 0, "guest journal/native read failed");
    const guest = JSON.parse(remote.stdout);
    // The Cloud engine is a deployed Linux binary, not the Mac NIGHTLY executable.
    // Bind the socket peer's bytes and stamped source separately from the publication.
    const build = /^([0-9a-f]{7,40}) (\d{4}-\d{2}-\d{2})$/.exec(guest.engine?.build ?? "");
    check(build && HASH.test(guest.engine?.sha256) && typeof guest.engine?.version === "string", "guest socket engine provenance missing");
    const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
    const sourceRead = spawnSync("git", ["-C", repo, "rev-parse", "--verify", `${build[1]}^{commit}`], { encoding: "utf8", timeout: 10_000 });
    const guestSource = sourceRead.stdout?.trim();
    check(sourceRead.status === 0 && SHA.test(guestSource), "guest engine source not in verification checkout");
    check(spawnSync("git", ["-C", repo, "merge-base", "--is-ancestor", PRODUCT, guestSource], { timeout: 10_000 }).status === 0, "guest engine source lacks journal-replica merge");
    evidence.cloud.engine = { ...guest.engine, source_sha: guestSource, contains_sha: PRODUCT };
    const restored = eventTuples(guest.events);
    evidence.journal = { through: manifest.lastSeq, prefix_sha256: assertJournalPrefix(source, restored, manifest.lastSeq) };
    assertRecovered(restored, manifest.lastSeq, nonce); assertMarker(guest.marker, nonce);
    check(guest.nativeId === nativeId && guest.here === true, "guest native conversation/holder mismatch");
    evidence.native.guest_bytes = guest.nativeBytes; evidence.native.guest_sha256 = guest.nativeSha256;
    stage = "old-source-fence";
    for (const p of owned.processes) signalOwned(p, "SIGCONT");
    await S.call("_acpmux/auto_session/wake", {});
    // Socket changes wake the local read; the shared store is not evidence of local fencing.
    const fenced = await S.waitUntil(async () => (await S.call("_acpmux/info", { sessionId: id })).autoSession?.here === false, 60_000);
    check(fenced, "old source did not acknowledge here:false");
    assertMarker(readFileSync(path.join(work, marker), "utf8"), nonce);
    evidence.checks = { publication: true, silent_renewals: true, lease_expiry: true, native_resume: true, journal_prefix: true, exactly_one_continuation: true, no_shell_replay: true, old_source_fenced: true };
    evidence.status = "pass";
  } catch (error) {
    evidence.status = "fail"; evidence.stage = stage;
    // No backend response bodies, raw journal or bearer reach the public artifact.
    let message = String((error as Error).message ?? "verification failed");
    for (const secret of secrets.filter(Boolean)) message = message.split(secret).join("[redacted]");
    writeFileSync(path.join(out, "failure.txt"), message.replace(/sk-ant-oat01-[\x21-\x7e]+/g, "[redacted]"), { mode: 0o600 });
    evidence.error = `verification failed during ${stage}; details retained privately`;
  } finally {
    sock?.close();
    try { if (child?.pid) {
      const root = owned.processes.find(p => p.pid === child!.pid);
      const live = processTable().find(p => p.pid === child!.pid);
      if (root && live && sameProcess(root, live)) {
        const all = descendants(child.pid);
        for (const p of all) if (!owned.processes.some(old => sameProcess(old, p))) owned.processes.push(p);
        keep();
      }
    } } catch { evidence.process_reconciliation_failed = true; evidence.status = "fail"; }
    try { await cleanup(out); evidence.cleanup = true; } catch { evidence.cleanup = false; evidence.status = "fail"; }
    writeJson(path.join(out, "evidence.json"), evidence);
  }
  return evidence.status === "pass" ? 0 : 1;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { if (arg("--cleanup")) await cleanup(path.resolve(arg("--cleanup")!)); else process.exitCode = await main(); }
  catch (e) { console.error((e as Error).message); process.exitCode = 1; }
}
