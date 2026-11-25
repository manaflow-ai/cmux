#!/usr/bin/env bun
/**
 * The Cloud Chief on a fresh staging machine (images/cmux-vm/chief, web/scripts/cmux-vm-image/chief-host.ts):
 *
 *   1. create `cmux-test-chief-<run>` (deleted in the finally path; older leftovers of this check are swept first);
 *   2. install the chief units with the image's own install.sh and this run's optchat-chief (`--binary`), unless the
 *      machine's image already carries them (then its own build is checked as is);
 *   3. `optchat-chief --version` runs;
 *   4. pair the machine's brain on the test account (enroll, register, default chief), enable cmux-chief.service, and
 *      check it is active with the same main pid and no restarts 30 s later;
 *   5. self-update: a new build (this one plus a nonce, so a new sha256) behind a file:// manifest; cmux-chief-update
 *      moves `current`, the host hands off between turns, and systemd starts the new build. Before and after it, the
 *      host's acpmux daemon and a probe subagent (a minimal ACP agent under that daemon): whether the update ends them;
 *   6. rollback: a build that passes `--version` and exits 1 as host is rolled back after its third failed start,
 *      one that exits 2 at once; `current` is the build before it again, the host runs it, and the updater does not
 *      take the refused build again. Then `cmux-chief-update --rollback` by hand. Each prints its times;
 *   7. finally: revoke the install and delete the machine.
 *
 * Usage: bun scripts/cmux-next/cloud-chief-check.ts --binary PATH [--target staging] [--out DIR] [--run ID]
 * Env: CMUX_DOGFOOD_STACK_EMAIL, CMUX_DOGFOOD_STACK_PASSWORD (the staging agent test account), PRODUCT_TEAM (optional).
 */
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Api, directExec, Journey, listAllMachines, machineStopFields, passwordSignIn, resolveBackend, STACK, type Exec } from "./cloud-journey";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const CHIEF_DIR = path.join(ROOT, "images/cmux-vm/chief");
const STAGE = "/var/tmp/cmux-chief-check";
const NAME_PREFIX = "cmux-test-chief-";
const SWEEP_AFTER_MS = 3 * 60 * 60 * 1000;
const CHUNK = 3 << 20;
const CHANNEL_URL = "https://files.cmux.com/cmux-tui/channels/cloud-machine.json";
const INSTALL_FILE = "/home/cmux/.cmux/chief/cloud/install.json";

const arg = (name: string): string | undefined => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
};
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/** One command as root (the exec route may run as the work user, whose sudo asks no password on the image). */
const asRoot = (cmd: string) => `if [ "$(id -u)" = 0 ]; then sh -c ${shq(cmd)}; else sudo -n sh -c ${shq(cmd)}; fi`;
/** One command as the work user, whichever user the exec route runs as. */
const asUser = (cmd: string) => `if [ "$(id -u)" = 0 ]; then runuser -u cmux -- sh -c ${shq(cmd)}; else sh -c ${shq(cmd)}; fi`;

async function must(exec: Exec, cmd: string, timeoutMs = 120_000): Promise<string> {
  const r = await exec(cmd, timeoutMs);
  if (r.code !== 0) throw new Error(`exit ${r.code}: ${(r.stderr || r.stdout).trim().slice(-800)}`);
  return r.stdout.trim();
}

async function writeFile(api: Api, machine: string, file: string, data: Buffer, mode: number): Promise<void> {
  const w = await api.raw("POST", `/v1/cloud/machines/${machine}/fs/write`, { path: file, dataBase64: data.toString("base64"), mode }, 120_000);
  if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`fs/write ${file}: HTTP ${w.status} ${String(w.body?.error?.code ?? "")}`);
}

