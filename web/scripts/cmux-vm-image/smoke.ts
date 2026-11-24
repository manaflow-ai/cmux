/**
 * Smoke test for a cmux VM image snapshot (plans/cmux-next/vm-image.md 4.11).
 *
 * Usage (from web/):
 *   bun ../images/cmux-vm/smoke.ts --snapshot <sh-id> --tag <tag> [--clones 5] [--browser-probe]
 *       [--idle-seconds 120] [--out-dir <dir>] [--lock <path>]
 *       [--expect-capabilities <json>] [--team-vm]
 *
 * Creates N clones (cmuxnp-dev-vmimg-<tag>-smoke-<i>) and measures create ->
 * first exec and create -> daemon listening. On two of them it checks: the
 * daemon is bound to this instance; daemon identity and SSH host key differ
 * between the clones (machine-id is reported); the idle-wakeup check
 * (devboxIdleWakeupCheckCommand) and idle CPU-s/min; every program in the
 * lock runs from /opt/cmux/current/bin (`acpmux --version` too: cmux-tui's acpmux name);
 * `acpmux ls --json` starts and lists the machine's acpmux; `cr capabilities --json`; Postgres
 * binaries present with no cluster; docker.socket active and docker.service
 * inactive; no secret patterns (paths and pattern kinds only); /tmp empty;
 * sshd trusts only the bound CA on loopback (empty CA refuses, throwaway CA
 * cert login + scp pass, KRL refuses); display and first-use roles are off and
 * CJK fonts are present (cloud-automation.md 2 and 5).
 * Machine health (machine-health.ts): cmux-machine-health.timer is active, one pass exits 0 and
 * writes valid JSON with no problems, and the guard drop-ins apply (a session-*.scope stand-in gets
 * TasksMax 8192 and MemoryHigh/MemoryMax of about 70%/80% of RAM; the user manager -900).
 * DNS (dns.ts): cmux-dns-check --restart restarts systemd-resolved (and tailscaled when
 * installed), then needs the resolv.conf stub link and a public name resolving (a tailnet name too
 * when logged in to one).
 * IPv6 routes (ipv6-route.ts): no block route over public IPv6 (a dead-IPv6 host's `unreachable 2000::/3`), an IPv6
 * default route, and a route lookup for a public IPv6 address that names a device (RFD 0067 item 5).
 * The daemon handshake (identify.ts) must serve REQUIRED_IMAGE_CAPABILITIES and, with
 * --expect-capabilities, every listed capability; --team-vm also checks /srv/team.
 * The session host stays up 60 s after boot and after one forced rebind, with no legacy or migration
 * error (daemon-uptime.ts). No agent sign-in
 * (~/.claude/.credentials.json, ~/.codex/auth.json) or daemon identity comes from the image.
 * With --agent-probe, one more clone is made the way a team in inference gateway mode makes its machines:
 * with an inline edge rule (coderouter.cmux.internal steered to a platform origin). It must still resolve a
 * public name and the API host, and its bind agent must reach the dev API (edge-rule-*). Production images
 * cloud-native-auto-45ed727f-* (the first on Freestyle's new ubuntu-sm base, cmux#50583) passed every other
 * check here while every gateway-mode create on them never bound (cmux#51612 rolled them back): no clone
 * here carried a rule. The clone also prints its resolver state, which is the guest's own account of a
 * failure (INFO edge-rule-guest).
 * Checks that need the bind agent are reported as PENDING.
 * Every clone is deleted whatever happens.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { CMUX_TUI_SESSION, cmuxTuiRunCommand } from "../../services/vms/drivers/cmuxTuiDaemon";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { DEVBOX_INSTANCE_ID_COMMAND, devboxIdleWakeupCheckCommand, devboxWaitForDaemonCommand } from "../devbox-image-common";
import { GUEST_DIR, TEAM_FILES_ROOT, teamVmDirsCommand, TMP_LEFTOVERS } from "./bake";
import { CREDENTIAL_FILES_CHECK, devTreeCredentialCheckCommand, devTreeUserPaths } from "./dev-tree";
import { daemonIdentifyCommand, parseDaemonIdentify } from "./identify";
import { DNS_SMOKE_COMMAND, dnsCheckProblems } from "./dns";
import { ipv6RouteProblems, ipv6RouteSmokeCommand } from "./ipv6-route";
import { machineHealthSmokeCommand, machineHealthSmokeProblems } from "./machine-health";
import { argValue, createVm, type CreateTlsRule, deleteVm, firstExec, freestyleClient, Ledger, run, sleep, type Vm } from "./guest";
import { bakedPrograms, CURRENT_BIN, DEFAULT_LOCK_PATH, type InputsLock, percentile, readInputsLock, ROLES_MANIFEST_PATH, sq } from "./lock";
import { AGENT_TOOLS_BIN } from "./agent-tools";
import { browserRoleProbe } from "./browser-probe";
import { GH_SHIM } from "./github-auth";
import { API_ORIGINS, HOST_CLI, HOST_JOURNAL, SELF_UPDATE_OFF } from "./host-agent";
import { agentBindProbe, resizeProbe } from "./probes";
import { daemonHoldCommand, daemonUptimeDetail, daemonUptimeProblems, forcedRebindCommand, HOLD_SECONDS } from "./daemon-uptime";
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
const SCAN_ROOTS = "/etc /root /var/lib/cmux /usr/local/etc /opt/cmux/profiles";
/** Per-clone material the supervisor mints after resume; not image content. */
const SCAN_EXCLUDES = ["/etc/ssh/ssh_host_", `${DEVBOX_WORK_HOME}/.local/state/`];

