/**
 * Smoke test for a cmux VM image snapshot (plans/cmux-next/vm-image.md 4.11).
 *
 * Usage (from web/):
 *   bun ../images/cmux-vm/smoke.ts --snapshot <sh-id> --tag <tag> [--clones 5] [--browser-probe]
 *       [--idle-seconds 120] [--out-dir <dir>] [--lock <path>]
 *
 * Creates N clones (cmuxnp-dev-vmimg-<tag>-smoke-<i>) and measures create ->
 * first exec and create -> daemon listening. On two of them it checks: the
 * daemon is bound to this instance; daemon identity and SSH host key differ
 * between the clones (machine-id is reported); the idle-wakeup check
 * (devboxIdleWakeupCheckCommand) and idle CPU-s/min; every program in the
 * lock runs from /opt/cmux/current/bin; `cr capabilities --json`; Postgres
 * binaries present with no cluster; docker.socket active and docker.service
 * inactive; no secret patterns (paths and pattern kinds only); /tmp empty;
 * sshd trusts only the bound CA on loopback (empty CA refuses, throwaway CA
 * cert login + scp pass, KRL refuses); display and first-use roles are off and
 * CJK fonts are present (cloud-automation.md 2 and 5).
 * Checks that need the bind agent are reported as PENDING.
 * Every clone is deleted whatever happens.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { CMUX_TUI_SESSION, cmuxTuiRunCommand } from "../../services/vms/drivers/cmuxTuiDaemon";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { DEVBOX_INSTANCE_ID_COMMAND, devboxIdleWakeupCheckCommand, devboxWaitForDaemonCommand } from "../devbox-image-common";
import { GUEST_DIR, TMP_LEFTOVERS } from "./bake";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run, sleep, type Vm } from "./guest";
import { bakedPrograms, CURRENT_BIN, DEFAULT_LOCK_PATH, type InputsLock, percentile, readInputsLock, ROLES_MANIFEST_PATH, sq } from "./lock";
import { browserRoleProbe } from "./browser-probe";
import { HOST_CLI } from "./host-agent";
import { agentBindProbe, resizeProbe } from "./probes";
import { sshdCertSmokeCommand, sshdListenProblems, sshdPolicyProblems } from "./sshd";

const REMOTE_IDENTITY = `${DEVBOX_WORK_HOME}/.local/state/cmux/remote/sessions/${Buffer.from(CMUX_TUI_SESSION).toString("base64url")}/auth/identity.json`;
const MACHINE_SECRETS = `${DEVBOX_WORK_HOME}/.local/state/cmux-tui/sessions/machine-id ${DEVBOX_WORK_HOME}/.local/state/cmux-tui/sessions/resource-effect-pepper`;

/** Checks that belong to the bind agent (another helper builds it); reported, not run. */
export const PENDING_BIND_AGENT_CHECKS = [
  "bind agent: wakes on the resume signal and binds before vms.create returns",
  "bind agent: machine-id regenerated at bind (today's supervisor keeps the snapshot's)",
  "bind agent: first /dev/urandom bytes recorded at bind differ across clones",
  "bind agent: WireGuard key minted per clone",
  "bind agent: store updater applies and rolls back a test manifest",
] as const;

/** Secret pattern kinds; the scan prints only the kind and the path, never the match. */
export const SECRET_PATTERNS: ReadonlyArray<{ kind: string; regex: string }> = [
  { kind: "route-token", regex: "crt_[A-Za-z0-9._-]{8,}" },
  { kind: "coderouter-key", regex: "crk_[A-Za-z0-9._-]{8,}" },
  { kind: "private-key", regex: "-----BEGIN [A-Z ]*PRIVATE KEY-----" },
  { kind: "github-token", regex: "(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})" },
  { kind: "model-api-key", regex: "(sk-ant-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,})" },
  { kind: "aws-access-key", regex: "AKIA[0-9A-Z]{16}" },
  { kind: "npm-auth", regex: "_authToken=" },
];
const SCAN_ROOTS = "/etc /home /root /var/lib/cmux /usr/local/etc /opt/cmux/profiles";
/** Per-clone material the supervisor mints after resume; not image content. */
const SCAN_EXCLUDES = ["/etc/ssh/ssh_host_", `${DEVBOX_WORK_HOME}/.local/state/`];