/** The binary in CHUNK-sized parts (one fs/write each), joined and checked on the machine. */
async function upload(api: Api, machine: string, exec: Exec, data: Buffer, dest: string): Promise<void> {
  await must(exec, asRoot(`rm -rf ${STAGE}/parts && mkdir -p ${STAGE}/parts`));
  const parts: string[] = [];
  for (let off = 0, i = 0; off < data.length; off += CHUNK, i++) {
    const p = `${STAGE}/parts/${String(i).padStart(4, "0")}`;
    await writeFile(api, machine, p, data.subarray(off, off + CHUNK), 0o644);
    parts.push(p);
  }
  const sha = createHash("sha256").update(data).digest("hex");
  await must(exec, asRoot(`cat ${parts.join(" ")} > ${dest} && chmod 0755 ${dest} && rm -rf ${STAGE}/parts && test "$(sha256sum ${dest} | cut -d' ' -f1)" = ${sha}`));
}

async function waitRunning(api: Api, machine: string, timeoutMs: number): Promise<any> {
  const until = Date.now() + timeoutMs;
  for (;;) {
    const v = await api.read("cloud.machine.get", { machine });
    const m = v?.machine ?? v;
    if (m?.status === "running" && m?.host) return m;
    if (m?.status === "failed" || m?.status === "deleted") throw new Error(`machine ${machine} is ${m.status}`);
    if (Date.now() > until) throw new Error(`machine ${machine} not running after ${timeoutMs} ms (status ${m?.status})`);
    await sleep(3000);
  }
}

const unitFacts = async (exec: Exec) => {
  const out = await must(exec, "systemctl show cmux-chief.service -p ActiveState -p SubState -p MainPID -p NRestarts -p ExecMainStatus");
  return Object.fromEntries(out.split("\n").map((l) => l.split("=", 2) as [string, string]));
};
const journal = (exec: Exec) => exec(asRoot("journalctl -u cmux-chief.service -u cmux-chief-update.service --no-pager -o cat -n 60"), 30_000).then((r) => r.stdout.trim().slice(-2500));

const CURRENT = "/var/lib/cmux-chief/current";
/** The host's own acpmux (cmux-chief.service's ACPMUX_HOME and ACPMUX_BIN), as the work user. */
const ACPMUX = "env ACPMUX_HOME=/home/cmux/.cmux/chief/acpmux ACPMUX_BIN=/opt/cmux/current/bin/acpmux /opt/cmux/current/bin/acpmux";
/** A minimal ACP agent (initialize, session/new, session/prompt): the probe subagent, cheap and without a sign-in. */
const PROBE_AGENT = `import json, sys, time
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if "id" not in m or "method" not in m:
        continue
    r = {"initialize": {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []},
         "session/new": {"sessionId": "chief-probe-%d" % int(time.time() * 1000)},
         "session/prompt": {"stopReason": "end_turn"}}.get(m["method"], {})
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}) + "\\n")
    sys.stdout.flush()
`;
const PROBE_PROFILE = `schema = 1
id = "chiefprobe"
name = "Chief check probe"
protocol = "acp"
command = "python3"
args = ["-I", "/home/cmux/.cmux/chief/chief-probe-agent.py"]
`;

/** Every process in cmux-chief.service's cgroup, `pid comm` each. */
const unitProcs = async (exec: Exec) =>
  (await exec(asRoot("cg=$(systemctl show -p ControlGroup --value cmux-chief.service); [ -n \"$cg\" ] && [ -d /sys/fs/cgroup$cg ] || exit 0; find /sys/fs/cgroup$cg -name cgroup.procs -exec cat {} + | sort -n | while read -r p; do echo \"$p $(cat /proc/$p/comm 2>/dev/null)\"; done"), 30_000)).stdout.trim().split("\n").filter(Boolean);
/** The acpmux daemon in cmux-chief.service's cgroup (the one the host started) and the probe subagent: their pids (0: none runs). */
const daemonAndProbe = async (exec: Exec) => {
  const out = (await exec(asRoot("cg=$(systemctl show -p ControlGroup --value cmux-chief.service); [ -n \"$cg\" ] && [ -d /sys/fs/cgroup$cg ] || { echo 0 0; exit 0; }; d=0; p=0; for q in $(find /sys/fs/cgroup$cg -name cgroup.procs -exec cat {} + | sort -n); do c=$(tr '\\0' ' ' < /proc/$q/cmdline 2>/dev/null); case \"$c\" in *'daemon run'*) [ $d = 0 ] && d=$q ;; *chief-probe-agent.py*) [ $p = 0 ] && p=$q ;; esac; done; echo $d $p"), 30_000)).stdout.trim().split(/\s+/);
  return { daemon: Number(out[0] || 0), probe: Number(out[1] || 0) };
};
const alive = async (exec: Exec, pid: number) => pid > 0 && (await exec(`kill -0 ${pid} 2>/dev/null && echo up || echo gone`)).stdout.trim() === "up";