/** `skip`: directories under /home left out with their contents (the dev tree, which devTreeCredentialCheckCommand checks instead). */
export function secretScanCommand(skip: readonly string[] = []): string {
  const prune = skip.length > 0 ? `\\( ${skip.map((p) => `-path ${sq(p)}`).join(" -o ")} \\) -prune -o ` : "";
  const homes = (regex: string) => `find /home -mindepth 1 ${prune}-type f -print0 2>/dev/null | xargs -0 -r grep -IlE -e ${sq(regex)} 2>/dev/null`;
  const lines = SECRET_PATTERNS.map(
    ({ kind, regex }) => `{ grep -rIlE --exclude-dir=proc -e ${sq(regex)} ${SCAN_ROOTS} 2>/dev/null; ${homes(regex)}; } | sed 's#^#${kind} #'`,
  );
  const files = "for f in /root/.git-credentials /root/.netrc /root/.npmrc /home/*/.git-credentials /home/*/.netrc /home/*/.npmrc; do [ -s \"$f\" ] && echo \"credential-file $f\"; done";
  const keys = "for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do [ -s \"$f\" ] && echo \"authorized-keys $f\"; done";
  return `{ ${[...lines, files, keys].join("; ")}; } | grep -vE ${sq(SCAN_EXCLUDES.map((p) => ` ${p.replace(/[.]/g, "\\.")}`).join("|"))} || true`;
}

/** Agent sign-ins a shared image must never carry (checked by existence only, never read). */
export const AGENT_SIGN_IN_LEFTOVERS = [".claude/.credentials.json", ".codex/auth.json"] as const;
const BIND_MARKER = "/etc/cmux/daemon-instance-id";

/**
 * Prints one `kind path` line per leftover; empty output passes. Daemon state and identity count as
 * image content when older than this clone's bind (BIND_MARKER): the bake removes ~/.local/state/cmux
 * and cmux-tui before the snapshot, so any such file there is a leftover; under ~/.cmux (whose bin/
 * the bake links) only identity-shaped names count. The smoke runs on images the bake built from the
 * shared base; a snapshot seeded from a person's own machine never comes through here.
 */
export function imageLeftoversCommand(): string {
  const homes = "/root /home/*";
  const signIns = `for h in ${homes}; do for f in ${AGENT_SIGN_IN_LEFTOVERS.join(" ")}; do [ -e "$h/$f" ] && echo "agent-sign-in $h/$f"; done; done`;
  const state = `for h in ${homes}; do for d in "$h/.local/state/cmux" "$h/.local/state/cmux-tui"; do [ -d "$d" ] && find "$d" -type f ! -newer ${BIND_MARKER} 2>/dev/null | head -10 | sed 's#^#daemon-state #'; done; done`;
  const identity = `for h in ${homes}; do [ -d "$h/.cmux" ] && find "$h/.cmux" -path "$h/.cmux/bin" -prune -o -type f \\( -iname '*identity*' -o -iname '*auth*' -o -iname '*key*' -o -iname '*token*' -o -name machine-id -o -name resource-effect-pepper \\) ! -newer ${BIND_MARKER} -print 2>/dev/null | head -10 | sed 's#^#daemon-identity #'; done`;
  return `{ test -e ${BIND_MARKER} || echo "no-bind-marker ${BIND_MARKER}"; ${signIns}; ${state}; ${identity}; } 2>/dev/null; true`;
}

/**
 * Sets `p` to the path lookup for `command` (type -P: not an alias or function the login shell
 * defines). A user-local alias that resolves to the very file the current profile's entry resolves
 * to reports as that entry: the canonical acpmux user unit needs ~/.local/bin/acpmux, and Ubuntu's
 * ~/.profile puts ~/.local/bin first, yet the alias runs the store's binary. An alias to any other
 * file (say a separately downloaded acpmux) still fails the check, as it should.
 */
export function storeCommandPathSnippet(command: string, currentBin = CURRENT_BIN): string {
  const entry = `${currentBin}/${command}`;
  return `p=$(type -P ${command}); if [ -n "$p" ] && [ "$p" != ${sq(entry)} ] && [ -e ${sq(entry)} ] && real=$(readlink -f "$p") && [ -n "$real" ] && [ "$real" = "$(readlink -f ${sq(entry)})" ]; then p=${sq(entry)}; fi`;
}

/** One login-shell run per command name as the work user; prints `name exit path :: output`. */
export function programChecksCommand(lock: InputsLock): string {
  const rows: string[] = [];
  for (const p of bakedPrograms(lock)) {
    for (const command of Object.keys(p.bin)) {
      const invoke = p.versionArgs.length > 0 ? `${command} ${p.versionArgs.join(" ")} 2>&1` : `test -x "$(type -P ${command})" && echo executable`;
      const script = `cd; ${storeCommandPathSnippet(command)}; out=$(${invoke}); rc=$?; echo "${command} $rc $p :: $(printf '%s' "$out" | head -2 | tr '\\n' ' ')"`;
      rows.push(`sudo -n -u ${DEVBOX_WORK_USER} -H bash -lc ${sq(script)} </dev/null`);
    }
  }
  return rows.join("; ");
}

