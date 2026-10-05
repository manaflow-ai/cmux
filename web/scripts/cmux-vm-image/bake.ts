/**
 * Bake the cmux VM image from images/cmux-vm/inputs.lock.json alone
 * (plans/cmux-next/vm-image.md sections 4.1 to 4.10).
 *
 * Usage (from web/):
 *   bun ../images/cmux-vm/bake.ts --tag <tag> [--out-dir <dir>] [--lock <path>]
 *       [--update-lock] [--keep-builder] [--promotion]
 *
 * - L0: refuses a base whose fingerprint (kernel release, sha256 of the sorted
 *   dpkg list) differs from the lock, unless --update-lock rewrites it (a base
 *   change is then a reviewed diff of the lock). Base runtimes, base packages
 *   and base npm globals must match the lock too.
 * - L1: apt from the dated snapshot mirror and PGDG's archive, every package at
 *   the locked version, and the installed set must equal the lock exactly.
 *   PostgreSQL 17 binaries only (no cluster, units disabled). Docker is
 *   socket-activated. The daily apt, man-db and motd timers are disabled.
 * - L2: every program into /opt/cmux/store/<sha256>/ (download sha256 + size
 *   checked), profile generation 1, /opt/cmux/current/bin on PATH.
 * - The daemon still runs under today's cmux-devbox-boot supervisor (the
 *   bind agent replaces it later), whose binary path is linked into the store.
 * - Model-plane env and the coderouter CLI point at the VM edge alias; no
 *   login and no token in the image.
 * - SBOM (syft, pinned) and a file-hash manifest are downloaded next to the
 *   result JSON. The page cache is dropped and the bind path re-read before the
 *   snapshot.
 *
 * Every VM and snapshot is named cmuxnp-dev-vmimg-<tag> unless --promotion
 * (unused for now) and is recorded in <out-dir>/resources.tsv the moment it
 * exists. The builder is deleted whatever happens.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { renderVmGuestModelPlaneEnvFile, VM_GUEST_MODEL_PLANE_ENV_PATH, vmEdgeAliasDomain, vmGuestModelPlaneEnv } from "../../services/coderouter/vmGuestEnv";
import { cmuxTuiInstallCommand, cmuxTuiLayoutSelector, cmuxTuiPinCheckCommand, type CmuxTuiSource } from "../../services/vms/drivers/cmuxTuiDaemon";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER, devboxWorkUserSetupCommand } from "../../services/vms/images/workUser";
import {
  cmuxTuiWebsocketSmokeCommand,
  DEVBOX_INSTANCE_ID_COMMAND,
  devboxFileBytes,
  devboxGhosttyVersion,
  devboxIdentityCheckCommand,
  devboxIdentityInstallCommand,
  devboxJournalResetCommand,
  devboxSnapshotClockCommand,
  devboxWaitForDaemonCommand,
} from "../devbox-image-common";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, hasFlag, Ledger, StepLog, type Vm } from "./guest";
import { SSHD_DROP_IN, sshdBakeCommand, sshdDropIn, sshdListenProblems, sshdPolicyProblems, splitSshdBakeOutput } from "./sshd";
import {
  aptClosureProblems,
  aptPinArgs,
  basePackageProblems,
  CURRENT_BIN,
  DEFAULT_LOCK_PATH,
  dpkgChanges,
  fingerprintProblems,
  imageResourceName,
  type InputsLock,
  type LockedProgram,
  lockDigest,
  npmGlobalProblems,
  parseDpkgList,
  parseInputsLock,
  pgdgSourcesFile,
  profileCommand,
  programInstallCommand,
  ROLES_MANIFEST_PATH,
  rolesManifest,
  sq,
  STORE_DIR,
  ubuntuSourcesFile,
  withFingerprint,
} from "./lock";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const GUEST_DIR = path.resolve(HERE, "../../../images/cmux-vm/guest");
const DPKG_LIST = "dpkg-query -W -f='${Package}\\t${Version}\\t${Architecture}\\n' | LC_ALL=C sort";
const PGDG_KEY = "/usr/share/keyrings/cmux-pgdg.asc";
const DAEMON_UNIT = "cmux-tui-daemon.service";
const DISABLED_TIMERS = ["apt-daily.timer", "apt-daily-upgrade.timer", "man-db.timer", "motd-news.timer"];
/** Temp files left in the image; the provider's exec agent keeps its own per-exec scratch (.freestyle-exec-*). */
export const TMP_LEFTOVERS = "find /tmp /var/tmp -mindepth 1 -maxdepth 1 ! -name '.freestyle-exec-*'";
const STORE_PATH = `${CURRENT_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`;

export type BakeOptions = {
  tag: string;
  outDir: string;
  lockPath: string;
  updateLock: boolean;
  keepBuilder: boolean;
  promotion: boolean;
};