export function secretScanCommand(): string {
  const lines = SECRET_PATTERNS.map(
    ({ kind, regex }) => `grep -rIlE --exclude-dir=proc -e ${sq(regex)} ${SCAN_ROOTS} 2>/dev/null | sed 's#^#${kind} #'`,
  );
  const files = "for f in /root/.git-credentials /root/.netrc /root/.npmrc /home/*/.git-credentials /home/*/.netrc /home/*/.npmrc; do [ -s \"$f\" ] && echo \"credential-file $f\"; done";
  const keys = "for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do [ -s \"$f\" ] && echo \"authorized-keys $f\"; done";
  return `{ ${[...lines, files, keys].join("; ")}; } | grep -vE ${sq(SCAN_EXCLUDES.map((p) => ` ${p.replace(/[.]/g, "\\.")}`).join("|"))} || true`;
}

/** One login-shell run per command name as the work user; prints `name exit path :: output`. */
export function programChecksCommand(lock: InputsLock): string {
  const rows: string[] = [];
  for (const p of bakedPrograms(lock)) {
    for (const command of Object.keys(p.bin)) {
      const invoke = p.versionArgs.length > 0 ? `${command} ${p.versionArgs.join(" ")} 2>&1` : `test -x "$(type -P ${command})" && echo executable`;
      // type -P: the path lookup, not an alias or function the login shell defines.
      const script = `cd; p=$(type -P ${command}); out=$(${invoke}); rc=$?; echo "${command} $rc $p :: $(printf '%s' "$out" | head -2 | tr '\\n' ' ')"`;
      rows.push(`sudo -n -u ${DEVBOX_WORK_USER} -H bash -lc ${sq(script)} </dev/null`);
    }
  }
  return rows.join("; ");
}

export function programProblems(lock: InputsLock, stdout: string): string[] {
  const problems: string[] = [];
  const lines = new Map(stdout.trim().split("\n").map((line) => [line.split(" ")[0], line] as const));
  for (const p of bakedPrograms(lock)) {
    for (const command of Object.keys(p.bin)) {
      const line = lines.get(command);
      if (!line) {
        problems.push(`${command}: no output`);
        continue;
      }
      const [, rc, resolved] = line.split(" ");
      const output = line.slice(line.indexOf(" :: ") + 4);
      if (rc !== "0") problems.push(`${command}: exit ${rc}: ${output.slice(0, 160)}`);
      if (resolved !== `${CURRENT_BIN}/${command}`) problems.push(`${command}: resolves to ${resolved}, expected ${CURRENT_BIN}/${command}`);
      if (p.expect && !output.includes(p.expect)) problems.push(`${command}: output lacks ${p.expect}: ${output.slice(0, 160)}`);
    }
  }
  return problems;
}

const POSTGRES_CHECK = [
  "/usr/lib/postgresql/17/bin/postgres --version",
  "/usr/lib/postgresql/17/bin/psql --version",
  "test -z \"$(pg_lsclusters -h)\" && echo no-cluster",
  "test ! -e /var/lib/postgresql/17 && echo no-data-dir",
  "test \"$(systemctl is-enabled postgresql.service 2>/dev/null)\" = disabled && echo unit-disabled",
  "! systemctl is-active --quiet postgresql.service && echo unit-inactive",
].join(" && ");