/**
 * `acpmux ls --json` as the work user from a login shell. The image's `acpmux` is cmux-tui under
 * another name (argv0 dispatch), so this proves the name reaches acpmux, which starts the
 * machine's acpmux daemon (agent launches denied: no harness probe on a smoke clone) and lists
 * its sessions; the daemon is stopped again. Automation agent steps run `acpmux run` this way.
 */
export function acpmuxListCommand(): string {
  // `acpmux ls` never starts a daemon since #28046; start one explicitly (it returns once it accepts clients).
  const script = "export ACPMUX_AGENT_LAUNCH=deny; acpmux daemon start >/dev/null || exit $?; acpmux ls --json; rc=$?; acpmux daemon shutdown >/dev/null 2>&1; exit $rc";
  return `sudo -n -u ${DEVBOX_WORK_USER} -H bash -lc ${sq(script)} </dev/null`;
}

/** Problems with `acpmuxListCommand`'s answer: it must exit 0 with a JSON session list. */
export function acpmuxListProblems(code: number, stdout: string, stderr: string): string[] {
  if (code !== 0) return [`acpmux ls --json: exit ${code}: ${(stderr.trim() || stdout.trim()).slice(-200)}`];
  try {
    const listed = JSON.parse(stdout) as { sessions?: unknown };
    return Array.isArray(listed?.sessions) ? [] : [`acpmux ls --json: no sessions list: ${stdout.trim().slice(0, 200)}`];
  } catch {
    return [`acpmux ls --json: not JSON: ${stdout.trim().slice(0, 200)}`];
  }
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
      // gh resolves to the GitHub shim (github-auth.ts), which runs the store's gh.
      const expected = command === "gh" ? GH_SHIM : `${CURRENT_BIN}/${command}`;
      if (resolved !== expected) problems.push(`${command}: resolves to ${resolved}, expected ${expected}`);
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

export const IDENTITY_PROBE = [
  `echo instance=$(${DEVBOX_INSTANCE_ID_COMMAND})`,
  "echo bound=$(cat /etc/cmux/daemon-instance-id 2>/dev/null)",
  "for i in $(seq 1 150); do [ -n \"$(find /etc/ssh -name ssh_host_ed25519_key.pub -newer /etc/cmux/daemon-instance-id 2>/dev/null)\" ] && break; sleep 0.2; done",
  "echo sshkey=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')",
  `echo daemon=$(cat ${REMOTE_IDENTITY} ${MACHINE_SECRETS} 2>/dev/null | sha256sum | cut -c1-64)`,
  `test -s ${REMOTE_IDENTITY} && echo identity-present=1`,
  "echo machineid=$(cat /etc/machine-id)",
  "echo bootid=$(cat /proc/sys/kernel/random/boot_id)",
  // Clones of one memory snapshot start with the same kernel CRNG state; unless the kernel reseeds on restore
  // (VM generation id) or new entropy arrives, both draw the same bytes.
  "echo urandom=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \\n')",
].join("; ");

export function kv(stdout: string): Record<string, string> {
  return Object.fromEntries(stdout.trim().split("\n").filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
}

type Clone = { vm: Vm; vmId: string; name: string };
type Report = { checks: Record<string, { ok: boolean; detail: string }>; pending: readonly string[]; [key: string]: unknown };

function check(report: Report, name: string, ok: boolean, detail: string): void {
  report.checks[name] = { ok, detail };
  console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${detail.split("\n").slice(0, 6).join(" | ")}`);
}

/**
 * The provider never finished this clone: its create call failed, its guest never answered an exec,
 * or an exec call failed before the guest ran the command. That is the provider's latency or capacity,
 * not the image's, so the smoke replaces the clone instead of failing the image on it.
 */
export class ProviderUnfinished extends Error {
  constructor(readonly clone: Clone | undefined, reason: string) {
    super(reason);
  }
}

/**
 * A restored guest answers its first exec 0.1 to 0.7 s after the create returns. Roll 43953739384's
 * clone 3 took 13.8 s, then its daemon missed the 30 s listen poll but was ready at 145 s: the provider
 * stalled that guest. Such a clone is replaced, and the replacement must pass; a clone that answered
 * promptly and still has no daemon fails the image.
 */
export const PROVIDER_STALL_MS = 10_000;

/** Why a clone whose daemon missed the listen poll is the provider's stall, or undefined when it is the image's. */
export function providerStall(createApiMs: number, createToFirstExecMs: number, listenCode: number): string | undefined {
  const firstExecAfterCreate = createToFirstExecMs - createApiMs;
  if (listenCode === 0 || firstExecAfterCreate <= PROVIDER_STALL_MS) return undefined;
  return `guest stalled: first exec ${firstExecAfterCreate} ms after the create returned, then no daemon listening in the 30 s poll`;
}

const providerUnfinished =(clone: Clone | undefined, step: string) => (error: unknown): never => {
  throw new ProviderUnfinished(clone, `${step}: ${String(error).slice(0, 200)}`);
};

export async function measureClone(fs: ReturnType<typeof freestyleClient>, ledger: Ledger, name: string, snapshotId: string): Promise<{ clone: Clone; row: Record<string, number | string> }> {
  const { vm, vmId, createMs, t0 } = await createVm(fs, ledger, { name, snapshotId }).catch(providerUnfinished(undefined, "create"));
  const clone = { vm, vmId, name };
  const firstExecMs = await firstExec(vm, t0).catch(providerUnfinished(clone, "first exec"));
  // A smoke clone measures the snapshot as baked: the marker goes down with the first command,
  // well before its updater's first check (30 s after cmux host run starts), which reads it
  // again right before it changes anything.
  const listen = await run(vm, `mkdir -p /etc/cmux && touch ${SELF_UPDATE_OFF}; ${LISTEN_POLL}`, 60_000).catch(providerUnfinished(clone, "listen exec"));
  const listeningMs = Date.now() - t0;
  // The poll prints its wait before it judges; without that line the guest never ran it.
  if (!/guest-wait-ms \d+/.test(listen.stdout)) throw new ProviderUnfinished(clone, `listen exec returned ${listen.code} without running: ${listen.stderr.slice(-200)}`);
  const stall = providerStall(createMs, firstExecMs, listen.code);
  if (stall) throw new ProviderUnfinished(clone, stall);
  const ready = await run(vm, devboxWaitForDaemonCommand(60), 90_000).catch(providerUnfinished(clone, "ready exec"));
  const readyMs = Date.now() - t0;
  const guestWaitMs = Number(/guest-wait-ms (\d+)/.exec(listen.stdout)?.[1] ?? Number.NaN);
  // createTo* include the provider's create call; createDoneTo* start when it returned, the image's part.
  return {
    clone,
    row: {
      vmId,
      createApiMs: createMs,
      createToFirstExecMs: firstExecMs,
      createToListeningMs: listen.code === 0 ? listeningMs : -1,
      guestWaitMs,
      createToReadyMs: ready.code === 0 ? readyMs : -1,
      createDoneToFirstExecMs: firstExecMs - createMs,
      createDoneToListeningMs: listen.code === 0 ? listeningMs - createMs : -1,
      createDoneToReadyMs: ready.code === 0 ? readyMs - createMs : -1,
    },
  };
}

/** The domain a gateway-mode create steers (cmux-platform CoderouterEdge.ts), and where this smoke steers it. */
export const EDGE_RULE_DOMAIN = "coderouter.cmux.internal";
export const EDGE_RULE_DESTINATION = "cmux-platform-development.debussy.workers.dev";

/** The create's rule, shaped as freestyleEdgeRules makes it; the header is a marker, never a credential. */
export function edgeRuleCreateRules(): CreateTlsRule[] {
  return [{
    action: "allow",
    domain: EDGE_RULE_DOMAIN,
    source: {},
    destination: { host: EDGE_RULE_DESTINATION, port: 443 },
    transform: [{ headers: { "x-cmux-image-smoke": "edge-rule" } }],
  }];
}

const API_HOST = new URL(API_ORIGINS.dev).host;

/**
 * The guest's resolver state on the edge-rule clone, one `key: value` line per fact (multi-line facts are
 * folded with ` ; `): what it resolves, and what it resolves with. Waits up to 60 s for the provider's
 * injection of the rule's host (/etc/hosts), which runs after the guest starts.
 */
export function edgeRuleGuestCommand(): string {
  const fold = (cmd: string) => `{ ${cmd}; } 2>&1 | tr '\n' ';' | sed 's/;/ ; /g' | cut -c1-1500`;
  const fact = (key: string, cmd: string) => `echo "${key}: $(${fold(cmd)})"`;
  return [
    `for i in $(seq 1 60); do grep -q ${sq(EDGE_RULE_DOMAIN)} /etc/hosts && break; sleep 1; done; echo "hosts-wait-s: $i"`,
    fact("resolve-public", "timeout 10 getent hosts github.com || echo FAILED rc=$?"),
    fact("resolve-api", `timeout 10 getent hosts ${sq(API_HOST)} || echo FAILED rc=$?`),
    fact("resolve-edge", `timeout 10 getent hosts ${sq(EDGE_RULE_DOMAIN)} || echo FAILED rc=$?`),
    fact("edge-https", `timeout 15 curl -sS -o /dev/null -w '%{http_code}' https://${EDGE_RULE_DOMAIN}/ || echo FAILED rc=$?`),
    fact("api-https", `timeout 15 curl -sS -o /dev/null -w '%{http_code}' ${API_ORIGINS.dev}/ || echo FAILED rc=$?`),
    fact("resolv.conf-link", "readlink -f /etc/resolv.conf"),
    fact("resolv.conf", "grep -v '^#' /etc/resolv.conf"),
    fact("resolved.conf.d", "for f in /etc/systemd/resolved.conf.d/* /run/systemd/resolved.conf.d/*; do [ -e \"$f\" ] && echo \"$f\" && grep -v '^#' \"$f\"; done"),
    fact("resolvectl", "timeout 10 resolvectl status --no-pager | grep -E 'Link|Current DNS|DNS Servers|Fallback|DNSSEC|resolv.conf mode|Protocols'"),
    fact("hosts", "grep -v '^#' /etc/hosts"),
    fact("nsswitch-hosts", "grep '^hosts' /etc/nsswitch.conf"),
    fact("routes", "ip -4 route; ip -6 route | head -5"),
    fact("ca-store", "ls -la --time-style=+%s /etc/ssl/certs/ca-certificates.crt; ls /usr/local/share/ca-certificates"),
    fact("resolved-journal", "journalctl -u systemd-resolved --no-pager -o cat -n 25"),
    fact("networkd-journal", "journalctl -u systemd-networkd --no-pager -o cat -n 15"),
    fact("host-journal", `${HOST_JOURNAL} -n 25`),
  ].join("\n");
}

/** The facts edgeRuleGuestCommand printed, by key. */
export function edgeRuleFacts(stdout: string): Record<string, string> {
  const facts: Record<string, string> = {};
  for (const line of stdout.split("\n")) {
    const m = /^([a-z][a-z.-]*): ?(.*)$/.exec(line);
    if (m && !(m[1] in facts)) facts[m[1]] = m[2].trim();
  }
  return facts;
}

/** What is wrong with the edge-rule clone's name resolution: a name that does not resolve. Empty when none. */
export function edgeRuleResolveProblems(facts: Record<string, string>): string[] {
  const problems: string[] = [];
  for (const key of ["resolve-public", "resolve-api"]) {
    const value = facts[key];
    if (!value || /FAILED/.test(value) || !/\d+\.\d+\.\d+\.\d+|[0-9a-f]*:[0-9a-f:]+/i.test(value)) problems.push(`${key}: ${value || "no answer"}`);
  }
  return problems;
}

/**
 * One clone made as a gateway-mode team makes its machines, with an inline edge rule: it must still resolve a
 * public name and the API host, and its bind agent must reach the dev API. Prints the guest's resolver state.
 */
async function edgeRuleChecks(fs: ReturnType<typeof freestyleClient>, ledger: Ledger, tag: string, snapshotId: string, report: Report): Promise<void> {
  const name = `cmuxnp-dev-vmimg-${tag}-smoke-edge`;
  const { vm, vmId, t0 } = await createVm(fs, ledger, { name, snapshotId, tlsRules: edgeRuleCreateRules() });
  try {
    const firstExecMs = await firstExec(vm, t0);
    await run(vm, `mkdir -p /etc/cmux && touch ${SELF_UPDATE_OFF}`);
    const guest = await run(vm, edgeRuleGuestCommand(), 180_000);
    const facts = edgeRuleFacts(guest.stdout);
    report.edgeRule = { vmId, firstExecMs, facts };
    for (const [key, value] of Object.entries(facts)) console.log(`INFO edge-rule-guest ${key}: ${value}`);
    const problems = edgeRuleResolveProblems(facts);
    check(report, "edge-rule-resolve", guest.code === 0 && problems.length === 0, problems.join("\n") || `${facts["resolve-public"]} | ${facts["resolve-api"]} | edge ${facts["resolve-edge"]} ${facts["edge-https"]}`);
    const probe = await agentBindProbe(vm);
    check(report, "edge-rule-bind-probe", probe.ok, probe.detail);
  } finally {
    await deleteVm(vm, vmId, name, ledger);
  }
}

/** Replacement clones a smoke may create for ones the provider never finished. */
export const PROVIDER_RETRIES = 3;

/**
 * Measures one clone, replacing it when the provider never finished it (deleting the unfinished one),
 * at most `retries` times across the whole smoke (`budget.left`). An image failure is never retried.
 */
export async function measureCloneRetrying(measure: (attempt: number) => Promise<{ clone: Clone; row: Record<string, number | string> }>, discard: (clone: Clone) => Promise<void>, budget: { left: number; unfinished: string[] }, backoffMs = 10_000): Promise<{ clone: Clone; row: Record<string, number | string> }> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await measure(attempt);
    } catch (error) {
      if (!(error instanceof ProviderUnfinished)) throw error;
      budget.unfinished.push(error.message);
      if (error.clone) await discard(error.clone).catch((e) => console.error(`could not delete unfinished ${error.clone?.vmId}: ${String(e)}`));
      if (budget.left <= 0) throw new Error(`provider never finished ${budget.unfinished.length} clones: ${budget.unfinished.join("; ")}`);
      budget.left--;
      console.log(`PROVIDER clone unfinished (${error.message}); replacing it, ${budget.left} replacements left`);
      await sleep(backoffMs);
    }
  }
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
  // The scan skips the tree's directories only on an image that has the tree; its credential check runs instead.
  const tree = lock.devTree && (await run(vm, `test -d ${sq(lock.devTree.dir)}`)).code === 0 ? lock.devTree : undefined;
  const secrets = await run(vm, secretScanCommand(tree ? devTreeUserPaths(tree) : []), 240_000);
  check(report, "no-secrets", secrets.stdout.trim() === "", secrets.stdout.trim() || "no pattern matched");
  const credentials = await run(vm, tree ? devTreeCredentialCheckCommand(tree) : `${CREDENTIAL_FILES_CHECK} && echo no-credential-files`);
  check(report, tree ? "dev-tree-no-credentials" : "no-credential-files", credentials.code === 0, credentials.stdout.trim() || credentials.stderr.slice(-300));
  const signIns = await run(vm, imageLeftoversCommand());
  check(report, "no-sign-in-or-identity-leftovers", signIns.code === 0 && signIns.stdout.trim() === "", signIns.stdout.trim() || "no agent sign-in or daemon identity from the image");
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
  const acpmux = await run(vm, acpmuxListCommand(), 120_000);
  const acpmuxProblems = acpmuxListProblems(acpmux.code, acpmux.stdout, acpmux.stderr);
  check(report, "acpmux-ls", acpmuxProblems.length === 0, acpmuxProblems.join("\n") || `acpmux ls --json from ${CURRENT_BIN}: ${acpmux.stdout.trim().slice(0, 120)}`);
  const env = await run(vm, `pid=$(pgrep -f 'cmux-tui server [s]tart' | head -1) && tr '\\0' '\\n' < /proc/$pid/environ | grep -E '^PATH=' && test "$(readlink -f ${DEVBOX_WORK_HOME}/.cmux/bin/cmux-tui)" = "$(readlink -f ${CURRENT_BIN}/cmux-tui)" && echo daemon-from-store`);
  check(report, "daemon-from-store", env.code === 0 && env.stdout.includes(CURRENT_BIN), env.stdout.trim());
}