export type BakeResult = Record<string, unknown> & { name: string; snapshotId?: string; error?: string; sbomFile?: string; manifestFile?: string };

function program(lock: InputsLock, name: string): LockedProgram {
  const found = lock.programs.find((p) => p.name === name);
  if (!found) throw new Error(`lock has no ${name}`);
  return found;
}

/** The daemon source the driver's install command expects, built from the lock (no manifest fetch). */
export function cmuxTuiSourceFromLock(lock: InputsLock): CmuxTuiSource {
  const tui = program(lock, "cmux-tui");
  const hook = program(lock, "cmux-tui-hook");
  return { url: tui.url, sha256: tui.sha256, commit: tui.version, builtAt: null, hookUrl: hook.url, hookSha256: hook.sha256 };
}

const runtimeProbe = [
  "printf 'node=%s\\n' \"$(node --version)\"",
  "printf 'npm=%s\\n' \"$(npm --version)\"",
  "printf 'bun=%s\\n' \"$(bun --version)\"",
  "printf 'python3=%s\\n' \"$(python3 --version 2>&1)\"",
  "printf 'uv=%s\\n' \"$(uv --version)\"",
  "printf 'docker=%s\\n' \"$(docker --version)\"",
].join("; ");

function runtimeProblems(lock: InputsLock, stdout: string): string[] {
  const seen = new Map(stdout.trim().split("\n").map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)] as const));
  return Object.entries(lock.base.runtimes)
    .filter(([key, expected]) => !(seen.get(key) ?? "").startsWith(expected))
    .map(([key, expected]) => `base runtime ${key}: lock ${expected}, base ${seen.get(key) ?? "absent"}`);
}

/** Strip the base's unrequested npm globals; keep bun as its real ELF (the npm package was its only copy). */
function npmStripCommand(lock: InputsLock): string {
  return [
    "R=$(npm root -g)",
    'b=$(readlink -f /usr/local/bin/bun); [ "$(head -c4 "$b" | tail -c3)" = ELF ] && cp "$b" /usr/local/bin/.bun-real',
    `for p in ${lock.base.npmGlobals.strip.map(sq).join(" ")}; do if [ -d "$R/$p" ]; then echo "strip $p $(du -sb "$R/$p" | cut -f1)"; npm rm -g "$p" >/dev/null 2>&1 || { echo "npm rm failed $p"; exit 1; }; fi; done`,
    "rm -f /usr/local/bin/bun /usr/local/bin/bunx && mv /usr/local/bin/.bun-real /usr/local/bin/bun && ln -s bun /usr/local/bin/bunx",
    "find /usr/local/bin -xtype l -print -delete",
    "bun --version",
    "npm ls -g --depth=0 --json",
  ].join(" && ");
}

function npmGlobals(json: string): Map<string, string> {
  const start = json.indexOf("{");
  const parsed = JSON.parse(json.slice(start)) as { dependencies?: Record<string, { version?: string }> };
  return new Map(Object.entries(parsed.dependencies ?? {}).map(([name, dep]) => [name, dep.version ?? ""]));
}

function storeProfileScript(): string {
  return `# cmux store: user-space programs (images/cmux-vm). Managed, do not edit.\ncase ":$PATH:" in *:${CURRENT_BIN}:*) ;; *) PATH=${CURRENT_BIN}:$PATH ;; esac\nexport PATH\n`;
}

function coderouterProfileScript(): string {
  // The CLI dials the same edge alias as the agents; the edge injects the route token.
  return `# cmux: the coderouter CLI uses the VM edge alias; no login and no token on disk. Managed, do not edit.\nexport CODEROUTER_API_URL=${sq(`https://${vmEdgeAliasDomain()}`)}\n`;
}

function daemonUnit(): string {
  return [
    "[Unit]",
    "Description=cmux-tui session daemon supervisor",
    "After=network.target",
    "",
    "[Service]",
    "Type=simple",
    "User=root",
    "Environment=CMUX_TUI_REMOTE_WS_BIND=[::]:1337",
    `Environment=PATH=${STORE_PATH}`,
    "ExecStart=/usr/local/bin/cmux-devbox-boot",
    "Restart=always",
    "RestartSec=2",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "",
  ].join("\n");
}