const DOCKER_CHECK = [
  "test \"$(systemctl is-active docker.socket)\" = active && echo socket-active",
  "! systemctl is-active --quiet docker.service && echo service-inactive",
  "! systemctl is-active --quiet containerd.service && echo containerd-inactive",
  "test \"$(systemctl is-enabled docker.service)\" = disabled && echo service-disabled",
].join(" && ");

const LISTEN_POLL = [
  "t0=$(date +%s%N)",
  "n=0; until grep -qi ':0539 00000000000000000000000000000000:0000 0A' /proc/net/tcp6; do n=$((n+1)); [ $(( ($(date +%s%N) - t0) / 1000000 )) -gt 30000 ] && break; done",
  "echo guest-wait-ms $(( ($(date +%s%N) - t0) / 1000000 ))",
  "grep -qi ':0539 00000000000000000000000000000000:0000 0A' /proc/net/tcp6",
].join("; ");

const IDENTITY_PROBE = [
  `echo instance=$(${DEVBOX_INSTANCE_ID_COMMAND})`,
  "echo bound=$(cat /etc/cmux/daemon-instance-id 2>/dev/null)",
  "for i in $(seq 1 150); do [ -n \"$(find /etc/ssh -name ssh_host_ed25519_key.pub -newer /etc/cmux/daemon-instance-id 2>/dev/null)\" ] && break; sleep 0.2; done",
  "echo sshkey=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')",
  `echo daemon=$(cat ${REMOTE_IDENTITY} ${MACHINE_SECRETS} 2>/dev/null | sha256sum | cut -c1-64)`,
  `test -s ${REMOTE_IDENTITY} && echo identity-present=1`,
  "echo machineid=$(cat /etc/machine-id)",
  "echo bootid=$(cat /proc/sys/kernel/random/boot_id)",
].join("; ");