/** Capabilities every Cloud image must serve (the frontend's browser tabs; bead cx-4l51). */
export const REQUIRED_IMAGE_CAPABILITIES = ["frontend-browser-tabs-v1", "loopback-forward-v1"] as const; // vm-agent-v1 is added by `cmux host cloud daemon-info`, not identify (the bake checks it)

/** The fresh clone's full handshake; with `expected` (the tip's list) none may be missing. */
export async function handshakeChecks(vm: Vm, report: Report, expected?: readonly string[]): Promise<void> {
  const out = await run(vm, daemonIdentifyCommand(), 60_000);
  let served: string[] = [];
  try {
    const identify = parseDaemonIdentify(out.stdout);
    report.daemonIdentify = identify;
    served = identify.capabilities;
  } catch (error) {
    check(report, "daemon-handshake", false, `${String(error)} ${out.stderr.slice(-200)}`);
    return;
  }
  const required = REQUIRED_IMAGE_CAPABILITIES.filter((c) => !served.includes(c));
  check(report, "daemon-handshake", required.length === 0, required.length ? `missing ${required.join(", ")}` : `${served.length} capabilities, build ${String((report.daemonIdentify as { build_commit?: string }).build_commit)}`);
  if (expected) {
    const missing = expected.filter((c) => !served.includes(c));
    report.handshakeMissing = missing;
    check(report, "daemon-handshake-matches-expected", missing.length === 0, missing.length ? `missing ${missing.join(", ")}` : `all ${expected.length} expected capabilities served`);
  }
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
  const roles = await run(vm, rolesOffFontsOnCommand());
  check(report, "roles-off-fonts-on", roles.code === 0, roles.stdout.trim() || roles.stderr.slice(-300));
}