/** Park the daemon for the snapshot. No template terminal in this image: every per-machine file goes. */
function parkCommand(): string {
  return [
    cmuxTuiLayoutSelector(),
    `mkdir -p /etc/cmux && ${DEVBOX_INSTANCE_ID_COMMAND} > /etc/cmux/bake-instance-id && test -s /etc/cmux/bake-instance-id`,
    "for i in $(seq 1 30); do pgrep -f 'cmux-tui server [s]tart' >/dev/null || break; sleep 1; done",
    "! pgrep -f 'cmux-tui server [s]tart' >/dev/null",
    "pkill -f '[_]_terminal-host' || true",
    "for i in $(seq 1 50); do pgrep -f '[_]_terminal-host' >/dev/null || break; sleep 0.1; done",
    "! pgrep -f '[_]_terminal-host' >/dev/null",
    `systemctl is-active ${DAEMON_UNIT} >/dev/null`,
    'rm -rf "$CMUX_TUI_HOME/.local/state/cmux-tui" "$CMUX_TUI_HOME/.local/state/cmux" /etc/cmux/daemon-instance-id /etc/cmux/first-terminal.json /etc/cmux/daemon-layout /tmp/cmux-tui-websocket-smoke',
    "mkdir -p /run/cmux && find /run/cmux -mindepth 1 -delete",
    "! grep -qi ':0539 ' /proc/net/tcp6",
    "echo daemon-parked",
  ].join(" && ");
}

/** Drop the page cache, then read back what a clone's bind path touches first. */
function warmBindPathCommand(): string {
  const files = [
    `"$(readlink -f ${CURRENT_BIN}/cmux-tui)"`,
    "/usr/local/bin/cmux-devbox-boot",
    "$(command -v sh) $(readlink -f $(command -v sh))",
    "$(command -v bash) $(command -v curl) $(command -v setpriv) $(command -v perl) $(command -v ssh-keygen) $(command -v arping) $(command -v sudo)",
    "$(ldd $(command -v curl) $(command -v bash) $(command -v sudo) $(command -v ssh-keygen) $(command -v perl) 2>/dev/null | awk '/=> \\//{print $3} /^\\t\\//{print $1}' | sort -u)",
  ];
  return [
    "sync",
    "echo 3 > /proc/sys/vm/drop_caches",
    `cat ${files.join(" ")} > /dev/null`,
    "free -m | sed -n 2p",
  ].join(" && ");
}

async function writeGuestFile(vm: Vm, target: string, bytes: string | Uint8Array, mode: number): Promise<void> {
  await vm.fs.writeFile(target, bytes, { mode });
}

async function readGuestText(vm: Vm, file: string): Promise<string> {
  return new TextDecoder().decode(await vm.fs.readFile(file));
}

type Ctx = { vm: Vm; L: StepLog; lock: InputsLock; lockText: string; options: BakeOptions; result: BakeResult; name: string };

async function checkBase(ctx: Ctx): Promise<void> {
  const { vm, L, options, result } = ctx;
  const fp = await L.step(vm, "base-fingerprint", `uname -r && ${DPKG_LIST} > /root/base-dpkg.tsv && sha256sum /root/base-dpkg.tsv | cut -d' ' -f1 && wc -l < /root/base-dpkg.tsv`);
  const [kernelRelease, dpkgListSha256, count] = fp.trim().split("\n");
  const observed = { kernelRelease, dpkgListSha256, dpkgPackageCount: Number(count) };
  result.baseFingerprint = observed;
  const baseDpkg = await readGuestText(vm, "/root/base-dpkg.tsv");
  writeFileSync(path.join(options.outDir, `base-dpkg-${ctx.name}.tsv`), baseDpkg);
  const fpProblems = fingerprintProblems(ctx.lock, observed);
  if (fpProblems.length > 0) {
    if (!options.updateLock) throw new Error(`base fingerprint differs from the lock (pass --update-lock to record it):\n${fpProblems.join("\n")}`);
    ctx.lockText = withFingerprint(ctx.lockText, observed, new Date().toISOString());
    writeFileSync(options.lockPath, ctx.lockText);
    ctx.lock = parseInputsLock(ctx.lockText);
    L.log(`--update-lock: recorded the new base fingerprint in ${options.lockPath}: ${fpProblems.join("; ")}`);
  }
  const problems = [
    ...basePackageProblems(ctx.lock, parseDpkgList(baseDpkg)),
    ...runtimeProblems(ctx.lock, await L.step(vm, "base-runtimes", runtimeProbe)),
    ...npmGlobalProblems(ctx.lock, npmGlobals(await L.step(vm, "base-npm-globals", "npm ls -g --depth=0 --json"))),
  ];
  if (problems.length > 0) throw new Error(`base does not match the lock:\n${problems.join("\n")}`);
}

