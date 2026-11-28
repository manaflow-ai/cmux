#!/usr/bin/env bun
/**
 * The end-to-end encrypted cmux vault on staging with no Mac (cmuxterm-hq docs/design/e2e-vault.md): a Cloud machine
 * created after the value was kept receives it, sealed by a CLI device standing in for the phone, and a device that
 * was never approved cannot read it. Run by .github/workflows/vault-e2e.yml.
 *
 *   bun scripts/cmux-next/vault-e2e.ts --cmux PATH --out DIR [--run ID] [--backend staging]
 *
 * `--cmux` is a Linux x86_64 cmux-tui (named `cmux`) built with the machine side (cmux#56879, cmux-host's vault pull):
 * it is the CLI device here and, copied to the machine, the machine's `cmux host run`.
 *
 * Steps, each a real command:
 *   1. Sign in as the staging agent test account (CMUX_DOGFOOD_STACK_EMAIL / _PASSWORD), `user.ensure`.
 *   2. Reset that account's personal vault through the person routes (every item, then every device), so the CLI
 *      device below is the first device of an empty vault.
 *   3. Device A (its own HOME, key in a 0600 file: CMUX_VAULT_DEVICE_FILE=1): `cmux vault on --json` (active, first
 *      device), then `cmux vault set VAULT_E2E_NONCE --json` with a random nonce on stdin.
 *   4. Create `cmux-test-vault-<tag>` (no Mac anywhere), copy `--cmux` to it through fs/write, and run cmux-host from
 *      it: a systemd drop-in replaces the unit's ExecStart with that binary, then `systemctl restart cmux-host`.
 *   5. Device A: `cmux vault sync --json` (seals the value to the machine's daemon key).
 *   6. On the machine, within 150 s: `bash -lc 'printenv VAULT_E2E_NONCE' | sha256sum` equals the nonce's hash (the
 *      comparison runs on the machine; only the verdict comes back), and the exec output never holds the value.
 *   7. Device B (another HOME): `cmux vault on --json` answers pending; the server gives B no wrap of the vault key;
 *      `cmux vault sync` from B fails.
 *   8. Cleanup, pass or fail: `cmux vault rm`, the vault reset again, the machine deleted (also on a signal), and
 *      machines of an earlier run of this script over an hour old.
 *
 * The vault origin is the API's `/v1/cloud/vault` when cmux-api forwards it (cmux#56768), else cmux-platform staging
 * directly for the device side; the machine side always pulls through the API its host is bound to. No token, password
 * or value is printed: every line goes through scrub() with them listed, and values reach the CLI on stdin only.
 */
import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { gzipSync } from "node:zlib";
import { Api, Journey, STACK, directExec, listAllMachines, passwordSignIn, resolveBackend, scrub } from "./cloud-journey.ts";

const argValue = (flag: string, argv: string[]) => { const i = argv.indexOf(flag); return i >= 0 ? argv[i + 1] : undefined; };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const NAME_PREFIX = "cmux-test-vault-";
const HOME = "/home/cmux";
const DIR = `${HOME}/.cmux-vault-e2e`;
const HOST_BIN = "/usr/local/lib/cmux-vault-e2e/cmux";
const DROP_IN = "/etc/systemd/system/cmux-host.service.d/zz-vault-e2e.conf";
const SECRET_NAME = "VAULT_E2E_NONCE";
const STAGING_PLATFORM = "https://cmux-platform-staging.debussy.workers.dev";
/** Under FILE_MAX_BYTES (cmux-platform MachineGuest.ts, 8 MiB) once base64 is decoded. */
const PIECE = 6 * 1024 * 1024;
const CREATE_BUDGET_MS = 240_000;
const VAULT = "personal";

type Cli = { code: number; json: any; stderr: string };