/** The health loop runs clean and the guard drop-ins apply (machine-health.ts). */
/**
 * Roles are parked (no Xvfb running), first-use packages are absent, and CJK fonts are baked. openbox is role
 * display-wm's: a first-use package, except that an agent-tools image bakes it for the desktop session
 * (AGENT_TOOLS_BAKED_ROLES, #44696). The agent tools' cmux-cua wrapper marks that image.
 */
export function rolesOffFontsOnCommand(): string {
  return [
    `test -s ${ROLES_MANIFEST_PATH}`,
    "! pgrep -x Xvfb >/dev/null",
    `{ test -x ${AGENT_TOOLS_BIN}/cmux-cua || ! command -v openbox >/dev/null; }`,
    "! command -v ffmpeg >/dev/null",
    "command -v Xvfb >/dev/null",
    "ls /usr/share/fonts/opentype/noto/ | grep -q '^NotoSansCJK'",
    "echo roles-off-fonts-on",
  ].join(" && ");
}

async function machineHealthChecks(vm: Vm, report: Report): Promise<void> {
  const out = await run(vm, machineHealthSmokeCommand(DEVBOX_WORK_USER), 120_000);
  const problems = machineHealthSmokeProblems(out.stdout);
  report.machineHealth = out.stdout.trim().split("\n");
  check(report, "machine-health", problems.length === 0, problems.join("\n") || out.stdout.trim());
}