async function installApt(ctx: Ctx): Promise<void> {
  const { vm, L, lock } = ctx;
  const { ubuntu, pgdg } = lock.apt;
  await L.step(vm, "apt-sources-snapshot", "cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/ubuntu.sources.live");
  await writeGuestFile(vm, "/etc/apt/sources.list.d/ubuntu.sources", ubuntuSourcesFile(ubuntu), 0o644);
  await L.step(vm, "apt-update", "apt-get update -q >/tmp/apt-update.log 2>&1 || { tail -30 /tmp/apt-update.log; exit 1; }");
  await L.step(vm, "apt-install-ubuntu", `apt-get install -y --no-install-recommends ${aptPinArgs(ubuntu.packages)} >/tmp/apt.log 2>&1 || { tail -40 /tmp/apt.log; exit 1; }; grep -c '^Setting up' /tmp/apt.log`);
  // postgresql-common would create and start a 17/main cluster on install; the image carries binaries only.
  await L.step(vm, "pgdg-key", `mkdir -p /etc/postgresql-common/createcluster.d && printf 'create_main_cluster = false\\n' > /etc/postgresql-common/createcluster.d/00-cmux.conf && curl -fsSL --retry 3 -o ${PGDG_KEY} ${sq(pgdg.keyUrl)} && printf '%s  %s\\n' ${pgdg.keySha256} ${PGDG_KEY} | sha256sum -c --quiet -`);
  await writeGuestFile(vm, "/etc/apt/sources.list.d/pgdg.sources", pgdgSourcesFile(pgdg, PGDG_KEY), 0o644);
  await L.step(vm, "apt-install-pgdg", `apt-get update -q >/tmp/apt-update.log 2>&1 || { tail -30 /tmp/apt-update.log; exit 1; }; apt-get install -y --no-install-recommends ${aptPinArgs(pgdg.packages)} >/tmp/apt-pg.log 2>&1 || { tail -40 /tmp/apt-pg.log; exit 1; }; ${DPKG_LIST} > /root/after-dpkg.tsv`);
  const added = dpkgChanges(parseDpkgList(await readGuestText(vm, "/root/base-dpkg.tsv")), parseDpkgList(await readGuestText(vm, "/root/after-dpkg.tsv")));
  const problems = aptClosureProblems({ ...ubuntu.packages, ...pgdg.packages }, added);
  if (problems.length > 0) throw new Error(`apt closure differs from the lock:\n${problems.join("\n")}`);
  ctx.result.aptInstalled = added.size;
  await L.step(vm, "postgres-binaries-only", [
    "systemctl disable --now postgresql.service >/dev/null 2>&1 || true",
    "test \"$(systemctl is-enabled postgresql.service 2>/dev/null)\" = disabled",
    "test -z \"$(pg_lsclusters -h)\"",
    "test ! -e /var/lib/postgresql/17/main",
    // ssl-cert's postinst generates a snakeoil key pair: a private key every clone would share.
    "rm -f /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem",
    "/usr/lib/postgresql/17/bin/postgres --version",
  ].join(" && "));
  await L.step(vm, "fuse-user-allow-other", "grep -q '^user_allow_other' /etc/fuse.conf || echo user_allow_other >> /etc/fuse.conf; fusermount3 -V && bwrap --version && setfacl --version | head -1");
}

async function installStore(ctx: Ctx): Promise<void> {
  const { vm, L, lock } = ctx;
  for (const p of lock.programs) {
    await L.step(vm, `store-${p.name}`, programInstallCommand(p));
  }
  await L.step(vm, "store-profile", `${profileCommand(lock)} && chown -R root:root /opt/cmux`);
  await writeGuestFile(vm, "/etc/profile.d/00-cmux-store.sh", storeProfileScript(), 0o644);
  await writeGuestFile(vm, "/etc/profile.d/cmux-coderouter.sh", coderouterProfileScript(), 0o644);
  ctx.result.storeBytes = (await L.step(vm, "store-size", `du -sb ${STORE_DIR} | cut -f1`)).trim();
}

/** The supervisor runs `$HOME/.cmux/bin/cmux-tui`: link it (and the hook helper beside it) into the store. */
async function wireCmuxTui(ctx: Ctx): Promise<void> {
  const { vm, L, lock } = ctx;
  const source = cmuxTuiSourceFromLock(lock);
  await L.step(vm, "cmux-tui-link", [
    `install -d -o ${DEVBOX_WORK_USER} -g ${DEVBOX_WORK_USER} ${DEVBOX_WORK_HOME}/.cmux ${DEVBOX_WORK_HOME}/.cmux/bin`,
    `ln -sfn ${CURRENT_BIN}/cmux-tui ${DEVBOX_WORK_HOME}/.cmux/bin/cmux-tui`,
    `ln -sfn ${CURRENT_BIN}/cmux-tui-hook ${DEVBOX_WORK_HOME}/.cmux/bin/cmux-tui-hook`,
  ].join(" && "));
  // The driver's own install command: the pinned files already match, so it downloads nothing and installs the agent hooks.
  await L.step(vm, "cmux-tui-hooks", `export PATH=${STORE_PATH} && ${cmuxTuiInstallCommand(source)} && chown -R root:root ${STORE_DIR} && chown -h ${DEVBOX_WORK_USER}:${DEVBOX_WORK_USER} ${DEVBOX_WORK_HOME}/.cmux/bin/cmux-tui ${DEVBOX_WORK_HOME}/.cmux/bin/cmux-tui-hook`);
  await L.step(vm, "cmux-tui-pin", `${cmuxTuiPinCheckCommand(source)} && mkdir -p /etc/cmux && printf '%s %s\\n' ${source.sha256} ${source.commit} > /etc/cmux/cmux-tui-pin && printf '%s\\n' ${devboxGhosttyVersion()} > /etc/cmux/ghostty-version`);
}