function kv(stdout: string): Record<string, string> {
  return Object.fromEntries(stdout.trim().split("\n").filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
}

type Clone = { vm: Vm; vmId: string; name: string };
type Report = { checks: Record<string, { ok: boolean; detail: string }>; pending: readonly string[]; [key: string]: unknown };

function check(report: Report, name: string, ok: boolean, detail: string): void {
  report.checks[name] = { ok, detail };
  console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${detail.split("\n").slice(0, 6).join(" | ")}`);
}

async function measureClone(fs: ReturnType<typeof freestyleClient>, ledger: Ledger, name: string, snapshotId: string): Promise<{ clone: Clone; row: Record<string, number | string> }> {
  const { vm, vmId, createMs, t0 } = await createVm(fs, ledger, { name, snapshotId });
  const clone = { vm, vmId, name };
  const firstExecMs = await firstExec(vm, t0);
  const listen = await run(vm, LISTEN_POLL, 60_000);
  const listeningMs = Date.now() - t0;
  const ready = await run(vm, devboxWaitForDaemonCommand(60), 90_000);
  const readyMs = Date.now() - t0;
  const guestWaitMs = Number(/guest-wait-ms (\d+)/.exec(listen.stdout)?.[1] ?? Number.NaN);
  return { clone, row: { vmId, createApiMs: createMs, createToFirstExecMs: firstExecMs, createToListeningMs: listen.code === 0 ? listeningMs : -1, guestWaitMs, createToReadyMs: ready.code === 0 ? readyMs : -1 } };
}

async function idlePhase(vm: Vm, report: Report, idleSeconds: number): Promise<void> {
  await vm.fs.writeFile("/root/cmux-sampler.py", readFileSync(path.join(GUEST_DIR, "sampler.py")), { mode: 0o755 });
  const ws = await run(vm, `${cmuxTuiRunCommand(`--session ${CMUX_TUI_SESSION} --json workspace create --name Smoke`)} >/dev/null && sleep 30 && pgrep -f '[_]_terminal-host' | wc -l`, 120_000);
  check(report, "terminal-host-created", ws.code === 0, ws.stdout.trim() || ws.stderr.slice(-300));
  const t0 = Date.now();
  await run(vm, "python3 /root/cmux-sampler.py snap /root/idle-a.json");
  const wake = await run(vm, devboxIdleWakeupCheckCommand(), 180_000);
  check(report, "idle-wakeups", wake.code === 0, wake.stdout.trim().split("\n").filter((l) => /PASS|FAIL|main/.test(l)).join("\n"));
  const remaining = idleSeconds * 1000 - (Date.now() - t0);
  if (remaining > 0) await sleep(remaining);
  await run(vm, "python3 /root/cmux-sampler.py snap /root/idle-b.json");
  const diff = await run(vm, "python3 /root/cmux-sampler.py diff /root/idle-a.json /root/idle-b.json && rm -f /root/cmux-sampler.py /root/idle-a.json /root/idle-b.json");
  const idle = JSON.parse(diff.stdout.trim().split("\n")[0]) as Record<string, unknown>;
  report.idle = idle;
  check(report, "idle-cpu", typeof idle.cpu_s_per_min_all_cpus === "number", `${String(idle.cpu_s_per_min_all_cpus)} CPU-s/min over ${String(idle.window_s)} s (whole VM; includes today's 1 s supervisor poll)`);
}

async function functionalChecks(vm: Vm, lock: InputsLock, report: Report): Promise<void> {
  // Image content only: the running daemon creates its runtime dirs after the clone is bound.
  const tmp = await run(vm, `${TMP_LEFTOVERS} ! -newer /etc/cmux/daemon-instance-id | head -20; echo "runtime: $(${TMP_LEFTOVERS} -newer /etc/cmux/daemon-instance-id | tr '\\n' ' ')"`);
  const leftovers = tmp.stdout.trim().split("\n").filter((line) => line && !line.startsWith("runtime:"));
  check(report, "tmp-empty", leftovers.length === 0, tmp.stdout.trim());
  const secrets = await run(vm, secretScanCommand(), 240_000);
  check(report, "no-secrets", secrets.stdout.trim() === "", secrets.stdout.trim() || "no pattern matched");
  const programs = await run(vm, programChecksCommand(lock), 240_000);
  const problems = programProblems(lock, programs.stdout);
  const ran = programs.stdout.trim().split("\n");
  report.programs = ran;
  check(report, "programs-run", problems.length === 0, problems.join("\n") || `${ran.length} commands ran from ${CURRENT_BIN}`);
  const caps = await run(vm, `sudo -n -u ${DEVBOX_WORK_USER} -H bash -lc 'cr capabilities --json' </dev/null`);
  let capsOk = false;
  try {
    capsOk = caps.code === 0 && typeof JSON.parse(caps.stdout) === "object";
  } catch {
    capsOk = false;
  }
  check(report, "cr-capabilities", capsOk, caps.stdout.trim().slice(0, 300) || caps.stderr.slice(-300));
  const pg = await run(vm, POSTGRES_CHECK);
  check(report, "postgres-binaries-no-cluster", pg.code === 0, pg.stdout.trim() || pg.stderr.slice(-300));
  const docker = await run(vm, DOCKER_CHECK);
  check(report, "docker-socket-only", docker.code === 0, docker.stdout.trim() || docker.stderr.slice(-300));
  const env = await run(vm, `pid=$(pgrep -f 'cmux-tui server [s]tart' | head -1) && tr '\\0' '\\n' < /proc/$pid/environ | grep -E '^PATH=' && test "$(readlink -f ${DEVBOX_WORK_HOME}/.cmux/bin/cmux-tui)" = "$(readlink -f ${CURRENT_BIN}/cmux-tui)" && echo daemon-from-store`);
  check(report, "daemon-from-store", env.code === 0 && env.stdout.includes(CURRENT_BIN), env.stdout.trim());
}

/** sshd trust (LINK-FILES) and roles that stay off (cloud-automation.md 5 and 2). Runs after the secret scan: the cert smoke makes a temp CA. */
async function automationChecks(vm: Vm, report: Report): Promise<void> {
  const effective = await run(vm, `sshd -T -C user=${DEVBOX_WORK_USER},host=localhost,addr=127.0.0.1`);
  const listen = await run(vm, "ss -Hltn");
  const sshd = [...sshdPolicyProblems(effective.stdout, DEVBOX_WORK_USER), ...sshdListenProblems(listen.stdout)];
  check(report, "sshd-ca-only-loopback", effective.code === 0 && sshd.length === 0, sshd.join("\n") || "policy and loopback listen ok");
  const cert = await run(vm, sshdCertSmokeCommand(DEVBOX_WORK_USER), 120_000);
  check(report, "sshd-cert-login", cert.code === 0, cert.stdout.trim() || cert.stderr.slice(-300));
  const probe = await run(vm, `${HOST_CLI} cloud probe-activity`, 60_000);
  const probed = probe.code === 0 && /"capability":true,"connected":true/.test(probe.stdout);
  check(report, "vm-activity-stream", probed, probe.stdout.trim().split("\n").at(-1) || probe.stderr.slice(-300));
  const roles = await run(vm, `test -s ${ROLES_MANIFEST_PATH} && ! pgrep -x Xvfb >/dev/null && ! command -v openbox >/dev/null && ! command -v ffmpeg >/dev/null && command -v Xvfb >/dev/null && ls /usr/share/fonts/opentype/noto/ | grep -q '^NotoSansCJK' && echo roles-off-fonts-on`);
  check(report, "roles-off-fonts-on", roles.code === 0, roles.stdout.trim() || roles.stderr.slice(-300));
}

function summarize(rows: Array<Record<string, number | string>>): Record<string, unknown> {
  const pick = (key: string) => rows.map((r) => Number(r[key])).filter((v) => v >= 0 && Number.isFinite(v));
  const stat = (key: string) => {
    const values = pick(key);
    return { n: values.length, p50: percentile(values, 50), p95: percentile(values, 95), raw: values };
  };
  return { createApi: stat("createApiMs"), createToFirstExec: stat("createToFirstExecMs"), createToListening: stat("createToListeningMs"), createToReady: stat("createToReadyMs"), guestWait: stat("guestWaitMs") };
}

export async function smoke(options: { snapshotId: string; tag: string; clones: number; idleSeconds: number; outDir: string; lockPath: string; agentProbe?: boolean; resizeProbe?: boolean; browserProbe?: boolean }): Promise<Report> {
  mkdirSync(options.outDir, { recursive: true });
  const lock = readInputsLock(options.lockPath);
  const ledger = new Ledger(path.join(options.outDir, "resources.tsv"));
  const fs = freestyleClient();
  const report: Report = { snapshotId: options.snapshotId, checks: {}, pending: PENDING_BIND_AGENT_CHECKS };
  const kept: Clone[] = [];
  const rows: Array<Record<string, number | string>> = [];
  try {
    for (let i = 1; i <= options.clones; i++) {
      const name = `cmuxnp-dev-vmimg-${options.tag}-smoke-${i}`;
      const { clone, row } = await measureClone(fs, ledger, name, options.snapshotId);
      rows.push(row);
      console.log(`clone ${i} ${clone.vmId}: ${JSON.stringify(row)}`);
      if (kept.length < 2) kept.push(clone);
      else await deleteVm(clone.vm, clone.vmId, clone.name, ledger);
    }
    report.clones = rows;
    report.latency = summarize(rows);
    check(report, "daemon-listening", rows.every((r) => Number(r.createToListeningMs) > 0 && Number(r.createToReadyMs) > 0), JSON.stringify(report.latency));
    const ids = await Promise.all(kept.map((c) => run(c.vm, IDENTITY_PROBE, 60_000).then((r) => kv(r.stdout))));
    report.identity = ids.map((id) => ({ instance: id.instance, bound: id.bound, sshkey: id.sshkey, daemon: id.daemon?.slice(0, 12), machineid: id.machineid?.slice(0, 8), bootid: id.bootid?.slice(0, 8) }));
    check(report, "daemon-bound", ids.every((id) => id.instance && id.instance === id.bound && id["identity-present"] === "1"), JSON.stringify(report.identity));
    check(report, "daemon-identity-differs", ids.length === 2 && ids[0].daemon !== ids[1].daemon, `${ids[0]?.daemon?.slice(0, 12)} vs ${ids[1]?.daemon?.slice(0, 12)}`);
    check(report, "ssh-host-key-differs", ids.length === 2 && Boolean(ids[0].sshkey) && ids[0].sshkey !== ids[1].sshkey, `${ids[0]?.sshkey} vs ${ids[1]?.sshkey}`);
    report.machineIdShared = ids[0]?.machineid === ids[1]?.machineid;
    console.log(`INFO machine-id ${report.machineIdShared ? "SHARED (regenerated by the bind agent, pending)" : "differs"}`);
    await functionalChecks(kept[1].vm, lock, report);
    await automationChecks(kept[1].vm, report);
    if (options.agentProbe) {
      const probe = await agentBindProbe(kept[1].vm);
      check(report, "vm-agent-bind-probe", probe.ok, probe.detail);
    }
    if (options.browserProbe) {
      // After the roles-off checks: the probe installs the browser role on this clone.
      const browser = await browserRoleProbe(kept[1].vm, { lockPath: options.lockPath });
      report.browser = { timings: browser.timings, idle: browser.idle, pending: browser.pending };
      for (const [name, c] of Object.entries(browser.checks)) check(report, `browser-${name}`.replace(/^browser-browser-/, "browser-"), c.ok, c.detail);
    }
    await idlePhase(kept[0].vm, report, options.idleSeconds);
    if (options.resizeProbe) {
      report.resize = await resizeProbe(kept[0].vm);
      const after = JSON.parse(String((report.resize as Record<string, unknown>).after)) as { cpu: number; memoryMb: number; rootMb: number };
      check(report, "resize-sm-to-md", after.cpu >= 4 && after.memoryMb >= 7000 && after.rootMb >= 32768 * 0.85, JSON.stringify(report.resize));
    }
  } catch (error) {
    report.error = String(error);
    console.error(`SMOKE FAILED: ${report.error}`);
  } finally {
    for (const c of kept) await deleteVm(c.vm, c.vmId, c.name, ledger);
  }
  for (const item of PENDING_BIND_AGENT_CHECKS) console.log(`PENDING ${item}`);
  report.passed = !report.error && Object.values(report.checks).every((c) => c.ok);
  writeFileSync(path.join(options.outDir, `smoke-${options.tag}.json`), `${JSON.stringify(report, null, 2)}\n`);
  console.log(report.passed ? "SMOKE PASSED" : "SMOKE FAILED");
  return report;
}

export async function main(argv = process.argv): Promise<number> {
  const snapshotId = argValue("--snapshot", argv);
  const tag = argValue("--tag", argv);
  if (!snapshotId?.startsWith("sh-") || !tag) throw new Error("usage: smoke.ts --snapshot <sh-id> --tag <tag> [--clones 5] [--idle-seconds 120] [--out-dir <dir>]");
  const report = await smoke({
    snapshotId,
    tag,
    clones: Number(argValue("--clones", argv) ?? 5),
    idleSeconds: Number(argValue("--idle-seconds", argv) ?? 120),
    outDir: path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${tag}`),
    lockPath: path.resolve(argValue("--lock", argv) ?? DEFAULT_LOCK_PATH),
    agentProbe: argv.includes("--agent-probe"),
    resizeProbe: argv.includes("--resize-probe"),
    browserProbe: argv.includes("--browser-probe"),
  });
  return report.passed ? 0 : 1;
}