/** The resolver survives a restart of systemd-resolved (and tailscaled) and resolves (dns.ts); after the checks above, since it restarts services. */
async function resolverChecks(vm: Vm, report: Report): Promise<void> {
  const dns = await run(vm, DNS_SMOKE_COMMAND, 120_000);
  const problems = dnsCheckProblems(dns.code, dns.stdout);
  report.dns = dns.stdout.trim().split("\n");
  check(report, "dns-resolved-restart", problems.length === 0, problems.join("\n") || dns.stdout.trim());
}

/** Public IPv6 stays routed: no block route over 2000::/3 (a dead-IPv6 host's fix) and an IPv6 default route (ipv6-route.ts, RFD 0067 item 5). */
async function ipv6RouteChecks(vm: Vm, report: Report): Promise<void> {
  const out = await run(vm, ipv6RouteSmokeCommand(), 90_000);
  const problems = ipv6RouteProblems(out.code, out.stdout);
  report.ipv6Routes = out.stdout.trim().split("\n");
  check(report, "ipv6-public-routed", problems.length === 0, problems.join("\n") || out.stdout.trim().split("\n").filter((l) => !l.startsWith("==")).join(" ; "));
}

/**
 * The session host stays up HOLD_SECONDS after boot and again after one forced rebind (daemon-uptime.ts).
 * Last on its clone: the rebind restarts the session host and rewrites the bound id.
 */
async function daemonUptimeChecks(vm: Vm, report: Report): Promise<void> {
  await daemonBootHold(vm, report);
  await daemonRebindHold(vm, report);
}

const HOLD_TIMEOUT_MS = (HOLD_SECONDS + 60) * 1000;

async function daemonBootHold(vm: Vm, report: Report): Promise<void> {
  const boot = await run(vm, daemonHoldCommand(), HOLD_TIMEOUT_MS);
  const bootProblems = daemonUptimeProblems(boot.stdout);
  check(report, "daemon-stays-up", boot.code === 0 && bootProblems.length === 0, bootProblems.join("\n") || daemonUptimeDetail(boot.stdout));
}