async function configureSystem(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  ctx.result.docker = await L.step(vm, "docker-socket-only", [
    "systemctl disable --now docker.service containerd.service >/dev/null 2>&1",
    "systemctl enable docker.socket >/dev/null 2>&1",
    "systemctl start docker.socket",
    "test \"$(systemctl is-active docker.socket)\" = active",
    "test \"$(systemctl is-enabled docker.service)\" = disabled",
    "systemctl is-active docker.service containerd.service | tr '\\n' ' '; true",
  ].join(" && "));
  ctx.result.timers = await L.step(vm, "timers-disable", [
    `for t in ${DISABLED_TIMERS.join(" ")}; do systemctl disable --now "$t" >/dev/null 2>&1 || true; done`,
    `for t in ${DISABLED_TIMERS.join(" ")}; do s=$(systemctl is-enabled "$t" 2>/dev/null || true); case "$s" in enabled*) echo "$t still $s"; exit 1;; esac; done`,
    "systemctl list-timers --all --no-legend | awk '{print $NF}' | tr '\\n' ' '",
  ].join(" && "));
  await writeGuestFile(vm, "/etc/tmpfiles.d/cmux-snapshot-resume.conf", "# Clones resume with a monotonic clock jump; do not report a workqueue lockup.\nw- /sys/module/workqueue/parameters/watchdog_thresh - - - - 0\n", 0o644);
  await L.step(vm, "snapshot-resume-quiet", "{ [ ! -e /sys/module/workqueue/parameters/watchdog_thresh ] || echo 0 > /sys/module/workqueue/parameters/watchdog_thresh; } && echo ok");
}

/** Loopback sshd that trusts only the CA bind writes (cloud-automation.md 5, D-A4). No key material is baked. */
async function configureSshd(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  await writeGuestFile(vm, SSHD_DROP_IN, sshdDropIn(DEVBOX_WORK_USER), 0o644);
  const { effective, ss } = splitSshdBakeOutput(await L.step(vm, "sshd-ca-trust", sshdBakeCommand(DEVBOX_WORK_USER)));
  const problems = [...sshdPolicyProblems(effective, DEVBOX_WORK_USER), ...sshdListenProblems(ss)];
  if (problems.length > 0) throw new Error(`sshd policy:\n${problems.join("\n")}`);
}

/** The roles file for `cmux host`; baked role packages stay off (no unit, no process), first-use closures stay uninstalled. */
async function configureRoles(ctx: Ctx): Promise<void> {
  const { vm, L, lock } = ctx;
  await writeGuestFile(vm, ROLES_MANIFEST_PATH, `${JSON.stringify(rolesManifest(lock), null, 2)}\n`, 0o644);
  const firstUse = Object.values(lock.apt.ubuntu.firstUse).flatMap((closure) => Object.keys(closure));
  ctx.result.roles = await L.step(vm, "roles-off", [
    `python3 -c 'import json,sys; json.load(open(sys.argv[1]))' ${ROLES_MANIFEST_PATH}`,
    "! pgrep -x Xvfb >/dev/null",
    `for p in ${[...new Set(firstUse)].sort().join(" ")}; do if dpkg-query -W -f='\${Status}' "$p" 2>/dev/null | grep -q 'ok installed'; then echo "first-use package $p is installed"; exit 1; fi; done`,
    "dpkg-query -W -f='${Status}' fonts-noto-cjk | grep -q 'ok installed' && ls /usr/share/fonts/opentype/noto/ | grep -q '^NotoSansCJK'",
    "echo roles-ok",
  ].join(" && "));
}

export const VM_AGENT_PATH = "/opt/cmux/guest/vm-agent.ts";

/** systemd units for the VM agent: started by bind.json (path unit) or at boot when bound; never at bake. */
export function vmAgentUnits(): { path: string; service: string } {
  return {
    path: [
      "[Unit]",
      "Description=cmux VM agent trigger (the driver wrote bind.json)",
      "",
      "[Path]",
      "PathExists=/var/lib/cmux/bind.json",
      "Unit=cmux-vm-agent.service",
      "",
      "[Install]",
      "WantedBy=paths.target",
      "",
    ].join("\n"),
    service: [
      "[Unit]",
      "Description=cmux VM agent (bind, status report, events)",
      "After=network-online.target",
      "Wants=network-online.target",
      "ConditionPathExists=|/var/lib/cmux/bind.json",
      "ConditionPathExists=|/var/lib/cmux/bound.json",
      "",
      "[Service]",
      "Type=simple",
      `ExecStart=/usr/local/bin/bun ${VM_AGENT_PATH}`,
      "Restart=on-failure",
      "RestartSec=5",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "",
    ].join("\n"),
  };
}