export async function main(argv = process.argv.slice(2)): Promise<number> {
  const backend = resolveBackend(argValue("--backend", argv) ?? "staging");
  if (backend.name === "prod" || backend.stack === "prod") throw new Error("staging only");
  const cmux = argValue("--cmux", argv);
  if (!cmux) throw new Error("--cmux PATH (a Linux cmux-tui with cmux#56879, named cmux)");
  const outDir = path.resolve(argValue("--out", argv) ?? "vault-e2e");
  mkdirSync(outDir, { recursive: true });
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("no agent test account: CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD");
  const runId = (argValue("--run", argv) ?? "local").replace(/[^a-z0-9]/gi, "").toLowerCase();
  const tag = `${Date.now().toString(36)}-${runId}`;
  const J = new Journey(backend, outDir, { tag });
  const nonce = `e2e-${randomBytes(24).toString("base64url")}`;
  const want = createHash("sha256").update(`${nonce}\n`).digest("hex");
  J.secrets.push(password, nonce);
  const say = (line: string) => console.log(scrub(line, J.secrets));
  const report: Record<string, unknown> = { backend: backend.name, tag, name: SECRET_NAME, checks: {} as Record<string, string> };
  const checks = report.checks as Record<string, string>;
  const api = new Api(backend.api);
  let vaultApi = new Api(backend.api);
  let signedAt = 0;
  const signIn = async () => {
    const s = await passwordSignIn(STACK[backend.stack], email, password);
    J.secrets.push(s.access, s.refresh);
    api.bearer = vaultApi.bearer = s.access;
    signedAt = Date.now();
  };
  const fresh = async () => { if (Date.now() - signedAt > 4 * 60_000) await signIn(); };

  const scratch = mkdtempSync(path.join(process.env.RUNNER_TEMP ?? os.tmpdir(), "vault-e2e-"));
  const homeA = path.join(scratch, "device-a");
  const homeB = path.join(scratch, "device-b");
  for (const h of [homeA, homeB]) mkdirSync(h, { recursive: true, mode: 0o700 });
  const cli = async (home: string, args: string[], stdin = ""): Promise<Cli> => {
    await fresh();
    const r = spawnSync(cmux, ["vault", ...args, "--json"], {
      input: stdin,
      encoding: "utf8",
      timeout: 120_000,
      env: {
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        HOME: home,
        CMUX_CLOUD_ACCESS_TOKEN: api.bearer,
        CMUX_CLOUD_API: vaultApi.origin,
        CMUX_VAULT_DEVICE_FILE: "1",
        CMUX_NEXT_CLOUD_SECRETS_FILE: path.join(home, "cloud-secrets.json"),
      },
    });
    let json: any = null;
    try { json = JSON.parse(String(r.stdout ?? "").trim() || "null"); } catch { json = { raw: scrub(String(r.stdout).slice(0, 400), J.secrets) }; }
    if (String(r.stdout ?? "").includes(nonce) || String(r.stderr ?? "").includes(nonce)) checks.cli_never_printed_value = "FAIL";
    return { code: r.status ?? 128, json, stderr: scrub(String(r.stderr ?? "").slice(-600), J.secrets) };
  };
  const show = (c: Cli) => scrub(`exit ${c.code} ${JSON.stringify(c.json).slice(0, 500)} ${c.stderr}`, J.secrets);

  /** Every item, then every device, through the person routes: an empty vault, so the next device is the first. */
  const reset = async () => {
    await fresh();
    const snap = await vaultApi.raw("GET", `/v1/cloud/vault?vault=${VAULT}`);
    if (snap.status !== 200) throw new Error(`vault snapshot: HTTP ${snap.status} ${JSON.stringify(snap.body?.error ?? snap.body).slice(0, 200)}`);
    const v = snap.body?.value ?? snap.body;
    let items = 0, devices = 0;
    for (const it of v?.items ?? []) {
      const r = await vaultApi.raw("DELETE", `/v1/cloud/vault/items/${encodeURIComponent(it.id)}?vault=${VAULT}&expectedRevision=${it.revision}`);
      if (r.status >= 300) throw new Error(`item delete: HTTP ${r.status} ${JSON.stringify(r.body?.error ?? r.body).slice(0, 200)}`);
      items++;
    }
    for (const d of v?.devices ?? []) {
      const r = await vaultApi.raw("DELETE", `/v1/cloud/vault/devices/${encodeURIComponent(d.id)}?vault=${VAULT}`);
      if (r.status >= 300) throw new Error(`device delete: HTTP ${r.status} ${JSON.stringify(r.body?.error ?? r.body).slice(0, 200)}`);
      devices++;
    }
    return `${items} item(s), ${devices} device(s) removed`;
  };

  let machine: string | null = null;
  const remove = async (id: string) => {
    try { await api.deleteMachine(id, `${tag}-delete-${id}`); say(`deleted ${id}`); }
    catch (e) { say(`delete ${id}: ${(e as Error).message}`); }
  };
  const onSignal = async () => { if (machine) await remove(machine); process.exit(143); };
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  const write = (verdict: string) => {
    writeFileSync(path.join(outDir, "proof.json"), `${scrub(JSON.stringify({ ...report, steps: J.steps, verdict }, null, 2), J.secrets)}\n`);
    const rows = J.steps.map((s) => `| ${s.step} | ${s.status} | ${Math.round(s.ms / 100) / 10} s | ${String(s.detail ?? "").replace(/\|/g, "/").replace(/\s+/g, " ").slice(0, 300)} |`);
    writeFileSync(path.join(outDir, "summary.md"), scrub(`## cmux vault, no Mac (${backend.name})\n\nmachine \`${report.machine ?? "?"}\` (\`${NAME_PREFIX}${tag}\`), vault origin \`${report.vaultOrigin ?? "?"}\`, deleted: ${report.deleted ?? "?"}\n\n**${verdict}**\n\n| step | status | time | detail |\n|---|---|---|---|\n${rows.join("\n")}\n`, J.secrets));
  };
  let verdict = "FAIL: did not finish";
  let set = false;
  try {
    await J.step("sign in (agent test account)", async () => { await signIn(); return { value: null, detail: "password" }; });
    await J.step("user.ensure", async () => ({ value: await api.op("user.ensure", {}, `${tag}-ensure`), detail: "ok" }));
    await J.step("vault origin", async () => {
      const r = await api.raw("GET", `/v1/cloud/vault?vault=${VAULT}`);
      const forwarded = r.status === 200 || typeof r.body?.ok === "boolean";
      report.forwarder = forwarded ? "cmux-api forwards /v1/cloud/vault" : `cmux-api answered ${r.status} without a body (cmux#56768 not deployed)`;
      if (!forwarded) vaultApi = new Api(STAGING_PLATFORM);
      vaultApi.bearer = api.bearer;
      report.vaultOrigin = vaultApi.origin;
      return { value: null, detail: `${vaultApi.origin}; ${report.forwarder}` };
    });
    await J.step("reset the account's personal vault", async () => ({ value: null, detail: await reset() }));
    const a = await J.step("device A: cmux vault on (first device)", async () => {
      const c = await cli(homeA, ["on"]);
      if (c.code !== 0 || c.json?.state !== "active") throw new Error(show(c));
      return { value: c.json, detail: `state ${c.json.state}, device ${c.json.deviceId}, epoch ${c.json.epoch}` };
    });
    await J.step(`device A: cmux vault set ${SECRET_NAME} (nonce on stdin)`, async () => {
      const c = await cli(homeA, ["set", SECRET_NAME], `${nonce}\n`);
      if (c.code !== 0) throw new Error(show(c));
      set = true;
      return { value: null, detail: `revision ${c.json?.revision}, scope ${c.json?.scope}` };
    });

    // Earlier runs cut off before their delete: their exact name, over an hour old.
    const listed = await listAllMachines((p) => api.read("cloud.machine.list", p));
    report.accountMachines = listed.filter((m) => m.status !== "deleted" && m.status !== "deleting").length;
    say(`the account has ${report.accountMachines} live machine(s)`);
    for (const m of listed) {
      const t = new RegExp(`^${NAME_PREFIX}([0-9a-z]+)-[0-9a-z]+$`).exec(String(m?.name ?? ""));
      const at = t ? parseInt(t[1], 36) : NaN;
      if (Number.isFinite(at) && at > Date.UTC(2026, 0, 1) && Date.now() - at > 3_600_000 && m.status !== "deleted" && m.status !== "deleting") await remove(String(m.id));
    }
    machine = await J.step("create machine (no Mac)", async () => {
      await fresh();
      const t0 = Date.now();
      let created: any;
      for (let tries = 1; ; tries++) {
        try {
          created = await api.op("cloud.machine.create", { name: `${NAME_PREFIX}${tag}`, size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `${tag}-create`);
          break;
        } catch (e) {
          const timedOut = (e as Error)?.name === "TimeoutError" || /operation timed out/i.test(String((e as Error)?.message));
          if (!timedOut || Date.now() - t0 > CREATE_BUDGET_MS) throw e;
        }
      }
      const id = typeof created?.machine === "string" ? created.machine : created?.machine?.id ?? created?.machine_id ?? created?.id;
      if (typeof id !== "string") throw new Error("create answered no machine id");
      return { value: id, detail: id };
    });
    report.machine = machine;
    await J.step("machine running", async () => {
      const t0 = Date.now();
      for (;;) {
        await fresh();
        const m = await api.read("cloud.machine.get", { machine }).catch(() => null);
        if (m?.status === "running" && m?.host) return { value: null, detail: `${Math.round((Date.now() - t0) / 1000)} s` };
        if (m?.status === "failed") throw new Error("machine failed");
        if (Date.now() - t0 > 300_000) throw new Error(`still ${m?.status} after 300 s`);
        await sleep(2000);
      }
    });
    const exec = directExec(api, machine, J);
    const run = async (command: string, timeoutMs = 120_000) => {
      await fresh();
      const r = await exec(`export HOME=${HOME}; cd "$HOME"; ${command}`, timeoutMs);
      if (r.stdout.includes(nonce) || r.stderr.includes(nonce)) checks.exec_never_printed_value = "FAIL";
      return { ...r, stdout: scrub(r.stdout, J.secrets), stderr: scrub(r.stderr, J.secrets) };
    };
    // A machine with no exec in flight pauses on its own (run 45679791255: 503 vm_unavailable at fs/write piece 10,
    // 286 s into the copy). One long exec keeps it running for the rest of the run; the delete ends it.
    void exec("sleep 1500", 1_500_000).catch(() => {});
    await sleep(3000);
    await J.step("run cmux-host from the PR's cmux on the machine", async () => {
      const data = gzipSync(readFileSync(cmux), { level: 9 });
      const n = Math.ceil(data.length / PIECE);
      await run(`rm -rf ${DIR} && mkdir -p ${DIR}/parts && chmod 700 ${DIR}`);
      let retried = 0;
      for (let i = 0; i < n; i++) {
        for (let tries = 1; ; tries++) {
          await fresh();
          const p0 = Date.now();
          // A write that never answers throws (AbortSignal.timeout): run 45827353873 lost the whole step to one hung
          // piece ("The operation timed out." at 524 s). A piece is idempotent (same path, same bytes): send it again.
          const w = await api.raw("POST", `/v1/cloud/machines/${machine}/fs/write`, { path: `${DIR}/parts/${String(i).padStart(3, "0")}`, dataBase64: Buffer.from(data.subarray(i * PIECE, (i + 1) * PIECE)).toString("base64"), mode: 0o644 }, 120_000)
            .catch((e: Error) => ({ status: 0, body: { error: { code: `${e?.name ?? "Error"}: ${e?.message ?? e}` } } }) as { status: number; body: any });
          say(`fs/write piece ${i + 1}/${n}: HTTP ${w.status} in ${Math.round((Date.now() - p0) / 1000)} s (try ${tries})`);
          if (w.status >= 200 && w.status < 300 && w.body?.ok !== false) break;
          if (tries >= 4 || (w.status !== 0 && w.status < 500 && w.status !== 409)) throw new Error(`fs/write piece ${i}/${n}: HTTP ${w.status} ${String(w.body?.error?.code ?? "")} (try ${tries})`);
          retried++;
          await sleep(5000 * tries);
        }
      }
      say(`copied ${n} piece(s), ${retried} retried; swapping cmux-host`);
      const r = await run(
        `set -e; cat ${DIR}/parts/* | gunzip > ${DIR}/cmux; rm -rf ${DIR}/parts; chmod 755 ${DIR}/cmux; ` +
        `before=$(systemctl show -p ExecStart --value cmux-host.service | sed -n 's/.*path=\\([^ ;]*\\).*/\\1/p'); echo "before=$before"; ` +
        `sudo -n install -D -m 755 ${DIR}/cmux ${HOST_BIN}; sudo -n touch /etc/cmux/no-self-update; sudo -n mkdir -p $(dirname ${DROP_IN}); ` +
        `printf '[Service]\\nExecStart=\\nExecStart=${HOST_BIN} host run --mode system\\n' | sudo -n tee ${DROP_IN} >/dev/null; ` +
        `sudo -n systemctl daemon-reload; sudo -n systemctl restart cmux-host.service; sleep 5; ` +
        `echo "active=$(systemctl is-active cmux-host.service)"; pid=$(systemctl show -p MainPID --value cmux-host.service); ` +
        `echo "running=$(sudo -n readlink /proc/$pid/exe)"; ${HOST_BIN} --version 2>&1 | head -1; ` +
        `echo "glibc=$(ldd --version 2>&1 | head -1)"`, 240_000).catch((e: Error) => { throw new Error(`swap (after copying ${n} piece(s)): ${e?.message ?? e}`); });
      if (r.code !== 0 || !r.stdout.includes(`running=${HOST_BIN}`) || !r.stdout.includes("active=active")) throw new Error(`swap: exit ${r.code} ${(r.stdout + r.stderr).trim().slice(-600)}`);
      report.host = r.stdout.trim();
      return { value: null, detail: `${data.length} gz bytes in ${n} piece(s); ${r.stdout.trim().replace(/\n/g, "; ").slice(0, 400)}` };
    });
    await J.step("device A: cmux vault sync (stands in for the phone)", async () => {
      const c = await cli(homeA, ["sync"]);
      if (c.code !== 0) throw new Error(show(c));
      const row = (c.json?.machines ?? []).find((m: any) => m.id === machine);
      // cmux-platform VaultMachines.ts lists at most VAULT_MACHINES_MAX (64) machines, in row order: an account with
      // more never sees a new one (run 45722765202).
      if (!row) throw new Error(`sync did not reach ${machine}: the vault listed ${(c.json?.machines ?? []).length} machine(s) (cmux-platform caps the list at 64)`);
      report.sync = row;
      return { value: null, detail: `${machine}: ${row.outcome} (${(row.names ?? []).join(", ")}); ${(c.json?.machines ?? []).length} machine(s) in all` };
    });
    await J.step(`machine: bash -lc 'printenv ${SECRET_NAME}' matches (hash compared on the machine)`, async () => {
      const r = await run(
        `want=${want}; got=; for i in $(seq 1 75); do got=$(bash -lc 'printenv ${SECRET_NAME}' 2>/dev/null | sha256sum | cut -d' ' -f1); ` +
        `[ "$got" = "$want" ] && { echo "match after $((i*2)) s"; break; }; sleep 2; done; [ "$got" = "$want" ] || echo nomatch; ` +
        `ls -l $HOME/.config/cmux/machine-secrets.env /etc/profile.d/cmux-vault.sh 2>&1 | awk '{print $1, $3, $NF}'; ` +
        `echo ==JOURNAL==; sudo -n journalctl -u cmux-host.service -o cat --no-pager 2>/dev/null | grep -F 'vault:' | tail -8`, 200_000);
      report.machine_check = r.stdout.trim();
      if (!/^match after/m.test(r.stdout)) throw new Error(`no match: ${r.stdout.trim().slice(-800)}`);
      return { value: null, detail: r.stdout.trim().replace(/\n/g, "; ").slice(0, 600) };
    });
    checks.machine_got_value = "pass";
    await J.step("device B (never approved): cannot read the vault", async () => {
      const on = await cli(homeB, ["on"]);
      if (on.code !== 0 || on.json?.state !== "pending") throw new Error(`B on: ${show(on)}`);
      const id = String(on.json?.deviceId ?? "");
      await fresh();
      const snap = await vaultApi.raw("GET", `/v1/cloud/vault?vault=${VAULT}`, undefined, 30_000, { "x-cmux-vault-device": id });
      const v = snap.body?.value ?? snap.body;
      if (snap.status !== 200) throw new Error(`B snapshot: HTTP ${snap.status}`);
      if (v?.wrap) throw new Error("the server gave the pending device a wrap of the vault key");
      const sync = await cli(homeB, ["sync"]);
      if (sync.code === 0) throw new Error(`B's sync succeeded: ${show(sync)}`);
      return { value: null, detail: `B ${id} pending, no wrap served, its sync refused (${String(sync.json?.error?.code ?? sync.json?.code ?? sync.stderr).slice(0, 120)})` };
    });
    checks.unapproved_device_blocked = "pass";
    checks.cli_never_printed_value ??= "pass";
    checks.exec_never_printed_value ??= "pass";
    const ok = Object.values(checks).every((c) => c === "pass");
    verdict = ok
      ? `PASS: ${machine}, created after the value was kept and with no Mac, read ${SECRET_NAME} in a login shell; an unapproved device could not read it`
      : `FAIL: ${JSON.stringify(checks)}`;
    return ok ? 0 : 1;
  } catch (e) {
    verdict = `FAIL: ${scrub(String((e as Error)?.message ?? e), J.secrets).slice(0, 600)}`;
    return 1;
  } finally {
    if (set) { const c = await cli(homeA, ["rm", SECRET_NAME]).catch(() => null); say(`vault rm: ${c ? `exit ${c.code}` : "failed"}`); }
    await reset().then((d) => say(`vault reset: ${d}`), (e) => say(`vault reset: ${(e as Error).message}`));
    if (machine) {
      await fresh().catch(() => {});
      await remove(machine);
      const m = await api.read("cloud.machine.get", { machine }).catch(() => null);
      report.deleted = !m || m.status === "deleted" || m.status === "deleting";
    }
    rmSync(scratch, { recursive: true, force: true });
    write(verdict);
    say(verdict);
  }
}

if (import.meta.main) main().then((c) => process.exit(c), (e) => { console.error(String((e as Error).message ?? e)); process.exit(1); });