/** Last on its clone: the rebind restarts the session host and rewrites the bound id. */
async function daemonRebindHold(vm: Vm, report: Report): Promise<void> {
  const hold = HOLD_TIMEOUT_MS;
  const rebind = await run(vm, forcedRebindCommand(), 120_000);
  const rebound = /^rebound=1$/m.test(rebind.stdout);
  const after = rebound ? await run(vm, daemonHoldCommand(), hold) : undefined;
  const afterProblems = after ? daemonUptimeProblems(after.stdout) : [`forced rebind did not finish: ${rebind.stdout.trim() || rebind.stderr.slice(-200)}`];
  check(report, "daemon-stays-up-after-rebind", after?.code === 0 && afterProblems.length === 0, afterProblems.join("\n") || daemonUptimeDetail(after?.stdout ?? ""));
}

function summarize(rows: Array<Record<string, number | string>>): Record<string, unknown> {
  const pick = (key: string) => rows.map((r) => Number(r[key])).filter((v) => v >= 0 && Number.isFinite(v));
  const stat = (key: string) => {
    const values = pick(key);
    return { n: values.length, p50: percentile(values, 50), p95: percentile(values, 95), raw: values };
  };
  return {
    createApi: stat("createApiMs"),
    createToFirstExec: stat("createToFirstExecMs"),
    createToListening: stat("createToListeningMs"),
    createToReady: stat("createToReadyMs"),
    guestWait: stat("guestWaitMs"),
    createDoneToFirstExec: stat("createDoneToFirstExecMs"),
    createDoneToListening: stat("createDoneToListeningMs"),
    createDoneToReady: stat("createDoneToReadyMs"),
  };
}

/** The provider's part: its create call and the clones it never finished. Reported, never judged. */
export function providerLatency(rows: Array<Record<string, number | string>>, unfinished: readonly string[]): Record<string, unknown> {
  const s = summarize(rows);
  return { createApi: s.createApi, unfinished: unfinished.length, reasons: unfinished };
}

/** The image's part: from the create call's return to the daemon listening and ready. */
export function imageLatency(rows: Array<Record<string, number | string>>): Record<string, unknown> {
  const s = summarize(rows);
  return { createDoneToFirstExec: s.createDoneToFirstExec, createDoneToListening: s.createDoneToListening, createDoneToReady: s.createDoneToReady, guestWait: s.guestWait };
}

/** Every clone the provider finished had its daemon listening and ready. */
export function daemonListening(rows: Array<Record<string, number | string>>): boolean {
  return rows.length > 0 && rows.every((r) => Number(r.createDoneToListeningMs) >= 0 && Number(r.createDoneToReadyMs) >= 0);
}