async function installVmAgent(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  const units = vmAgentUnits();
  await L.step(vm, "vm-agent-dirs", "install -d -m 0755 /opt/cmux/guest && install -d -m 0700 /var/lib/cmux");
  await writeGuestFile(vm, VM_AGENT_PATH, readFileSync(path.join(GUEST_DIR, "vm-agent.ts")), 0o644);
  await writeGuestFile(vm, "/etc/systemd/system/cmux-vm-agent.path", units.path, 0o644);
  await writeGuestFile(vm, "/etc/systemd/system/cmux-vm-agent.service", units.service, 0o644);
  ctx.result.vmAgent = await L.step(vm, "vm-agent-enable", [
    `d="$(mktemp -d)" && /usr/local/bin/bun build --target=bun --outdir "$d" ${VM_AGENT_PATH} >/dev/null && rm -rf "$d"`,
    "systemctl daemon-reload",
    "systemctl enable --quiet cmux-vm-agent.path cmux-vm-agent.service",
    "systemctl start cmux-vm-agent.path",
    "test ! -e /var/lib/cmux/bind.json && test ! -e /var/lib/cmux/bound.json",
    "test \"$(systemctl is-active cmux-vm-agent.service)\" != active",
    "echo vm-agent-armed",
  ].join(" && "));
}

/**
 * The VM agent's daemon facts, recorded while the baked daemon runs: its control socket path
 * (found by `ss`, so no path rule is duplicated here) and its identify answer as the fallback
 * daemon.json. Bind queries the live daemon first (cloud-automation.md 17).
 */
async function recordDaemonInfo(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  const out = await L.step(vm, "daemon-identify-record", [
    `sock="$(ss -Hxlp | awk '/"cmux-tui"/ {for (i = 1; i <= NF; i++) if ($i ~ /\\/cloud\\.sock$/) print $i}' | head -1)"`,
    'test -n "$sock"',
    "printf '%s\\n' \"$sock\" > /etc/cmux/daemon-socket",
    `/usr/local/bin/bun ${VM_AGENT_PATH} --print-daemon-info > /etc/cmux/daemon.json.tmp`,
    "mv /etc/cmux/daemon.json.tmp /etc/cmux/daemon.json && chmod 0644 /etc/cmux/daemon.json /etc/cmux/daemon-socket",
    "cat /etc/cmux/daemon-socket /etc/cmux/daemon.json",
  ].join(" && "));
  const info = JSON.parse(out.trim().split("\n").at(-1) ?? "{}") as { version?: string; capabilities?: string[] };
  // The pinned cmux-tui must advertise loopback-forward-v1 (Cloud ports); fs-v1 appears only on a
  // bound Cloud host, so it is not required at bake time.
  if (!info.version || info.version.startsWith("unknown") || !info.capabilities?.includes("vm-agent-v1") || !info.capabilities.includes("loopback-forward-v1")) {
    throw new Error(`daemon.json is not a real identify answer: ${out.trim().slice(0, 300)}`);
  }
  ctx.result.daemonInfo = info;
}

async function startDaemon(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  await writeGuestFile(vm, "/usr/local/bin/cmux-devbox-boot", devboxFileBytes("cmux-devbox-boot"), 0o755);
  await writeGuestFile(vm, `/etc/systemd/system/${DAEMON_UNIT}`, daemonUnit(), 0o644);
  await L.step(vm, "daemon-unit", `sh -n /usr/local/bin/cmux-devbox-boot && rm -f /etc/cmux/bake-instance-id && systemctl daemon-reload && systemctl enable ${DAEMON_UNIT} >/dev/null 2>&1 && systemctl restart ${DAEMON_UNIT} && systemctl is-active ${DAEMON_UNIT}`);
  await L.step(vm, "daemon-ready", devboxWaitForDaemonCommand(120));
  await L.step(vm, "daemon-websocket-smoke", cmuxTuiWebsocketSmokeCommand());
  await recordDaemonInfo(ctx);
  await L.step(vm, "daemon-park", parkCommand());
}