/** Shell lines that put a build at DIR/optchat-chief behind DIR/manifest.json and run the updater. */
const publishAndUpdate = (dir: string, make: string[]) => [
  `rm -rf ${dir} && mkdir -p ${dir}`,
  ...make,
  `sha=$(sha256sum ${dir}/optchat-chief | cut -d' ' -f1); size=$(stat -c %s ${dir}/optchat-chief)`,
  `printf '{"commit":"check","url":"file://${dir}/optchat-chief","sha256":"%s","size":%s}\\n' "$sha" "$size" > ${dir}/manifest.json`,
  `echo "sha $sha"`,
  `CMUX_CHIEF_MANIFEST_URL=file://${dir}/manifest.json /usr/local/sbin/cmux-chief-update`,
].join(" && ");
const shaLine = (out: string) => /^sha ([0-9a-f]{64})$/m.exec(out)?.[1] ?? "";
/** A copy of the build `current` names with a trailing nonce (another sha256; the ELF still runs). */
const goodCopy = (dir: string) => [`cp "$(readlink -f ${CURRENT})" ${dir}/optchat-chief`, `printf %s ${randomBytes(8).toString("hex")} >> ${dir}/optchat-chief`];
/** A build whose `--version` passes and whose host exits CODE at once. */
const brokenBuild = (dir: string, code: number) => {
  const script = `#!/bin/sh\ncase "\${1:-}" in --version) echo "optchat-chief 0.0.0-broken-${randomBytes(4).toString("hex")}"; exit 0 ;; esac\necho "broken check build: exits ${code} as host" >&2\nexit ${code}\n`;
  return [`echo ${Buffer.from(script).toString("base64")} | base64 -d > ${dir}/optchat-chief`, `chmod 0755 ${dir}/optchat-chief`];
};

/**
 * Waits until the host runs the build at `want` (its MainPID's exe) with `current` naming it, the main pid other than
 * `notPid`, and `refused` (when given) the first field of /var/lib/cmux-chief/refused. Returns the ms it took.
 */
async function waitHostOn(exec: Exec, want: string, notPid: string, refused: string | null, limitMs: number): Promise<{ ms: number; pid: string }> {
  const t0 = Date.now();
  let seen = "";
  while (Date.now() - t0 < limitMs) {
    const r = await exec(asRoot(`st=$(systemctl show cmux-chief.service -p ActiveState --value); pid=$(systemctl show cmux-chief.service -p MainPID --value); set -- $st $pid; cur=$(readlink -f ${CURRENT}); exe=$(readlink -f /proc/$2/exe 2>/dev/null || true); ref=$(cut -d' ' -f1 /var/lib/cmux-chief/refused 2>/dev/null || true); echo "$1 $2 $cur $exe $ref"`), 30_000);
    seen = r.stdout.trim();
    const [state, pid, cur, exe, ref] = seen.split(" ");
    if (state === "active" && pid !== "0" && pid !== notPid && cur === want && exe === want && (refused === null || ref === refused)) return { ms: Date.now() - t0, pid };
    await sleep(2_000);
  }
  throw new Error(`the host is not on ${want} after ${limitMs} ms (last: ${seen})\n${await journal(exec)}`);
}