export async function smoke(options: { snapshotId: string; tag: string; clones: number; idleSeconds: number; outDir: string; lockPath: string; agentProbe?: boolean; resizeProbe?: boolean; browserProbe?: boolean; expectCapabilities?: readonly string[]; teamVm?: boolean }): Promise<Report> {
  mkdirSync(options.outDir, { recursive: true });
  const lock = readInputsLock(options.lockPath);
  const ledger = new Ledger(path.join(options.outDir, "resources.tsv"));
  const fs = freestyleClient();
  const report: Report = { snapshotId: options.snapshotId, checks: {}, pending: PENDING_BIND_AGENT_CHECKS };
  const kept: Clone[] = [];
  const rows: Array<Record<string, number | string>> = [];
  try {
    // One at a time: creating them at once made every create wait about 13 s at the provider (run
    // 42012003953, against about 0.5 s each one by one), and create latency is what this measures.
    const budget = { left: PROVIDER_RETRIES, unfinished: [] as string[] };
    report.providerUnfinished = budget.unfinished;
    for (let i = 1; i <= options.clones; i++) {
      const { clone, row } = await measureCloneRetrying(
        (attempt) => measureClone(fs, ledger, `cmuxnp-dev-vmimg-${options.tag}-smoke-${i}${attempt ? `r${attempt}` : ""}`, options.snapshotId),
        (c) => deleteVm(c.vm, c.vmId, c.name, ledger),
        budget,
      );
      rows.push(row);
      // Track the clone before the extra probe so a refused/failed exec still cleans it up.
      kept.push(clone);
      console.log(`clone ${i} ${clone.vmId}: ${JSON.stringify(row)}`);
      // Clones 1 and 2 carry the identity and idle checks; a third, when there is one, takes the rebind hold.
      if (kept.length > 3) {
        await deleteVm(clone.vm, clone.vmId, clone.name, ledger);
        kept.pop();
      }
    }
    report.clones = rows;
    report.latency = summarize(rows);
    report.providerLatency = providerLatency(rows, budget.unfinished);
    console.log(`INFO provider-latency ${JSON.stringify(report.providerLatency)}`);
    check(report, "daemon-listening", daemonListening(rows), JSON.stringify(imageLatency(rows)));
    const ids = await Promise.all(kept.slice(0, 2).map((c) => run(c.vm, IDENTITY_PROBE, 60_000).then((r) => kv(r.stdout))));
    report.identity = ids.map((id) => ({ instance: id.instance, bound: id.bound, sshkey: id.sshkey, daemon: id.daemon?.slice(0, 12), machineid: id.machineid?.slice(0, 8), bootid: id.bootid?.slice(0, 8) }));
    check(report, "daemon-bound", ids.every((id) => id.instance && id.instance === id.bound && id["identity-present"] === "1"), JSON.stringify(report.identity));
    check(report, "daemon-identity-differs", ids.length === 2 && ids[0].daemon !== ids[1].daemon, `${ids[0]?.daemon?.slice(0, 12)} vs ${ids[1]?.daemon?.slice(0, 12)}`);
    check(report, "ssh-host-key-differs", ids.length === 2 && Boolean(ids[0].sshkey) && ids[0].sshkey !== ids[1].sshkey, `${ids[0]?.sshkey} vs ${ids[1]?.sshkey}`);
    check(report, "urandom-differs", ids.length === 2 && Boolean(ids[0].urandom) && ids[0].urandom !== ids[1].urandom, "16 bytes of /dev/urandom on each clone");
    report.bootIdShared = ids[0]?.bootid === ids[1]?.bootid;
    report.machineIdShared = ids[0]?.machineid === ids[1]?.machineid;
    console.log(`INFO machine-id ${report.machineIdShared ? "SHARED (regenerated by the bind agent, pending)" : "differs"}`);
    // The idle window on clone 1 runs while every check on clone 2 does: they share no machine, and the
    // checks were the serial half of the smoke. The rebind hold runs on clone 3 at the same time when there is
    // one (it restarts that clone's session host, so it goes nowhere near the other checks); with two clones
    // it goes last on clone 2.
    const rebindClone = kept[2];
    const onClone2 = async () => {
      await handshakeChecks(kept[1].vm, report, options.expectCapabilities);
      if (options.teamVm) {
        // The bake's own command is idempotent and verifies owner and mode; on a clone it must change nothing.
        const before = await run(kept[1].vm, `stat -c '%n %U:%G %a' ${TEAM_FILES_ROOT}`);
        const verify = await run(kept[1].vm, teamVmDirsCommand());
        check(report, "team-files-root", before.code === 0 && verify.code === 0 && before.stdout.trim() === verify.stdout.trim().split("\n").at(-1), before.stdout.trim() || before.stderr.slice(-200));
      }
      await functionalChecks(kept[1].vm, lock, report);
      await automationChecks(kept[1].vm, report);
      await machineHealthChecks(kept[1].vm, report);
      await resolverChecks(kept[1].vm, report);
      await ipv6RouteChecks(kept[1].vm, report);
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
      if (rebindClone) await daemonBootHold(kept[1].vm, report);
      else await daemonUptimeChecks(kept[1].vm, report);
    };
    const phases: Record<string, number> = {};
    const timed = (label: string, f: () => Promise<void>) => async () => { const t = Date.now(); await f(); phases[label] = Date.now() - t; };
    // The edge-rule clone needs the dev API for its bind probe, as the agent probe does.
    const edgeRule = async () => {
      await edgeRuleChecks(fs, ledger, options.tag, options.snapshotId, report).catch((error: unknown) => {
        check(report, "edge-rule-resolve", false, `edge-rule clone failed: ${String(error).slice(0, 400)}`);
      });
    };
    await Promise.all([timed("idleClone1Ms", () => idlePhase(kept[0].vm, report, options.idleSeconds))(), timed("checksClone2Ms", onClone2)(),
      ...(rebindClone ? [timed("rebindClone3Ms", () => daemonRebindHold(rebindClone.vm, report))()] : []),
      ...(options.agentProbe ? [timed("edgeRuleCloneMs", edgeRule)()] : [])]);
    report.phasesMs = phases;
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
    // A clone whose worker failed after its create is in the ledger but not in `kept`.
    for (const row of ledger.live().filter((r) => r.kind === "vm" && r.name.startsWith(`cmuxnp-dev-vmimg-${options.tag}-smoke-`))) {
      try {
        await fs.vms.delete(row.id);
        ledger.record(row.id, row.kind, row.name, "deleted");
      } catch (error) {
        console.error(`could not delete ${row.id} (${row.name}): ${String(error)}; the run's cleanup retries it`);
      }
    }
  }
  for (const item of PENDING_BIND_AGENT_CHECKS) console.log(`PENDING ${item}`);
  report.passed = !report.error && Object.values(report.checks).every((c) => c.ok);
  writeFileSync(path.join(options.outDir, `smoke-${options.tag}.json`), `${JSON.stringify(report, null, 2)}\n`);
  console.log(report.passed ? "SMOKE PASSED" : "SMOKE FAILED");
  return report;
}

/** --expect-capabilities <file>: a JSON array of capability names, or a probe/bake JSON with identify.capabilities. */
function expectedCapabilities(file: string | undefined): string[] | undefined {
  if (!file) return undefined;
  const parsed = JSON.parse(readFileSync(file, "utf8")) as unknown;
  const list = Array.isArray(parsed) ? parsed : ((parsed as { identify?: { capabilities?: unknown }; daemonIdentify?: { capabilities?: unknown } }).identify?.capabilities ?? (parsed as { daemonIdentify?: { capabilities?: unknown } }).daemonIdentify?.capabilities);
  if (!Array.isArray(list) || !list.every((c) => typeof c === "string")) throw new Error(`${file}: no capability list`);
  return list as string[];
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
    expectCapabilities: expectedCapabilities(argValue("--expect-capabilities", argv)),
    teamVm: argv.includes("--team-vm"),
  });
  return report.passed ? 0 : 1;
}