async function writeModelPlane(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  // After every step that opens a login shell: once these exist, a login shell materializes harness configs.
  await writeGuestFile(vm, "/etc/cmux/agent-config.sh", devboxFileBytes("agent-config.sh"), 0o644);
  await writeGuestFile(vm, "/etc/profile.d/cmux-agents.sh", "[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh\n", 0o644);
  await writeGuestFile(vm, VM_GUEST_MODEL_PLANE_ENV_PATH, renderVmGuestModelPlaneEnvFile(vmGuestModelPlaneEnv()), 0o644);
  await L.step(vm, "model-plane-env", `sh -n ${VM_GUEST_MODEL_PLANE_ENV_PATH} && bash -n /etc/cmux/agent-config.sh && ! grep -q crt_ ${VM_GUEST_MODEL_PLANE_ENV_PATH} && grep -q "^export OPENAI_BASE_URL='https://" ${VM_GUEST_MODEL_PLANE_ENV_PATH} && echo model-plane-env-baked`);
}

async function finalizeAndCollect(ctx: Ctx): Promise<void> {
  const { vm, L, options, result, name, lock } = ctx;
  await L.step(vm, "identity-final", devboxIdentityCheckCommand());
  await L.step(vm, "image-stamp", `printf '%s\\n' ${sq(`cmux-vm inputs=${lockDigest(ctx.lockText)} ${name} ${new Date().toISOString()}`)} > /etc/cmux/image-stamp && cat /etc/cmux/image-stamp`);
  await L.step(vm, "apt-sources-live", `mv -f /etc/apt/ubuntu.sources.live /etc/apt/sources.list.d/ubuntu.sources && printf 'Types: deb\\nURIs: https://apt.postgresql.org/pub/repos/apt\\nSuites: noble-pgdg\\nComponents: main\\nSigned-By: ${PGDG_KEY}\\n' > /etc/apt/sources.list.d/pgdg.sources && rm -f /root/base-dpkg.tsv /root/after-dpkg.tsv`);
  result.dfBeforeClean = (await L.step(vm, "df-before-clean", "df -B1 --output=used / | tail -1")).trim();
  await writeGuestFile(vm, "/root/cmux-clean.py", readFileSync(path.join(GUEST_DIR, "clean.py")), 0o755);
  const clean = await L.step(vm, "clean", `python3 /root/cmux-clean.py && rm -f /root/cmux-clean.py && ${devboxJournalResetCommand}`);
  result.clean = JSON.parse(clean.split("CLEAN_JSON ")[1].split("\n")[0]);
  // SBOM and file-hash manifest of the final tree, written under /tmp (excluded from both) and downloaded.
  const syft = lock.tools.syft;
  await L.step(vm, "out-dir", "mkdir -p /tmp/cmux-out");
  await writeGuestFile(vm, "/tmp/cmux-out/manifest.py", readFileSync(path.join(GUEST_DIR, "manifest.py")), 0o755);
  result.manifest = (await L.step(vm, "file-manifest", "python3 /tmp/cmux-out/manifest.py /tmp/cmux-out/manifest.tsv && gzip -9 /tmp/cmux-out/manifest.tsv")).trim();
  result.syft = (await L.step(vm, "sbom", [
    `mkdir -p /tmp/cmux-syft && curl -fsSL --retry 3 -o /tmp/cmux-syft/syft.tgz ${sq(syft.url)}`,
    `printf '%s  %s\\n' ${syft.sha256} /tmp/cmux-syft/syft.tgz | sha256sum -c --quiet -`,
    `test "$(stat -c %s /tmp/cmux-syft/syft.tgz)" = ${syft.size}`,
    "tar -xzf /tmp/cmux-syft/syft.tgz -C /tmp/cmux-syft syft",
    "t=$(date +%s)",
    "cd / && SYFT_CHECK_FOR_APP_UPDATE=false HOME=/tmp/cmux-syft timeout 280 /tmp/cmux-syft/syft scan dir:/ --select-catalogers +javascript-package-cataloger --exclude './proc/**' --exclude './sys/**' --exclude './dev/**' --exclude './run/**' --exclude './tmp/**' -o cyclonedx-json=/tmp/cmux-out/sbom.cdx.json -q",
    "echo syft-secs $(( $(date +%s) - t ))",
    "gzip -9 /tmp/cmux-out/sbom.cdx.json",
  ].join(" && "))).trim();
  result.sbomFile = path.join(options.outDir, `sbom-${name}.cdx.json`);
  result.manifestFile = path.join(options.outDir, `manifest-${name}.tsv`);
  writeFileSync(result.sbomFile, gunzipSync(Buffer.from(await vm.fs.readFile("/tmp/cmux-out/sbom.cdx.json.gz"))));
  writeFileSync(result.manifestFile, gunzipSync(Buffer.from(await vm.fs.readFile("/tmp/cmux-out/manifest.tsv.gz"))));
  const sbom = JSON.parse(readFileSync(result.sbomFile, "utf8")) as { components?: unknown[] };
  result.sbomComponents = sbom.components?.length ?? 0;
  await L.step(vm, "tmp-empty", `rm -rf /tmp/cmux-out /tmp/cmux-syft /root/.cache && ${TMP_LEFTOVERS} | head -5; test -z "$(${TMP_LEFTOVERS})"`);
  result.dfAfterClean = (await L.step(vm, "df-after-clean", "df -B1 --output=used,iused / | tail -1")).trim();
  result.fstrim = (await L.step(vm, "fstrim", "fstrim -v / 2>&1 || true")).trim();
  result.pageCache = (await L.step(vm, "drop-cache-warm-bind-path", warmBindPathCommand())).trim();
}