async function main(): Promise<number> {
  const binaryPath = arg("--binary");
  if (!binaryPath) throw new Error("--binary PATH (this run's optchat-chief, x86_64 Linux) is required");
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD are required (never a skip)");
  const backend = resolveBackend(arg("--target") ?? "staging");
  const run = arg("--run") ?? `${process.env.GITHUB_RUN_ID ?? Date.now()}-${process.env.GITHUB_RUN_ATTEMPT ?? "1"}`;
  const outDir = arg("--out") ?? null;
  if (outDir) mkdirSync(outDir, { recursive: true });
  const J = new Journey(backend, outDir, { check: "cloud-chief", run });
  J.secrets.push(password);
  const binary = readFileSync(binaryPath);
  const name = `${NAME_PREFIX}${run}`;
  const api = new Api(backend.api, process.env.PRODUCT_TEAM || undefined);
  let machine = "";
  let install = "";
  try {
    await J.step("sign in", async () => {
      const s = await passwordSignIn(STACK[backend.stack], email, password);
      J.secrets.push(s.access, s.refresh);
      api.bearer = s.access;
      await api.op("user.ensure", {}, `chief-check-${run}-ensure`);
      return { value: null, detail: backend.api };
    });
    await J.step("sweep old check machines", async () => {
      const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
      const old = rows.filter((r) => String(r?.name ?? "").startsWith(NAME_PREFIX) && r.status !== "deleted" && r.status !== "deleting" && typeof r.created_at === "number" && Date.now() - r.created_at > SWEEP_AFTER_MS);
      for (const r of old) await api.deleteMachine(String(r.id ?? r.machine_id), `chief-check-sweep-${r.id ?? r.machine_id}`).catch(() => undefined);
      return { value: null, detail: `${old.length} older than 3 h deleted` };
    });
    const m = await J.step("create machine", async () => {
      // Run 45562243340: the create's request hit Api.op's 60 s cap ("The operation timed out") on a slow staging
      // create; run 45558916018's answered in 35 s. The create is keyed, so ask again under the same key, which
      // answers the machine the first ask made instead of a second one, for up to 5 min in all.
      const createKey = `chief-check-${run}-create`;
      const createUntil = Date.now() + 300_000;
      let asks = 0;
      let v: any;
      for (;;) {
        asks++;
        try {
          v = await api.op("cloud.machine.create", { name, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, createKey);
          break;
        } catch (e) {
          const msg = String((e as Error)?.message ?? e);
          if (!/timed out|TimeoutError|aborted/i.test(msg) || Date.now() > createUntil) throw new Error(`${msg} (ask ${asks} under ${createKey})`);
          console.log(`create machine: ask ${asks} cut off (${msg}); asking again under the same key`);
        }
      }
      machine = String(v.machine.id);
      const up = await waitRunning(api, machine, 420_000);
      return { value: up, detail: `${name} ${machine} (${asks} ask${asks === 1 ? "" : "s"}), image ${up?.image?.id ?? up?.image?.name ?? "?"}, daemon ${up?.image?.daemon_version ?? "?"}` };
    });
    void m;
    // Run 45558916018: the machine stopped 207 s after create, between the readback's 15 s polls (exec 409
    // vm_not_running). A fresh machine with no client is idle to the platform; turn its idle pause off, as the
    // wake-echo journey does, so the check measures the update and not the idle policy.
    await J.step("idle pause off", async () => {
      await api.op("cloud.machine.idle_policy.set", { machine, idle_seconds: 0 }, `chief-check-${run}-idle`);
      return { value: null, detail: "idle_seconds 0" };
    });
    const rawExec = directExec(api, machine, J);
    // A refused exec names who stopped the machine (status, pause_reason, paused_by), not only the HTTP code.
    const exec: Exec = async (command, timeoutMs) => {
      try {
        return await rawExec(command, timeoutMs);
      } catch (e) {
        const msg = String((e as Error)?.message ?? e);
        if (!/409/.test(msg)) throw e;
        const row = await api.read("cloud.machine.get", { machine }).then((v: any) => machineStopFields(v?.machine ?? v), (r) => `read failed: ${String((r as Error)?.message ?? r)}`);
        throw new Error(`${msg}; machine row: ${JSON.stringify(row)}`);
      }
    };

    // RFD 0166 row 302: a fresh Cloud machine runs the acpmux the signed cloud-machine channel names, not the
    // image's build or main's rolling cmux-tui/latest. The image's updater reads the channel 30 s after boot and
    // every minute, so wait for it, then read back acpmux's version and the updater's status.
    await J.step("acpmux follows the cloud-machine channel", async () => {
      const res = await fetch(CHANNEL_URL, { signal: AbortSignal.timeout(20_000) });
      if (!res.ok) throw new Error(`${CHANNEL_URL}: HTTP ${res.status}`);
      const want = String(JSON.parse(Buffer.from(String((await res.json()).payload), "base64").toString("utf8")).commit ?? "");
      if (!/^[0-9a-f]{40}$/.test(want)) throw new Error(`the channel names no commit: ${want}`);
      const read = `${ACPMUX} --version 2>&1 | head -n 3; echo ---; (cmux host update status --json || /opt/cmux/current/bin/cmux host update status --json) 2>&1 | head -c 4000`;
      const deadline = Date.now() + 300_000;
      let seen = "";
      const w12 = want.slice(0, 12);
      // acpmux prints a short commit (`acpmux 1.0.0 (29d6beb60 2026-11-25)`, 9 hex today): match any hex run of
      // 7+ in the version line as a prefix of the channel's commit, not a fixed 12-char slice.
      const runsWant = (version: string): boolean =>
        (version.match(/\b[0-9a-f]{7,40}\b/g) ?? []).some((h) => want.startsWith(h));
      // Only a flip to the channel's build, or a first check that found the image already on it, counts: the
      // status always echoes the channel's commit, so a bare substring match would pass a machine that never moved.
      const onChannel = (out: string): boolean => {
        const [version, status = ""] = out.split("\n---");
        if (runsWant(version)) return true;
        let st: any;
        try { st = JSON.parse(status.slice(status.indexOf("{"))); } catch { return false; }
        if (st?.off) throw new Error(`the machine's updater is off: ${JSON.stringify(st.off)}`);
        const look = st?.state?.look, first = st?.state?.first_ready;
        return st?.state?.applied_commit === want
          || (look?.settled?.commit === w12 && look.settled.outcome === "updated")
          || look?.swapped?.commit === w12
          || (first?.outcome === "current" && String(first.channel_commit ?? "").startsWith(w12));
      };
      for (;;) {
        seen = (await exec(asRoot(read), 60_000)).stdout.trim();
        if (onChannel(seen)) break;
        if (Date.now() > deadline) throw new Error(`after 5 min the machine still does not run channel commit ${want}: ${seen.slice(0, 1500)}`);
        await sleep(15_000);
      }
      const version = seen.split("\n---")[0].replace(/\s+/g, " ").trim();
      console.log(`acpmux channel readback: channel ${want}; acpmux ${version}`);
      return { value: want, detail: `channel ${want.slice(0, 12)}; acpmux ${version}` };
    });

    const baked = await J.step("image chief units", async () => {
      const r = await exec("test -f /etc/systemd/system/cmux-chief.service && test -x /var/lib/cmux-chief/current && echo baked || echo absent");
      return { value: r.stdout.trim() === "baked", detail: r.stdout.trim() };
    });
    if (!baked) {
      await J.step("install chief units (install.sh, this run's build)", async () => {
        await must(exec, asRoot(`rm -rf ${STAGE} && mkdir -p ${STAGE}/chief`));
        for (const f of readdirSync(CHIEF_DIR)) await writeFile(api, machine, `${STAGE}/chief/${f}`, readFileSync(path.join(CHIEF_DIR, f)), 0o644);
        await upload(api, machine, exec, binary, `${STAGE}/optchat-chief`);
        // The image's store is read-only; a build installed after the bake lives in the updater's own store.
        const sha = createHash("sha256").update(binary).digest("hex");
        const out = await must(exec, asRoot(`install -d -m 0755 /var/lib/cmux-chief/store/${sha} && install -m 0755 ${STAGE}/optchat-chief /var/lib/cmux-chief/store/${sha}/optchat-chief && sh ${STAGE}/chief/install.sh ${STAGE}/chief /var/lib/cmux-chief/store/${sha}/optchat-chief`), 180_000);
        return { value: null, detail: out.split("\n").at(-1) ?? "" };
      });
    }
    await J.step("optchat-chief --version", async () => {
      const out = await must(exec, asUser("optchat-chief --version"));
      if (!/^optchat-chief \d+\.\d+\.\d+/.test(out)) throw new Error(`unexpected --version: ${out}`);
      return { value: null, detail: out };
    });
    await J.step("unit installed disabled", async () => {
      const enabled = (await exec("systemctl is-enabled cmux-chief.service")).stdout.trim();
      if (enabled !== "disabled") throw new Error(`cmux-chief.service is ${enabled}, not disabled`);
      return { value: null, detail: enabled };
    });

    await J.step("pair the brain (enroll, register, default chief)", async () => {
      await must(exec, asUser(`mkdir -p -m 0700 ${path.dirname(INSTALL_FILE)} && optchat-chief cloud enroll --install ${INSTALL_FILE} --api-base ${backend.api} >/dev/null`));
      // The session token reaches the machine as a 0600 file the command reads and removes, never in argv.
      const tokenFile = `/home/cmux/.cmux/chief/cloud/.session-${randomBytes(6).toString("hex")}`;
      await writeFile(api, machine, tokenFile, Buffer.from(api.bearer), 0o600);
      await must(exec, asRoot(`chown cmux:cmux ${tokenFile} && chmod 0600 ${tokenFile}`));
      await must(exec, asUser(`CMUX_CLOUD_SESSION_TOKEN="$(cat ${tokenFile})"; rm -f ${tokenFile}; export CMUX_CLOUD_SESSION_TOKEN; optchat-chief cloud register --install ${INSTALL_FILE} --name ${shq(name)} --device ${shq(name)} >/dev/null`));
      // Read the install right after register, so the finally path revokes it even when the next command fails.
      install = await must(exec, asUser(`python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("install") or "")' ${INSTALL_FILE}`));
      const chief = await must(exec, asUser(`optchat-chief cloud chief --install ${INSTALL_FILE} --create`));
      return { value: null, detail: `${install}; ${chief.split("\n").at(-1)}` };
    });

    const first = await J.step("cmux-chief.service starts and stays active", async () => {
      await must(exec, asRoot("systemctl enable --now cmux-chief.service"), 180_000);
      await sleep(5_000);
      const a = await unitFacts(exec);
      await sleep(30_000);
      const b = await unitFacts(exec);
      if (b.ActiveState !== "active" || a.MainPID !== b.MainPID || b.NRestarts !== "0" || b.MainPID === "0") {
        throw new Error(`not steady: at 5 s ${JSON.stringify(a)}, at 35 s ${JSON.stringify(b)}\n${await journal(exec)}`);
      }
      return { value: b, detail: `active, pid ${b.MainPID}, restarts ${b.NRestarts}` };
    });

    // Whether an update ends the host's acpmux daemon and its subagents (review follow-up of #50074): a probe
    // subagent under the host's daemon before the update, looked at after it.
    const before = await J.step("acpmux daemon and a probe subagent before the update", async () => {
      let made = "";
      try {
        await must(exec, asUser("mkdir -p /home/cmux/.config/cmux/harnesses"));
        await writeFile(api, machine, "/home/cmux/.cmux/chief/chief-probe-agent.py", Buffer.from(PROBE_AGENT), 0o644);
        await writeFile(api, machine, "/home/cmux/.config/cmux/harnesses/chiefprobe.toml", Buffer.from(PROBE_PROFILE), 0o644);
        await must(exec, asRoot("chown -R cmux:cmux /home/cmux/.config/cmux /home/cmux/.cmux/chief/chief-probe-agent.py"));
        made = (await exec(asUser(`${ACPMUX} harness reload 2>&1 | tail -n 1; ${ACPMUX} new -d -m chiefprobe -n chief-probe 2>&1 | tail -n 3`), 90_000)).stdout.trim().replace(/\n/g, " | ");
      } catch (e) {
        made = `probe not started: ${String((e as Error)?.message ?? e).slice(0, 300)}`;
      }
      let pids = await daemonAndProbe(exec);
      for (let i = 0; i < 10 && !pids.probe; i++) {
        await sleep(2_000);
        pids = await daemonAndProbe(exec);
      }
      const procs = await unitProcs(exec);
      return { value: pids, detail: `daemon pid ${pids.daemon}, probe pid ${pids.probe} (${made}); unit cgroup: ${procs.join(", ")}` };
    });

    const updated = await J.step("self-update hands off between turns and starts the new build", async () => {
      const dir = `${STAGE}/feed`;
      const nonce = randomBytes(8).toString("hex");
      // A build with other bytes (a trailing nonce: the ELF still runs) behind a file:// manifest.
      const out = await must(exec, asRoot([
        `rm -rf ${dir} && mkdir -p ${dir}`,
        `cp "$(readlink -f /var/lib/cmux-chief/current)" ${dir}/optchat-chief && printf %s ${nonce} >> ${dir}/optchat-chief`,
        `sha=$(sha256sum ${dir}/optchat-chief | cut -d' ' -f1); size=$(stat -c %s ${dir}/optchat-chief)`,
        `printf '{"commit":"check-${nonce}","url":"file://${dir}/optchat-chief","sha256":"%s","size":%s}\\n' "$sha" "$size" > ${dir}/manifest.json`,
        `CMUX_CHIEF_MANIFEST_URL=file://${dir}/manifest.json /usr/local/sbin/cmux-chief-update`,
        `test "$(readlink -f /var/lib/cmux-chief/current)" = /var/lib/cmux-chief/store/$sha/optchat-chief && echo "moved $sha"`,
      ].join(" && ")), 300_000);
      const until = Date.now() + 120_000;
      let facts = await unitFacts(exec);
      while (Date.now() < until && (facts.MainPID === first.MainPID || facts.ActiveState !== "active")) {
        await sleep(3_000);
        facts = await unitFacts(exec);
      }
      const log = await journal(exec);
      if (facts.MainPID === first.MainPID || facts.ActiveState !== "active") throw new Error(`no restart onto the new build: ${JSON.stringify(facts)}\n${log}`);
      const exe = await must(exec, asRoot(`readlink -f /proc/${facts.MainPID}/exe`));
      if (!exe.startsWith("/var/lib/cmux-chief/store/")) throw new Error(`the host runs ${exe}`);
      // The whole unit journal: the new host's start lines push the old host's last line out of the tail.
      const handoff = await exec(asRoot("journalctl -u cmux-chief.service -o cat --no-pager | grep -F 'handed off between turns' | tail -n 3"), 30_000);
      if (!handoff.stdout.trim()) throw new Error(`the host restarted without the between-turns handoff line:\n${log}`);
      return { value: { pid: facts.MainPID, exe }, detail: `${out.split("\n").at(-1)}; pid ${first.MainPID} -> ${facts.MainPID} (${exe}); ${handoff.stdout.trim().split("\n").at(-1)}` };
    });

    // The handoff ends only the host (KillMode=process); ExecStop's `daemon shutdown` detaches the agents and the new
    // host's daemon adopts them, so the probe subagent's process is the same one before and after.
    const probeKept = async (what: string) => {
      let now = await daemonAndProbe(exec);
      for (let i = 0; i < 30 && (!now.daemon || now.daemon === before.daemon); i++) {
        await sleep(2_000);
        now = await daemonAndProbe(exec);
      }
      const kept = await alive(exec, before.probe);
      const ls = (await exec(asUser(`${ACPMUX} ls 2>&1 | grep -F chief-probe | head -n 1`), 60_000)).stdout.trim();
      const procs = await unitProcs(exec);
      const detail = `daemon ${before.daemon} -> ${now.daemon}; probe subagent ${before.probe} ${kept ? "still runs" : "ended"} (now ${now.probe}); acpmux ls: ${ls || "no chief-probe"}; unit cgroup: ${procs.join(", ")}`;
      if (!before.probe) throw new Error(`no probe subagent started before the update, so nothing shows ${what}: ${detail}`);
      if (!kept || now.probe !== before.probe) throw new Error(`the probe subagent did not survive ${what}: ${detail}\n${await journal(exec)}`);
      return { value: null, detail };
    };
    await J.step("the probe subagent survives the update's handoff (its acpmux daemon is replaced)", () => probeKept("the handoff"));

    // Rollback: the build before a broken one comes back. `good` is the build the host runs now.
    const good = updated.exe;
    for (const code of [1, 2]) {
      await J.step(`rollback: a build that exits ${code} as host goes back to the build before it`, async () => {
        const facts = await unitFacts(exec);
        const t0 = Date.now();
        const out = await must(exec, asRoot(publishAndUpdate(`${STAGE}/broken-${code}`, brokenBuild(`${STAGE}/broken-${code}`, code))), 300_000);
        const bad = shaLine(out);
        const swapMs = Date.now() - t0;
        const back = await waitHostOn(exec, good, facts.MainPID, bad, 240_000);
        const t1 = Date.now();
        await sleep(15_000);
        const steady = await unitFacts(exec);
        if (steady.ActiveState !== "active" || steady.MainPID !== back.pid) throw new Error(`the previous build did not stay up: ${JSON.stringify(steady)}\n${await journal(exec)}`);
        const again = await must(exec, asRoot(`CMUX_CHIEF_MANIFEST_URL=file://${STAGE}/broken-${code}/manifest.json /usr/local/sbin/cmux-chief-update && readlink -f ${CURRENT}`), 120_000);
        if (!again.includes("this machine rolled back") || again.split("\n").at(-1) !== good) throw new Error(`the updater took the refused build again:\n${again}`);
        const judged = await exec(asRoot(`journalctl -u cmux-chief.service -o cat --no-pager | grep -F 'cmux-chief-update: ' | grep -F ${bad} | tail -n 4`), 30_000);
        return { value: null, detail: `refused ${bad.slice(0, 12)}: swap ${swapMs} ms, swap to the previous build running again ${back.ms + swapMs} ms (pid ${back.pid}), steady 15 s after (t+${Date.now() - t1 + back.ms + swapMs} ms); the updater skips it on its next run; ${judged.stdout.trim().split("\n").join(" | ")}` };
      });
    }

    await J.step("rollback by hand: cmux-chief-update --rollback", async () => {
      const facts = await unitFacts(exec);
      const out = await must(exec, asRoot(publishAndUpdate(`${STAGE}/manual`, goodCopy(`${STAGE}/manual`))), 300_000);
      const next = `/var/lib/cmux-chief/store/${shaLine(out)}/optchat-chief`;
      const on = await waitHostOn(exec, next, facts.MainPID, null, 120_000);
      const t0 = Date.now();
      const back = await must(exec, asRoot("/usr/local/sbin/cmux-chief-update --rollback"), 120_000);
      const up = await waitHostOn(exec, good, on.pid, shaLine(out), 120_000);
      return { value: null, detail: `${back.split("\n")[0]}; host back on the previous build in ${Date.now() - t0} ms (pid ${on.pid} -> ${up.pid})` };
    });
    await J.step("the probe subagent survives the broken builds and the rollbacks", () => probeKept("the rollbacks"));
    await J.step("systemctl stop still ends the host, its acpmux daemon and its agents", async () => {
      const t0 = Date.now();
      await must(exec, asRoot("systemctl stop cmux-chief.service"), 120_000);
      const left = await unitProcs(exec);
      if (left.length) throw new Error(`processes left in cmux-chief.service's cgroup after a stop: ${left.join(", ")}`);
      const probe = await alive(exec, before.probe);
      if (probe) throw new Error(`the probe subagent ${before.probe} still runs after a stop`);
      return { value: null, detail: `stopped in ${Date.now() - t0} ms; nothing left in the unit's cgroup` };
    });
    return J.steps.some((s) => s.status === "fail") ? 1 : 0;
  } catch (e) {
    console.error(`cloud-chief-check: ${String((e as Error)?.message ?? e).slice(0, 2000)}`);
    return 1;
  } finally {
    if (install) {
      await J.step("revoke the install", async () => {
        await api.op("install.revoke", { install }, `chief-check-${run}-revoke`);
        return { value: null, detail: install };
      }).catch(() => undefined);
    }
    if (machine) {
      await J.step("delete machine", async () => {
        await api.deleteMachine(machine, `chief-check-${run}-delete`);
        return { value: null, detail: machine };
      }).catch(() => undefined);
    }
  }
}

process.exit(await main());
