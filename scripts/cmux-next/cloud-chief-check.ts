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
 *      moves `current`, the host hands off between turns, and systemd starts the new build;
 *   6. finally: revoke the install and delete the machine.
 *
 * Usage: bun scripts/cmux-next/cloud-chief-check.ts --binary PATH [--target staging] [--out DIR] [--run ID]
 * Env: CMUX_DOGFOOD_STACK_EMAIL, CMUX_DOGFOOD_STACK_PASSWORD (the staging agent test account), PRODUCT_TEAM (optional).
 */
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Api, directExec, Journey, listAllMachines, passwordSignIn, resolveBackend, STACK, type Exec } from "./cloud-journey";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const CHIEF_DIR = path.join(ROOT, "images/cmux-vm/chief");
const STAGE = "/var/tmp/cmux-chief-check";
const NAME_PREFIX = "cmux-test-chief-";
const SWEEP_AFTER_MS = 3 * 60 * 60 * 1000;
const CHUNK = 3 << 20;
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
      const v = await api.op("cloud.machine.create", { name, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `chief-check-${run}-create`);
      machine = String(v.machine.id);
      const up = await waitRunning(api, machine, 420_000);
      return { value: up, detail: `${name} ${machine}, image ${up?.image?.id ?? up?.image?.name ?? "?"}, daemon ${up?.image?.daemon_version ?? "?"}` };
    });
    void m;
    const exec = directExec(api, machine, J);

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

    await J.step("self-update hands off between turns and starts the new build", async () => {
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
      return { value: null, detail: `${out.split("\n").at(-1)}; pid ${first.MainPID} -> ${facts.MainPID} (${exe}); ${handoff.stdout.trim().split("\n").at(-1)}` };
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