/** Bakes one snapshot. Never throws: failures land in result.error; the builder is always deleted. */
export async function bake(options: BakeOptions): Promise<BakeResult> {
  mkdirSync(options.outDir, { recursive: true });
  const lockText = readFileSync(options.lockPath, "utf8");
  const lock = parseInputsLock(lockText);
  const sha = (process.env.GITHUB_SHA ?? "0000000000").toLowerCase();
  const name = imageResourceName({ promotion: options.promotion, tag: options.tag, date: new Date().toISOString().slice(0, 10).replace(/-/g, ""), sha });
  const ledger = new Ledger(path.join(options.outDir, "resources.tsv"));
  const L = new StepLog(path.join(options.outDir, `bake-${name}.log`));
  const result: BakeResult = { name, lockSha256: lockDigest(lockText), base: lock.base.snapshot };
  const fs = freestyleClient();
  const t0 = Date.now();
  let builder: Awaited<ReturnType<typeof createVm>> | null = null;
  try {
    builder = await createVm(fs, ledger, { name, snapshotId: lock.base.snapshot, allowUnprefixed: options.promotion });
    result.builderVmId = builder.vmId;
    await firstExec(builder.vm, builder.t0);
    const ctx: Ctx = { vm: builder.vm, L, lock, lockText, options, result, name };
    await checkBase(ctx);
    result.dfStart = (await L.step(ctx.vm, "df-start", "df -B1 --output=used / | tail -1")).trim();
    await L.step(ctx.vm, "snapshot-clock", devboxSnapshotClockCommand);
    await L.step(ctx.vm, "identity", devboxIdentityInstallCommand());
    await L.step(ctx.vm, "work-user", devboxWorkUserSetupCommand());
    result.npmStrip = await L.step(ctx.vm, "npm-strip", npmStripCommand(ctx.lock));
    await installApt(ctx);
    await installStore(ctx);
    await wireCmuxTui(ctx);
    await configureSystem(ctx);
    await configureSshd(ctx);
    await configureRoles(ctx);
    await installVmAgent(ctx);
    await startDaemon(ctx);
    await writeModelPlane(ctx);
    await finalizeAndCollect(ctx);
    const tSnap = Date.now();
    const snap = await builder.vm.snapshot({ displayName: name, slug: name });
    if (!snap?.snapshotId) throw new Error("snapshot response carried no id");
    ledger.record(snap.snapshotId, "snapshot", name);
    result.snapshotId = snap.snapshotId;
    result.snapshotMs = Date.now() - tSnap;
    L.log(`SNAPSHOT ${snap.snapshotId} (${result.snapshotMs} ms)`);
  } catch (error) {
    result.error = String(error);
    L.log(`BAKE FAILED: ${result.error}`);
  } finally {
    if (builder && !options.keepBuilder) await deleteVm(builder.vm, builder.vmId, name, ledger);
  }
  result.bakeMs = Date.now() - t0;
  result.steps = L.steps;
  writeFileSync(path.join(options.outDir, `bake-${name}.json`), `${JSON.stringify(result, null, 2)}\n`);
  L.log(`BAKE_DONE ${name} ${(Number(result.bakeMs) / 1000).toFixed(1)}s snapshot=${result.snapshotId ?? "none"}`);
  return result;
}

export function bakeOptionsFromArgv(argv = process.argv): BakeOptions {
  const tag = argValue("--tag", argv);
  if (!tag) throw new Error("usage: bake.ts --tag <tag> [--out-dir <dir>] [--lock <path>] [--update-lock] [--keep-builder] [--promotion]");
  return {
    tag,
    outDir: path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${tag}`),
    lockPath: path.resolve(argValue("--lock", argv) ?? DEFAULT_LOCK_PATH),
    updateLock: hasFlag("--update-lock", argv),
    keepBuilder: hasFlag("--keep-builder", argv),
    promotion: hasFlag("--promotion", argv),
  };
}

/** CLI entry (images/cmux-vm/bake.ts). */
export async function main(argv = process.argv): Promise<number> {
  const result = await bake(bakeOptionsFromArgv(argv));
  if (result.error || !result.snapshotId) return 1;
  console.log(`IMAGE_ID ${result.snapshotId}`);
  return 0;
}
