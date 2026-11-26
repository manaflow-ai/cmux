/**
 * Bake the cmux VM image from images/cmux-vm/inputs.lock.json alone
 * (plans/cmux-next/vm-image.md sections 4.1 to 4.10).
 *
 * Usage (from web/):
 *   bun ../images/cmux-vm/bake.ts --tag <tag> [--out-dir <dir>] [--lock <path>]
 *       [--update-lock] [--keep-builder] [--promotion] [--prod-copy] [--agent-tools] [--team-vm] [--dev-tree] [--layered] [--large]
 *
 * - --large: a second snapshot of the same builder, grown to the default Cloud chat start size (large-image.ts),
 *   named <name>-large and recorded as `large` in the result. The image's own snapshot, id and fields do not change.
 *
 * - --layered: the image as cached layers, system -> agents -> app (layers.ts); only a layer whose inputs
 *   changed rebuilds. Dev snapshots only; the full bake stays the weekly and manual source of truth.
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
 * - One boot unit, `cmux host run` (host-agent.ts): the bind agent, the session
 *   host supervisor and the Cloud agent role (bind, status reports, events) in
 *   the Rust binary from the store. /etc/cmux/host.json selects the Freestyle
 *   edge carrier; it holds no secret.
 * - Model-plane env and the coderouter CLI point at the VM edge alias; no
 *   login and no token in the image.
 * - The resolver is systemd-resolved with /etc/resolv.conf its stub (dns.ts), checked by
 *   /usr/local/sbin/cmux-dns-check, so Tailscale on a machine runs in resolved mode.
 * - cmux-machine-health.timer (machine-health.ts): a bounded pass every 60 s that checks and heals
 *   DNS, disk, RAM, acpmux and cmux-tui units and writes /run/cmux/machine-health.json; ssh and login sessions get
 *   memory and task limits, and the user's systemd manager outlives a runaway session.
 * - SBOM (syft, pinned) and a file-hash manifest are downloaded next to the
 *   result JSON. The page cache is dropped and the bind path re-read before the
 *   snapshot.
 *
 * - --agent-tools (dev snapshots only, bead cx-h8n): the browser role baked, the agent display
 *   and computer-use units (on demand) and the tool dir acpmux reads, so agent sessions on the
 *   machine get the cmux browser and computer-use tools (agent-tools.ts).
 *
 * - --dev-tree (dev snapshots only): the public cmux checkout at this commit, bindgen's libclang,
 *   the checkout's Rust and Zig toolchains and the caches its first build leaves (dev-tree.ts), so
 *   a developer's first build is a fetch and an incremental build (first-build.ts measures both).
 *
 * - --team-vm (TEAM_VM_SNAPSHOT images, bead cx-cemg): the team files root /srv/team
 *   (root:cmux-ssh 2750, teamVmDirsCommand).
 * - The full daemon handshake (identify.ts) goes into the result as daemonIdentify.
 *
 * Every VM and snapshot is named cmuxnp-dev-vmimg-<tag> unless --promotion
 * (unused for now) or --prod-copy (cmuxnp-prod-vmimg-<tag>: the production
 * copy of a recorded dev image, baked on the production account with the dev
 * image's flags; prod-copy.ts plans it) and is recorded in <out-dir>/resources.tsv the moment it
 * exists. The builder is deleted whatever happens.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import {
  renderVmGuestModelPlaneEnvFile,
  VM_GUEST_MODEL_PLANE_ENV_PATH,
  vmEdgeAliasDomain,
  vmGuestModelPlaneEnv,
} from "../../services/coderouter/vmGuestEnv";
import {
  cmuxTuiAcpmuxLinkCommand,
  cmuxTuiInstallCommand,
  cmuxTuiLayoutSelector,
  cmuxTuiPinCheckCommand,
  cmuxTuiServiceInstallCommand,
  type CmuxTuiSource,
} from "../../services/vms/drivers/cmuxTuiDaemon";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER, devboxWorkUserSetupCommand } from "../../services/vms/workUser";
import { npmCachePrefillCommand, npmCacheSizeCommand } from "./dep-cache";
import { graduatedInstallCommand, readGraduated } from "./graduate";
import {
  cmuxTuiWebsocketSmokeCommand,
  DEVBOX_INSTANCE_ID_COMMAND,
  devboxClaudeSettingsDefaultsCommand,
  devboxFileBytes,
  devboxGhosttyVersion,
  devboxIdentityCheckCommand,
  devboxIdentityInstallCommand,
  devboxJournalResetCommand,
  devboxSnapshotClockCommand,
  devboxTerminfoInstallCommand,
  devboxWaitForDaemonCommand,
} from "./machine-commands";
import {
  devTreeCredentialCheckCommand,
  devTreeLock,
  devTreeSizes,
  devTreeUserPaths,
  setUpDevTree,
  uploadDevTreeScript,
  DEV_TREE_SCRIPT,
  FIRST_BUILD,
} from "./dev-tree";
import { gitDefaultsCommand } from "./git-defaults";
import { GITHUB_SHIM_DIR, githubAuthFiles, githubAuthLinkCommand } from "./github-auth";
import {
  AGENT_TOOLS_BAKED_ROLES,
  AGENT_TOOLS_PROFILE,
  agentToolsDaemonEnv,
  agentToolsFiles,
  agentToolsLinkCommand,
  browserChromiumPath,
  imageToolsSmokeCommand,
  browserRoleBakePhases,
  daemonEnvLines,
  RD_SOCKET,
  RD_SOCKET_UNIT,
  rdHostPath,
  rdSetupCommand,
} from "./agent-tools";
import { daemonIdentifyCommand, parseDaemonIdentify } from "./identify";
import { DNS_CHECK_PATH, dnsCheckScript, resolverBakeCommand } from "./dns";
import { DISK_RECORD_COMMAND, parseDiskOutput } from "./disk-record";
import { MACHINE_HEALTH_ARM_COMMAND, machineHealthBakeCommand, machineHealthFiles } from "./machine-health";
import { chiefBinary, chiefHostFiles, chiefHostInstallCommand } from "./chief-host";
import { growToShape, LARGE_IMAGE_SHAPE, type LargeImageRecord, largeImageName, MEMORY_GUARD_REFRESH_COMMAND, memoryGuardProblems, ROOT_DEVICE_COMMAND } from "./large-image";
import {
  argValue,
  createVm,
  deleteVm,
  firstExec,
  freestyleClient,
  hasFlag,
  Ledger,
  run,
  StepLog,
  type Vm,
} from "./guest";
import { aptUpdateCommand } from "./apt-update";
import {
  baseInputTree,
  cachedInstallCommand,
  imageInputsSha256,
  imagePackagesCommand,
  layerLabel,
  isAppProgram,
  layerKeys,
  layerName,
  overlayPrepareCommand,
  overlayPruneCommand,
  type LayerName,
} from "./layers";
import { HOST_CLI, HOST_CONFIG_PATH, HOST_UNIT, SELF_UPDATE_OFF, hostConfig, hostUnit } from "./host-agent";
import {
  METADATA_GUARD_FILE,
  METADATA_GUARD_UNIT,
  metadataGuardEnableCommand,
  metadataGuardProblems,
  metadataGuardRules,
  metadataGuardUnit,
} from "./metadata-guard";
import {
  cronAtAllowCommand,
  cronAtAllowProblems,
  SSH_LOGIN_GROUP,
  SSH_SYNC_UNIT,
  SSHD_DROP_IN,
  sshdBakeCommand,
  sshdDropIn,
  sshdListenProblems,
  sshdPamProblems,
  sshdPolicyProblems,
  splitSshdBakeOutput,
  sshSyncUnit,
} from "./sshd";
import {
  aptClosureProblems,
  type AptDeb,
  aptDebFetchCommand,
  aptLocalInstallCommand,
  aptPins,
  bakedPrograms,
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
  storeEntry,
  ROLES_MANIFEST_PATH,
  rolesManifest,
  sq,
  STORE_DIR,
  ubuntuSourcesFile,
  withFingerprint,
} from "./lock";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const GUEST_DIR = path.resolve(HERE, "../../../images/cmux-vm/guest");
/** Cloud VM shell defaults shared with the Chief VM bake (cmux-shell.sh: TERM fallback, UTF-8, truecolor). */
export const SHELL_DIR = path.resolve(HERE, "../../services/vms/images/shell");
const DPKG_LIST = "dpkg-query -W -f='${Package}\\t${Version}\\t${Architecture}\\n' | LC_ALL=C sort";
const PGDG_KEY = "/usr/share/keyrings/cmux-pgdg.asc";
const DAEMON_UNIT = HOST_UNIT;
const DISABLED_TIMERS = ["apt-daily.timer", "apt-daily-upgrade.timer", "man-db.timer", "motd-news.timer"];
/** Temp files left in the image; the provider's exec agent keeps its own per-exec scratch (.freestyle-exec-*). */
export const TMP_LEFTOVERS = tmpLeftovers(["/tmp", "/var/tmp"]);

function tmpLeftovers(dirs: readonly string[]): string {
  return `find ${dirs.map(sq).join(" ")} -mindepth 1 -maxdepth 1 ! -name '.freestyle-exec-*'`;
}

/**
 * The last step before snapshot-ready: anything under /tmp or /var/tmp now was written after clean and tmp-empty
 * (image roll 42888042827: /tmp/opencode), and would ship in every clone. Fail, naming the writer: for each
 * leftover its owner and mtime, the processes that hold it open (fuser, /proc/<pid>/fd) or name it on their
 * command line, then every process of the daemon user, and the leftovers' names again on the last line. psmisc's
 * fuser takes no `--` (it printed its usage for every leftover in roll 45608292358). `dirs` is for tests.
 */
export function tmpWritersCommand(dirs: readonly string[] = ["/tmp", "/var/tmp"]): string {
  const script = [
    `left="$(${tmpLeftovers(dirs)})"`,
    'if [ -z "$left" ]; then echo tmp-no-writer; exit 0; fi',
    'printf \'%s\\n\' "$left" | while IFS= read -r p; do',
    '  echo "written after clean: $p $(stat -c \'owner=%U:%G mtime=%y\' -- "$p" 2>&1)"',
    '  if command -v fuser >/dev/null 2>&1; then fuser -v "$p" 2>&1 | sed \'s/^/  fuser: /\'; fi',
    '  for fd in /proc/[0-9]*/fd/*; do',
    '    t="$(readlink "$fd" 2>/dev/null)" || continue',
    '    case "$t" in "$p"|"$p"/*) pid="${fd#/proc/}"; pid="${pid%%/*}"; [ "$pid" = "$$" ] || echo "  open by pid $pid: $(tr \'\\0\' \' \' < "/proc/$pid/cmdline" 2>/dev/null)";; esac',
    "  done | sort -u",
    '  for c in /proc/[0-9]*/cmdline; do',
    '    pid="${c#/proc/}"; pid="${pid%%/*}"; [ "$pid" = "$$" ] && continue',
    '    cmd="$(tr \'\\0\' \' \' < "$c" 2>/dev/null)" || continue',
    '    case "$cmd" in *"$p"*) echo "  named by pid $pid: $cmd";; esac',
    "  done",
    "done",
    'echo "processes of $CMUX_TUI_USER:"',
    'ps -o pid,ppid,lstart,args -u "$CMUX_TUI_USER" 2>&1 | sed \'s/^/  /\'',
    // Last, so the step log's 3000-character tail always keeps the names (image roll 45608292358 lost them).
    'echo "files under /tmp or /var/tmp were written after clean: $(printf \'%s \' $left)(writers above)" >&2',
    "exit 1",
  ].join("\n");
  return `${cmuxTuiLayoutSelector()} && { ${script}\n} 2>&1`;
}
// The gh shim (github-auth.ts) comes first so plain `gh` gets a repo-scoped token.
const STORE_PATH = `${GITHUB_SHIM_DIR}:${CURRENT_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`;

export type BakeOptions = {
  tag: string;
  outDir: string;
  lockPath: string;
  updateLock: boolean;
  keepBuilder: boolean;
  promotion: boolean;
  /** Bake the required Cloud desktop closure (agent-tools.ts); on for Cloud Native bakes. */
  agentTools: boolean;
  /** Team VM image (TEAM_VM_SNAPSHOT): adds the team files root /srv/team (teamVmDirsCommand). */
  teamVm?: boolean;
  /** Bake the cmux dev tree (dev-tree.ts); off by default. */
  devTree?: boolean;
  /**
   * The production copy of a recorded dev image (cloud-vm-image-bake.yml mode prod-copy): the same
   * inputs and flags, baked on the production Freestyle account and named cmuxnp-prod-vmimg-<tag>,
   * the prefix the production Worker boots.
   */
  prodCopy?: boolean;
  /**
   * The layered bake (layers.ts): boot the cached system and agents snapshots of this lock's keys (building a
   * missing one on its parent), then bake only the app layer (this lock's cmux-tui) on top. Dev snapshots only.
   */
  layered?: boolean;
  /**
   * Snapshot before the SBOM and file manifest, keep the builder, and leave them to inventory.ts (run beside the
   * smoke): they were 73 s of a warm per-commit bake. --layered only.
   */
  deferInventory?: boolean;
  /**
   * Also snapshot the builder grown to LARGE_IMAGE_SHAPE (large-image.ts), after the image's own snapshot: the
   * same tree at the size a default Cloud chat start asks for. Dev snapshots only. A failure here never fails
   * the bake: the image's own snapshot is already taken, and nothing boots the large one yet.
   */
  large?: boolean;
};

/**
 * The agent sign-in files the image carries from the devbox template (images/devbox), at the paths the
 * devbox bakes use. The Mac app's Cloud sign-in (CloudCredentialInstaller, CloudMachineLogin) sources
 * agent-auth.sh for `cmux_agent_drop_model_plane_env` and `cmux_agent_has_own_login` and refuses a
 * machine without it; agent-config.sh calls claude-onboarding.py. The `claude`/`codex`/`opencode`
 * launchers are not baked: the agents live in the store profile (/opt/cmux/current/bin), which
 * `cmux host update` swaps, and agent-config.sh already keeps the model-plane Claude key out of the
 * login environment acpmux starts Claude with, so a delivered own login is what Claude uses.
 */
export const AGENT_SIGN_IN_FILES = [
  { name: "agent-auth.sh", path: "/etc/cmux/agent-auth.sh" },
  { name: "claude-onboarding.py", path: "/etc/cmux/claude-onboarding.py" },
] as const;

/**
 * The model route of every agent acpmux starts on the machine: the coderouter edge alias
 * (https://coderouter.cmux.internal, vmGuestEnv.ts) with the public placeholder key. The machine's edge rule
 * (cmux-platform CoderouterEdge) steers that name and adds the per-machine token, so the guest never holds a
 * provider login and the Mac never copies one here.
 *
 * acpmux starts Claude Code from the login environment, where agent-config.sh keeps Claude's pair set aside
 * (its terminal launchers put it back per launch), so an acpmux chat had no route at all and ran on whatever
 * login sat in HOME. The route is therefore pinned in each agent's managed layer: root-owned, read on every
 * start, and above user settings. Claude Code ranks `apiKeyHelper` over CLAUDE_CODE_OAUTH_TOKEN and a /login
 * session, and Codex's managed config overrides `~/.codex/config.toml`, so a login a user or an older copy
 * left in HOME is never used. Only a key the person exports themselves still wins, which is theirs to do.
 */
export function agentModelRouteFiles(alias: string = vmEdgeAliasDomain()): Array<{ path: string; target: string; text: string; mode: number }> {
  const env = vmGuestModelPlaneEnv(alias);
  const claude = {
    // Kept from the devbox image's managed defaults.
    cleanupPeriodDays: 99999,
    skipDangerousModePermissionPrompt: true,
    env: { ANTHROPIC_BASE_URL: env.ANTHROPIC_BASE_URL },
    // The placeholder, never a credential: the edge replaces it. A helper needs no "use this API key?" consent.
    apiKeyHelper: `printf %s ${sq(env.ANTHROPIC_API_KEY)}`,
  };
  const codex = [
    "# cmux Cloud machine: Codex reaches models only through the machine's coderouter edge, which adds the",
    "# per-machine credential. Managed by the image (web/scripts/cmux-vm-image/bake.ts); do not edit.",
    'model_provider = "cmux"',
    "check_for_update_on_startup = false",
    "",
    "[model_providers.cmux]",
    'name = "cmux"',
    `base_url = ${JSON.stringify(env.OPENAI_BASE_URL)}`,
    'env_key = "OPENAI_API_KEY"',
    'wire_api = "responses"',
    "requires_openai_auth = false",
    "supports_websockets = false",
    "",
    "[model_providers.cmux.env_http_headers]",
    '"x-cmux-workspace-id" = "CMUX_WORKSPACE_ID"',
    '"x-cmux-surface-id" = "CMUX_SURFACE_ID"',
    "",
    // The folder trust of the devbox's codex-managed.toml: the two HOMEs a session starts in.
    '[projects."/root"]',
    'trust_level = "trusted"',
    "",
    `[projects.${JSON.stringify(DEVBOX_WORK_HOME)}]`,
    'trust_level = "trusted"',
    "",
  ].join("\n");
  return [
    { path: `${AGENT_MODEL_ROUTE_DIR}/claude-managed-settings.json`, target: "/etc/claude-code/managed-settings.json", text: `${JSON.stringify(claude, null, 2)}\n`, mode: 0o644 },
    { path: `${AGENT_MODEL_ROUTE_DIR}/codex-managed_config.toml`, target: "/etc/codex/managed_config.toml", text: codex, mode: 0o644 },
  ];
}

/**
 * Where the image stages each agent's managed route (agentModelRouteFiles). The same snapshot boots in the dev
 * pool, staging and production, and only the dev pool's machines get the coderouter edge rule
 * (cmux-platform CloudCore, "development only"). Baked in place, the route sent every Claude chat on a staging
 * or production machine to a name that does not resolve (ENOTFOUND after about 180 s, cmux-platform#1442).
 * So the bake stages the files here, and agentModelRouteSyncScript installs them where the alias resolves.
 */
export const AGENT_MODEL_ROUTE_DIR = "/etc/cmux/agent-model-route";
export const AGENT_MODEL_ROUTE_SYNC_PATH = "/usr/local/sbin/cmux-agent-model-route";
export const AGENT_MODEL_ROUTE_UNIT = "cmux-agent-model-route";

/** The file cmux-host writes when a clone binds (PER_MACHINE_FILES); its edge rule was made with it at create. */
export const AGENT_MODEL_ROUTE_TRIGGER = "/var/lib/cmux/bound.json";

/**
 * One pass, once per machine (agentModelRouteUnitFiles): when the edge alias resolves, each staged route file is
 * copied to its agent's managed path; when it does not, a managed file with the staged bytes is removed, and any
 * other file there is left alone. Always exits 0. `CMUX_AGENT_MODEL_ROUTE_ROOT` prefixes every path (tests).
 */
export function agentModelRouteSyncScript(alias: string = vmEdgeAliasDomain()): string {
  const pairs = agentModelRouteFiles(alias).map((f) => `${f.path} ${f.target}`).join("\n");
  return [
    "#!/bin/sh",
    "# cmux: the agents' managed model route, only on a machine whose coderouter edge alias resolves.",
    "# Managed by the image (web/scripts/cmux-vm-image/bake.ts agentModelRouteSyncScript); do not edit.",
    'root="${CMUX_AGENT_MODEL_ROUTE_ROOT:-}"',
    `if timeout 5 getent hosts ${sq(alias)} >/dev/null 2>&1; then up=1; else up=0; fi`,
    "while read -r staged target; do",
    '  s="$root$staged"; t="$root$target"',
    '  [ -s "$s" ] || continue',
    '  if [ "$up" = 1 ]; then',
    '    cmp -s "$s" "$t" || { mkdir -p "$(dirname "$t")" && cp "$s" "$t.new" && chmod 644 "$t.new" && mv -f "$t.new" "$t"; }',
    '  elif cmp -s "$s" "$t"; then',
    '    rm -f "$t"',
    "  fi",
    "done <<EOF",
    pairs,
    "EOF",
    "exit 0",
    "",
  ].join("\n");
}

/**
 * A path unit (inotify, no wakeups) starts the pass when the clone binds, and the service stays active after it
 * (RemainAfterExit), so the path unit does not start it again: one pass per machine, then nothing runs. A clone
 * resumes the bake's running system with no boot, so the path unit is started at bake, before any bind.
 */
export function agentModelRouteUnitFiles(): Array<{ path: string; text: string; mode: number }> {
  return [
    {
      path: `/etc/systemd/system/${AGENT_MODEL_ROUTE_UNIT}.service`,
      text: `[Unit]\nDescription=cmux: the agents' managed model route where the coderouter edge resolves\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nTimeoutStartSec=30\nExecStart=${AGENT_MODEL_ROUTE_SYNC_PATH}\n`,
      mode: 0o644,
    },
    {
      path: `/etc/systemd/system/${AGENT_MODEL_ROUTE_UNIT}.path`,
      text: `[Unit]\nDescription=cmux: the agents' managed model route, once the machine binds\n\n[Path]\nPathExists=${AGENT_MODEL_ROUTE_TRIGGER}\n\n[Install]\nWantedBy=paths.target\n`,
      mode: 0o644,
    },
  ];
}

/**
 * Fails unless both staged route files exist, parse, point at the edge, and carry no credential, and neither is
 * in its agent's managed path (the sync script puts it there on a machine with the edge). `root` prefixes every
 * path (tests).
 */
export function agentModelRouteCheckCommand(root = ""): string {
  const [claudeFile, codexFile] = agentModelRouteFiles();
  const claude = sq(`${root}${claudeFile!.path}`);
  const codex = sq(`${root}${codexFile!.path}`);
  const files = `${claude} ${codex}`;
  return [
    `test -s ${claude}`,
    `test -s ${codex}`,
    `python3 -I -c 'import json, sys, tomllib; s = json.load(open(sys.argv[1])); c = tomllib.load(open(sys.argv[2], "rb")); sys.exit(0 if s["env"]["ANTHROPIC_BASE_URL"].startswith("https://") and s["apiKeyHelper"] and c["model_provider"] == "cmux" and c["model_providers"]["cmux"]["base_url"].startswith("https://") else 1)' ${files}`,
    `! grep -Eq 'CLAUDE_CODE_OAUTH_TOKEN|sk-ant-|sk-proj-|crt_|refresh_token|access_token' ${files}`,
    `test ! -e ${sq(`${root}${claudeFile!.target}`)}`,
    `test ! -e ${sq(`${root}${codexFile!.target}`)}`,
    `sh -n ${sq(`${root}${AGENT_MODEL_ROUTE_SYNC_PATH}`)}`,
    "echo agent-model-route-baked",
  ].join(" && ");
}

/** Fails unless the sign-in files parse and agent-auth.sh defines what the Mac app calls. `root` prefixes every path (tests). */
export function agentSignInCheckCommand(root = ""): string {
  const auth = sq(`${root}/etc/cmux/agent-auth.sh`);
  const onboarding = sq(`${root}/etc/cmux/claude-onboarding.py`);
  return [
    `test -s ${auth}`,
    `test -s ${onboarding}`,
    `sh -n ${auth}`,
    `python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' ${onboarding}`,
    `sh -c '. "$1" && for f in cmux_agent_has_own_login cmux_agent_drop_model_plane_env cmux_agent_own_login_allowed; do command -v "$f" >/dev/null || exit 1; done' sh ${auth}`,
    "echo agent-sign-in-baked",
  ].join(" && ");
}

/** The team files root (team-vm-plan.md section 2; backend team-vm-export.ts EXPORT_ROOT). */
export const TEAM_FILES_ROOT = "/srv/team";

/**
 * /srv/team, owned root:cmux-ssh, mode 2750 (cx-cemg). Only root writes the root itself: the
 * team-host reconciler (S4, root) creates the node directories under it with their own
 * n-<node>-{r,w,a} groups and ACLs. Team accounts and their agent accounts are in cmux-ssh
 * (team_ssh/accounts.rs LOGIN_GROUP), so they can traverse it; any other local user cannot.
 * setgid keeps cmux-ssh on entries a tool creates directly under the root.
 */
export function teamVmDirsCommand(): string {
  return [
    `getent group ${SSH_LOGIN_GROUP} >/dev/null`,
    `install -d -o root -g ${SSH_LOGIN_GROUP} -m 2750 ${TEAM_FILES_ROOT}`,
    `test "$(stat -c '%U:%G %a' ${TEAM_FILES_ROOT})" = "root:${SSH_LOGIN_GROUP} 2750"`,
    `stat -c '%n %U:%G %a' ${TEAM_FILES_ROOT}`,
  ].join(" && ");
}

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

/** Keep the baked image's user-local service alias on the current store generation. */
export function cmuxTuiImageAcpmuxLinkCommand(): string {
  return `${cmuxTuiLayoutSelector()} && ${cmuxTuiAcpmuxLinkCommand(`${CURRENT_BIN}/acpmux`, true)}`;
}

/** Reassert the immutable store before user profile additions (which may put ~/.local/bin first). */
export function storeUserProfilePathCommand(): string {
  const marker = "# cmux store: current profile after user PATH";
  const script = [
    marker,
    'old_path="$PATH"',
    'PATH=""',
    'old_ifs="$IFS"',
    "IFS=:",
    'for entry in $old_path; do case "$entry" in ""|' + GITHUB_SHIM_DIR + "|" + CURRENT_BIN + ') ;; *) PATH="${PATH:+$PATH:}$entry" ;; esac; done',
    'IFS="$old_ifs"',
    'PATH="' + GITHUB_SHIM_DIR + ":" + CURRENT_BIN + '${PATH:+:$PATH}"',
    "export PATH",
    "unset old_path old_ifs entry",
  ].join("\n");
  return [
    `profile=${sq(`${DEVBOX_WORK_HOME}/.profile`)}`,
    `test -e \"$profile\" || install -o ${DEVBOX_WORK_USER} -g ${DEVBOX_WORK_USER} -m 0644 /dev/null \"$profile\"`,
    `grep -qF ${sq(marker)} \"$profile\" || printf '%s\\n' ${sq(script)} >> \"$profile\"`,
    `chown ${DEVBOX_WORK_USER}:${DEVBOX_WORK_USER} \"$profile\"`,
  ].join(" && ");
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

/** The login profile's PATH: the gh shim (github-auth.ts), then the store, ahead of the rest. */
export function storeProfileScript(): string {
  return `# cmux store: user-space programs (images/cmux-vm). Managed, do not edit.\ncase ":$PATH:" in *:${CURRENT_BIN}:*) ;; *) PATH=${CURRENT_BIN}:$PATH ;; esac\ncase ":$PATH:" in *:${GITHUB_SHIM_DIR}:*) ;; *) PATH=${GITHUB_SHIM_DIR}:$PATH ;; esac\nexport PATH\n`;
}

/** Where the Antigravity CLI's updater is turned off: login shells, and the systemd user manager (acpmux.service). */
export const AGY_PROFILE_PATH = "/etc/profile.d/cmux-agy.sh";
export const AGY_USER_ENV_PATH = "/etc/environment.d/60-cmux-agy.conf";
/** agy updates itself in the background unless this is set; the lock pins its version and the store is root's. */
export const AGY_NO_SELF_UPDATE_ENV = "AGY_CLI_DISABLE_AUTO_UPDATE";

export function agyProfileScript(): string {
  return `# cmux: the store pins agy (images/cmux-vm/inputs.lock.json); its own updater stays off. Managed, do not edit.\nexport ${AGY_NO_SELF_UPDATE_ENV}=1\n`;
}

export function agyUserEnvironment(): string {
  return `# cmux: the store pins agy (images/cmux-vm/inputs.lock.json); its own updater stays off. Managed, do not edit.\n${AGY_NO_SELF_UPDATE_ENV}=1\n`;
}

function coderouterProfileScript(): string {
  // The CLI dials the same edge alias as the agents; the edge injects the route token.
  return `# cmux: the coderouter CLI uses the VM edge alias; no login and no token on disk. Managed, do not edit.\nexport CODEROUTER_API_URL=${sq(`https://${vmEdgeAliasDomain()}`)}\n`;
}

/** The boot unit (`cmux host run`); `extraEnv` (agent tools) reaches every terminal it creates. */
export function daemonUnit(extraEnv: Readonly<Record<string, string>> = {}): string {
  return hostUnit(daemonEnvLines(extraEnv), STORE_PATH);
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
    // cmux-tui hosts since 2323e5bdbb76 survive a SIGTERM that is not from PID 1 (host_signals.rs);
    // the builder's terminals are smoke leftovers whose state is wiped next, so they get SIGKILL.
    "pkill -KILL -f '[_]_terminal-host' || true",
    "for i in $(seq 1 50); do pgrep -f '[_]_terminal-host' >/dev/null || break; sleep 0.1; done",
    "! pgrep -f '[_]_terminal-host' >/dev/null",
    `systemctl is-active ${DAEMON_UNIT} >/dev/null`,
    'rm -rf "$CMUX_TUI_HOME/.local/state/cmux-tui" "$CMUX_TUI_HOME/.local/state/cmux" /etc/cmux/daemon-instance-id /etc/cmux/first-terminal.json /etc/cmux/daemon-layout /tmp/cmux-tui-websocket-smoke',
    "mkdir -p /run/cmux && find /run/cmux -mindepth 1 -delete",
    "! grep -qi ':0539 ' /proc/net/tcp6",
    // The roles are parked now; a clone of this snapshot updates itself.
    `rm -f ${SELF_UPDATE_OFF}`,
    "echo daemon-parked",
  ].join(" && ");
}

/** Files a machine makes for itself at bind (cmux-host cloud/wire.rs, identity.rs RECEIPT, carrier_entry.rs): a snapshot holding one gives it to every clone. */
export const PER_MACHINE_FILES = [
  "/var/lib/cmux/bind.json",
  "/var/lib/cmux/bound.json",
  "/var/lib/cmux/install/key.json",
  "/var/lib/cmux/install/identity.json",
  "/var/lib/cmux/wg/key.json",
  "/var/lib/cmux/carrier.json",
  "/run/cmux/carrier-grant.json",
  "/etc/cmux/daemon-instance-id",
] as const;

/**
 * Right before the snapshot (only the machine-health arm follows it): a clone resumes with cmux-host and acpmux already running (nothing waits on
 * their start), and holds no per-machine identity, which each clone mints at bind (cmux-host's rekey: machine-id,
 * random seed, SSH host key; the session host: its remote identity). `root` prefixes every path (tests only).
 */
export function snapshotReadyCommand(root = ""): string {
  const files = PER_MACHINE_FILES.map((f) => sq(`${root}${f}`)).join(" ");
  return [
    cmuxTuiLayoutSelector(),
    `systemctl is-active ${DAEMON_UNIT} >/dev/null`,
    "pgrep -f '[a]cpmux daemon run' >/dev/null",
    `for f in ${files}; do if [ -e "$f" ]; then echo "per-machine file in the snapshot: $f" >&2; exit 1; fi; done`,
    `state=${sq(root)}"$CMUX_TUI_HOME/.local/state"`,
    // Fail closed: a missing tree holds nothing, but one that exists and cannot be scanned refuses the snapshot.
    'held=""',
    // find does not follow a symlinked start point, so an identity tree behind one would pass unseen: refuse it.
    'if [ -L "$state/cmux/remote" ]; then echo "per-machine identity tree is a symlink: $state/cmux/remote" >&2; exit 1; fi',
    'if [ -e "$state/cmux/remote" ]; then held="$(find "$state/cmux/remote" -name identity.json)" || { echo "cannot scan $state/cmux/remote for per-machine identity" >&2; exit 1; }; fi',
    'for f in "$state/cmux-tui/sessions/machine-id" "$state/cmux-tui/sessions/resource-effect-pepper"; do if [ -e "$f" ] || [ -L "$f" ]; then held="$held $f"; fi; done',
    'if [ -n "$held" ]; then echo "per-machine identity in the snapshot: $held" >&2; exit 1; fi',
    "echo snapshot-ready",
  ].join(" && ");
}

/** Agent CLIs a first session starts; their entry files are read back into the snapshot's page cache. */
const WARM_AGENT_BINS = ["claude", "codex", "opencode", "pi", "cursor-agent", "gh", "git"] as const;

/** Drop the page cache, then read back what a clone's bind path touches first, then the agent CLIs. */
function warmBindPathCommand(): string {
  const files = [
    `"$(readlink -f ${CURRENT_BIN}/cmux-tui)"`,
    "$(command -v sh) $(readlink -f $(command -v sh))",
    "$(command -v bash) $(command -v curl) $(command -v setpriv) $(command -v perl) $(command -v ssh-keygen) $(command -v arping) $(command -v sudo)",
    "$(ldd $(command -v curl) $(command -v bash) $(command -v sudo) $(command -v ssh-keygen) $(command -v perl) 2>/dev/null | awk '/=> \\//{print $3} /^\\t\\//{print $1}' | sort -u)",
  ];
  // What a first session runs next: the agent CLIs' entry files (a missing one is skipped, not an error).
  const agents = `for b in ${WARM_AGENT_BINS.join(" ")}; do f="$(readlink -f ${CURRENT_BIN}/$b 2>/dev/null)" && [ -f "$f" ] && cat "$f" > /dev/null; done; true`;
  return [
    "sync",
    "echo 3 > /proc/sys/vm/drop_caches",
    `cat ${files.join(" ")} > /dev/null`,
    agents,
    "free -m | sed -n 2p",
  ].join(" && ");
}

/**
 * Every baked file is a system file: the provider's file API writes as the work user, so the file is handed
 * to root right after (a work-user-owned unit or sshd drop-in would let that user change what root runs).
 */
async function writeGuestFile(vm: Vm, target: string, bytes: string | Uint8Array, mode: number): Promise<void> {
  await vm.fs.writeFile(target, bytes, { mode });
  const r = await run(vm, `chown root:root ${sq(target)}`);
  if (r.code !== 0) throw new Error(`chown root:root ${target}: ${r.stderr.slice(-300)}`);
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

/**
 * One download-only batch: about 20 MB, so a batch ends well inside the guest agent's
 * 5-minute exec cap at the slowest locked-mirror rate seen (snapshot.ubuntu.com, about
 * 110 KB/s on 2026-10-12, bead cx-w6u84). A package larger than this is a batch alone.
 */
export const APT_BATCH_BYTES = 20_000_000;

/** The base image's apt index: the dated snapshot, else the public archive (aptUpdateCommand). Only pgdg's install reads an index. */
export const APT_UPDATE_COMMAND = aptUpdateCommand({ log: "/tmp/apt-update.log", sources: "/etc/apt/sources.list.d/ubuntu.sources", saved: "/tmp/ubuntu.sources.snapshot" });

/** Where the bake fetches locked Ubuntu .debs (clean.py empties it before the snapshot). */
export const APT_DEB_DIR = "/var/cache/apt/archives";

/** Greedy batches in name order, sized from the lock's .debs (apt.ubuntu.debs); a pin with no .deb is refused. */
export function aptDownloadBatches(
  packages: Readonly<Record<string, string>>,
  debs: Readonly<Record<string, AptDeb>>,
  maxBytes = APT_BATCH_BYTES,
): Array<{ pins: string[]; bytes: number }> {
  const pins = aptPins(packages);
  const missing = pins.filter((pin) => !debs[pin]);
  if (missing.length > 0) throw new Error(`apt.ubuntu.debs has no .deb for ${missing.length} of ${pins.length} locked pins (${missing.join(", ")}); run images/cmux-vm/apt-debs.ts`);
  const batches: Array<{ pins: string[]; bytes: number }> = [];
  let current: { pins: string[]; bytes: number } = { pins: [], bytes: 0 };
  for (const pin of pins) {
    const size = debs[pin]!.size;
    if (current.pins.length > 0 && current.bytes + size > maxBytes) {
      batches.push(current);
      current = { pins: [], bytes: 0 };
    }
    current.pins.push(pin);
    current.bytes += size;
  }
  if (current.pins.length > 0) batches.push(current);
  return batches;
}

/** Runs of one download batch before the bake fails. */
export const APT_FETCH_ATTEMPTS = 3;

/**
 * One download batch, run again when it fails: a slow mirror can push a batch past the guest's 5-minute exec cap
 * (image roll 44263286356, status 124), and aptDebFetchCommand keeps every .deb it verified, so each run only fetches
 * what is still missing. A .deb no mirror serves fails every run and still fails the bake.
 */
export async function fetchAptBatch(L: Pick<StepLog, "step" | "log">, vm: Vm, label: string, command: string, attempts = APT_FETCH_ATTEMPTS): Promise<void> {
  await stepAgain(L, vm, label, command, attempts, "the .debs it verified");
}

/**
 * Runs of one store program's install before the bake fails. GitHub release downloads into the bake machine ran at
 * about 100 KB/s a connection on 2026-11-23 (image rolls 45109809346 and 45113664312: store-codex, 109 MB, status
 * 124 at 300 s twice), so codex needs about four 5-minute runs; programInstallCommand resumes the download.
 */
export const STORE_FETCH_ATTEMPTS = 6;

/** One store program's install, run again when it fails, continuing its partial download (programInstallCommand). */
export async function installStoreProgram(L: Pick<StepLog, "step" | "log">, vm: Vm, label: string, command: string, attempts = STORE_FETCH_ATTEMPTS): Promise<void> {
  await stepAgain(L, vm, label, command, attempts, "the part it downloaded");
}

async function stepAgain(L: Pick<StepLog, "step" | "log">, vm: Vm, label: string, command: string, attempts: number, kept: string): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    try {
      await L.step(vm, attempt === 1 ? label : `${label}-try-${attempt}`, command);
      return;
    } catch (error) {
      if (attempt >= attempts) throw error;
      L.log(`${label} failed (try ${attempt} of ${attempts}); running it again, keeping ${kept}`);
    }
  }
}

/**
 * Fetch and install a locked Ubuntu closure by content (aptDebFetchCommand, aptLocalInstallCommand): no apt index is
 * read, so a pin the public archive has superseded comes from the dated snapshot instead of failing the bake (run
 * 43932356313: the snapshot's index update hit its 90 s cap, the archive fallback had moved ca-certificates on, and
 * "apt index has no size"). The snapshot can be too slow for one 5-minute exec (the guest agent's cap), so the
 * fetch runs in batches of about APT_BATCH_BYTES, each its own step.
 */
async function installUbuntuDebs(ctx: Ctx, prefix: string, packages: Readonly<Record<string, string>>, log: string): Promise<void> {
  const { vm, L } = ctx;
  const { ubuntu } = ctx.lock.apt;
  const batches = aptDownloadBatches(packages, ubuntu.debs);
  L.log(`${prefix} fetch: ${Object.keys(packages).length} packages, ${batches.length} batches: ${batches.map((b) => `${b.pins.length} pkgs ${(b.bytes / 1e6).toFixed(1)} MB`).join(", ")}`);
  for (const [i, batch] of batches.entries()) {
    await fetchAptBatch(L, vm, `${prefix}-download-${i + 1}-of-${batches.length}`, aptDebFetchCommand(ubuntu.debs, batch.pins, ubuntu.uri, APT_DEB_DIR));
  }
  await L.step(vm, `${prefix}-install`, `${aptLocalInstallCommand(ubuntu.debs, aptPins(packages), APT_DEB_DIR, log)}; grep -c '^Setting up' ${log}`);
}

async function installApt(ctx: Ctx): Promise<void> {
  const { vm, L, lock } = ctx;
  const { ubuntu, pgdg } = lock.apt;
  await L.step(vm, "apt-sources-snapshot", "cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/ubuntu.sources.live");
  await writeGuestFile(vm, "/etc/apt/sources.list.d/ubuntu.sources", ubuntuSourcesFile(ubuntu), 0o644);
  await installUbuntuDebs(ctx, "apt-ubuntu", ubuntu.packages, "/tmp/apt.log");
  // postgresql-common would create and start a 17/main cluster on install; the image carries binaries only.
  await L.step(vm, "pgdg-key", `mkdir -p /etc/postgresql-common/createcluster.d && printf 'create_main_cluster = false\\n' > /etc/postgresql-common/createcluster.d/00-cmux.conf && curl -fsSL --retry 3 -o ${PGDG_KEY} ${sq(pgdg.keyUrl)} && printf '%s  %s\\n' ${pgdg.keySha256} ${PGDG_KEY} | sha256sum -c --quiet -`);
  await writeGuestFile(vm, "/etc/apt/sources.list.d/pgdg.sources", pgdgSourcesFile(pgdg, PGDG_KEY), 0o644);
  await L.step(vm, "apt-install-pgdg", `${APT_UPDATE_COMMAND}; apt-get install -y --no-install-recommends ${aptPinArgs(pgdg.packages)} >/tmp/apt-pg.log 2>&1 || { tail -40 /tmp/apt-pg.log; exit 1; }; ${DPKG_LIST} > /root/after-dpkg.tsv`);
  const baseDpkg = parseDpkgList(await readGuestText(vm, "/root/base-dpkg.tsv"));
  const added = dpkgChanges(baseDpkg, parseDpkgList(await readGuestText(vm, "/root/after-dpkg.tsv")));
  const problems = aptClosureProblems({ ...ubuntu.packages, ...pgdg.packages }, added, baseDpkg);
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
  await parallelSteps(bakedPrograms(lock).map((p) => () => installStoreProgram(L, vm, `store-${p.name}`, programInstallCommand(p))));
  await L.step(vm, "store-profile", `${profileCommand(lock)} && chown -R root:root /opt/cmux`);
  await writeGuestFile(vm, "/etc/profile.d/00-cmux-store.sh", storeProfileScript(), 0o644);
  await writeGuestFile(vm, "/etc/profile.d/cmux-coderouter.sh", coderouterProfileScript(), 0o644);
  await writeGuestFile(vm, AGY_PROFILE_PATH, agyProfileScript(), 0o644);
  await L.step(vm, "agy-user-env-dir", "mkdir -p /etc/environment.d");
  await writeGuestFile(vm, AGY_USER_ENV_PATH, agyUserEnvironment(), 0o644);
  await L.step(vm, "store-user-profile", storeUserProfilePathCommand());
  ctx.result.storeBytes = (await L.step(vm, "store-size", `du -sb ${STORE_DIR} | cut -f1`)).trim();
  // git and gh with repo-scoped GitHub App tokens and no secret at rest (github-auth.ts).
  for (const file of githubAuthFiles()) await writeGuestFile(vm, file.path, file.text, file.mode);
  await L.step(vm, "github-auth", githubAuthLinkCommand(STORE_PATH));
  // Parallel checkout, untracked cache, index v4 for every machine (RFD 0065 piece 3; git-defaults.ts).
  await L.step(vm, "git-defaults", gitDefaultsCommand());
}

/** The supervisor runs `$HOME/.cmux/bin/cmux-tui`: link it (and the hook helper beside it) into the store. */
async function wireCmuxTui(ctx: Ctx): Promise<void> {
  const { vm, L, lock } = ctx;
  const source = cmuxTuiSourceFromLock(lock);
  await L.step(vm, "cmux-tui-link", [
    // ~/work is the default Cloud chat folder (`cmux cloud start-chat --cwd /home/cmux/work`, the move's work root).
    `install -d -o ${DEVBOX_WORK_USER} -g ${DEVBOX_WORK_USER} ${DEVBOX_WORK_HOME}/.cmux ${DEVBOX_WORK_HOME}/.cmux/bin ${DEVBOX_WORK_HOME}/work`,
    `ln -sfn ${CURRENT_BIN}/cmux-tui ${DEVBOX_WORK_HOME}/.cmux/bin/cmux-tui`,
    `ln -sfn ${CURRENT_BIN}/cmux-tui-hook ${DEVBOX_WORK_HOME}/.cmux/bin/cmux-tui-hook`,
  ].join(" && "));
  // The driver's own install command: the pinned files already match, so it downloads nothing and installs the agent hooks.
  await L.step(vm, "cmux-tui-hooks", `export PATH=${STORE_PATH} && ${cmuxTuiInstallCommand(source)} && chown -R root:root ${STORE_DIR} && chown -h ${DEVBOX_WORK_USER}:${DEVBOX_WORK_USER} ${DEVBOX_WORK_HOME}/.cmux/bin/cmux-tui ${DEVBOX_WORK_HOME}/.cmux/bin/cmux-tui-hook`);
  // The driver creates ~/.local/bin/acpmux for the runtime service. In the
  // baked image that alias must resolve through the immutable current profile,
  // otherwise smoke sees a home-local store path ahead of /opt/cmux/current.
  await L.step(vm, "acpmux-current-link", cmuxTuiImageAcpmuxLinkCommand());
  await L.step(vm, "acpmux-service", cmuxTuiServiceInstallCommand());
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
  // Shell defaults (web/services/vms/images/shell): the devbox terminfo overlay
  // so TERM=xterm-ghostty works in htop/vim/tmux/less, the TERM fallback and
  // truecolor profile, and no provider banner (Freestyle's static /etc/motd,
  // the stock Ubuntu motd scripts).
  await writeGuestFile(vm, "/etc/cmux/terminfo.src", devboxFileBytes("cmux-terminfo.src"), 0o644);
  await writeGuestFile(vm, "/etc/profile.d/cmux-terminfo.sh", devboxFileBytes("cmux-terminfo.sh"), 0o644);
  await writeGuestFile(vm, "/etc/profile.d/cmux-shell.sh", readFileSync(path.join(SHELL_DIR, "cmux-shell.sh")), 0o644);
  await writeGuestFile(vm, "/etc/cmux/nvm-lazy.sh", readFileSync(path.join(SHELL_DIR, "nvm-lazy.sh")), 0o644);
  await L.step(vm, "terminfo", devboxTerminfoInstallCommand);
  await L.step(vm, "shell-env", [
    "grep -qxF '[ -f /etc/profile.d/cmux-shell.sh ] && . /etc/profile.d/cmux-shell.sh' /etc/bash.bashrc || echo '[ -f /etc/profile.d/cmux-shell.sh ] && . /etc/profile.d/cmux-shell.sh' >> /etc/bash.bashrc",
    ": > /etc/motd",
    // The provider's eager nvm loader costs ~300 ms per login shell; node stays on PATH.
    "if [ -f /etc/profile.d/nvm.sh ] && grep -q 'nvm\\.sh\"' /etc/profile.d/nvm.sh; then cp /etc/profile.d/nvm.sh /etc/cmux/nvm.sh.orig && cp /etc/cmux/nvm-lazy.sh /etc/profile.d/nvm.sh; fi",
    "env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -lc 'command -v node' >/dev/null",
    "for f in /etc/update-motd.d/*; do [ -f \"$f\" ] && chmod -x \"$f\"; done; true",
    "[ \"$(env -i HOME=/root TERM=bogus-term sh -c '. /etc/profile.d/cmux-shell.sh; echo $TERM $COLORTERM')\" = 'xterm-256color truecolor' ]",
    "echo shell-env-ok",
  ].join(" && "));
  await writeGuestFile(vm, DNS_CHECK_PATH, dnsCheckScript(), 0o755);
  ctx.result.resolver = (await L.step(vm, "resolver", resolverBakeCommand(), 120_000)).trim();
  await L.step(vm, "snapshot-resume-quiet","{ [ ! -e /sys/module/workqueue/parameters/watchdog_thresh ] || echo 0 > /sys/module/workqueue/parameters/watchdog_thresh; } && echo ok");
}

/** The metadata service for root only (metadata-guard.ts), loaded now so the parked snapshot carries it. */
async function installMetadataGuard(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  await writeGuestFile(vm, METADATA_GUARD_FILE, metadataGuardRules(), 0o644);
  await writeGuestFile(vm, `/etc/systemd/system/${METADATA_GUARD_UNIT}`, metadataGuardUnit(), 0o644);
  const out = await L.step(vm, "metadata-guard", metadataGuardEnableCommand(DEVBOX_WORK_USER));
  const problems = metadataGuardProblems(out);
  if (problems.length > 0) throw new Error(`metadata guard:\n${problems.join("\n")}`);
  ctx.result.metadataGuard = out.trim();
}

/** Loopback sshd that trusts only the CA bind writes (cloud-automation.md 5, D-A4). No key material is baked. */
async function configureSshd(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  await writeGuestFile(vm, SSHD_DROP_IN, sshdDropIn(DEVBOX_WORK_USER), 0o644);
  const { effective, ss, pam } = splitSshdBakeOutput(await L.step(vm, "sshd-ca-trust", sshdBakeCommand(DEVBOX_WORK_USER)));
  const problems = [...sshdPolicyProblems(effective, DEVBOX_WORK_USER), ...sshdListenProblems(ss), ...sshdPamProblems(pam)];
  if (problems.length > 0) throw new Error(`sshd policy:\n${problems.join("\n")}`);
  const cronAt = cronAtAllowProblems(await L.step(vm, "cron-at-allow", cronAtAllowCommand(DEVBOX_WORK_USER)), DEVBOX_WORK_USER);
  if (cronAt.length > 0) throw new Error(`cron/at policy:\n${cronAt.join("\n")}`);
  await writeGuestFile(vm, `/etc/systemd/system/${SSH_SYNC_UNIT}`, sshSyncUnit(), 0o644);
  // --now: a clone resumes this running system (no boot), so an enabled-only unit would never run. Until a team
  // bind it blocks on inotify (no wakeups).
  await L.step(vm, "team-ssh-sync", `systemctl daemon-reload && systemctl enable --now --quiet ${SSH_SYNC_UNIT} && systemctl is-active ${SSH_SYNC_UNIT}`);
}

/**
 * The first-use packages roles-off refuses: every first-use closure, less the closures of the roles --agent-tools
 * bakes (AGENT_TOOLS_BAKED_ROLES: browser, and display-wm for the desktop session; browserRoleBakePhases). A layered
 * bake reruns roles-off in the agents layer, on a system layer whose agent tools already installed those closures.
 */
export function refusedFirstUsePackages(lock: InputsLock, agentTools: boolean): string[] {
  const baked = new Set(agentTools ? AGENT_TOOLS_BAKED_ROLES.flatMap((role) => Object.keys(lock.apt.ubuntu.firstUse[role] ?? {})) : []);
  return [...new Set(Object.values(lock.apt.ubuntu.firstUse).flatMap((closure) => Object.keys(closure)))].filter((p) => !baked.has(p)).sort();
}

/** The roles file for `cmux host`; baked role packages stay off (no unit, no process), first-use closures stay uninstalled. */
async function configureRoles(ctx: Ctx): Promise<void> {
  const { vm, L, lock } = ctx;
  await writeGuestFile(vm, ROLES_MANIFEST_PATH, `${JSON.stringify(rolesManifest(lock), null, 2)}\n`, 0o644);
  const firstUse = refusedFirstUsePackages(lock, Boolean(ctx.options.agentTools));
  ctx.result.roles = await L.step(vm, "roles-off", [
    `python3 -c 'import json,sys; json.load(open(sys.argv[1]))' ${ROLES_MANIFEST_PATH}`,
    "! pgrep -x Xvfb >/dev/null",
    `for p in ${firstUse.join(" ")}; do if dpkg-query -W -f='\${Status}' "$p" 2>/dev/null | grep -q 'ok installed'; then echo "first-use package $p is installed"; exit 1; fi; done`,
    "dpkg-query -W -f='${Status}' fonts-noto-cjk | grep -q 'ok installed' && ls /usr/share/fonts/opentype/noto/ | grep -q '^NotoSansCJK'",
    "echo roles-ok",
  ].join(" && "));
}

/** The Cloud agent's state dir and the host config (`cmux host run` reads it at each session host start). */
async function installHostConfig(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  await L.step(vm, "host-dirs", "install -d -m 0700 /var/lib/cmux && install -d -m 0755 /etc/cmux");
  const hostConfigBody = hostConfig();
  const hostCarrier = (JSON.parse(hostConfigBody) as { remoteWs: { carrier: string } }).remoteWs.carrier;
  ctx.result.cmuxRemoteAuth = hostCarrier === "freestyle-edge-grant" ? "client-grant" : "trusted-carrier";
  await writeGuestFile(vm, HOST_CONFIG_PATH, hostConfigBody, 0o644);
  ctx.result.hostConfig = (await L.step(vm, "host-config", [
    `chown root:root ${HOST_CONFIG_PATH}`,
    `python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c == {"remoteWs": {"bind": "[::]:1337", "carrier": "${hostCarrier}"}}, c' ${HOST_CONFIG_PATH}`,
    `test "$(stat -c '%U %a' ${HOST_CONFIG_PATH})" = "root 644"`,
    "test ! -e /var/lib/cmux/bind.json && test ! -e /var/lib/cmux/bound.json",
    `${HOST_CLI} --help >/dev/null`,
    "echo host-config-ok",
  ].join(" && "))).trim();
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
    `${HOST_CLI} cloud daemon-info > /etc/cmux/daemon.json.tmp`,
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
  // The full handshake (every capability), recorded so the channel history can name the image's
  // capability list and image-staleness.ts can compare it with the tip without a VM.
  ctx.result.daemonIdentify = parseDaemonIdentify(await L.step(vm, "daemon-identify-full", daemonIdentifyCommand()));
  // Coordinator condition for the activity pin: the daemon serves vm-activity-v1 and the agent's
  // own activity stream connects to it. A bake without both fails.
  const probe = await L.step(vm, "daemon-activity-probe", `${HOST_CLI} cloud probe-activity`);
  ctx.result.activityProbe = probe.trim().split("\n").at(-1) ?? "";
}

/** The health loop and guard drop-ins, through the script's own `install` (machine-health.ts); one pass recorded. */
async function installMachineHealth(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  for (const file of machineHealthFiles()) await writeGuestFile(vm, file.path, file.text, file.mode);
  const out = await L.step(vm, "machine-health", machineHealthBakeCommand(), 120_000);
  ctx.result.machineHealth = JSON.parse(out.slice(out.lastIndexOf('{"schema"')));
}

/**
 * The Cloud Chief host units (chief-host.ts), disabled: after the store and the work user. Rerun by the app
 * layer, whose store swap may bring a new optchat-chief.
 */
async function installChiefHost(ctx: Ctx): Promise<void> {
  const { vm, L, lock } = ctx;
  for (const file of chiefHostFiles()) await writeGuestFile(vm, file.path, file.text, file.mode);
  ctx.result.chiefHost = (await L.step(vm, "chief-host", chiefHostInstallCommand(chiefBinary(lock)))).trim().split("\n").at(-1);
}

/** Agent tools (agent-tools.ts): after configureRoles, whose check refuses any installed first-use package. */
async function installAgentTools(ctx: Ctx): Promise<void> {
  const { vm, L, lock } = ctx;
  // Before anything runs on the builder: a lock without cmux-rd fails here (rdHostPath).
  const files = agentToolsFiles(lock);
  for (const phase of browserRoleBakePhases(lock)) await L.step(vm, phase.name, phase.command);
  for (const file of files) await writeGuestFile(vm, file.path, file.text, file.mode);
  ctx.result.agentTools = (await L.step(vm, "agent-tools-link", `sh -n ${AGENT_TOOLS_PROFILE} && ${agentToolsLinkCommand(browserChromiumPath(lock))}`)).trim().split("\n").at(-2);
  await L.step(vm, "image-tools-smoke", imageToolsSmokeCommand());
  await L.step(vm, "agent-tools-desktop", rdSetupCommand());
}

/**
 * The names many people added on their own machines (graduate.ts), installed in the agents layer so one shared
 * copy replaces the many personal ones. Both bakes run it before the finalize records the image's packages.
 */
async function installGraduated(ctx: Ctx): Promise<void> {
  const g = readGraduated();
  if (g.apt.length + g.npm.length === 0) return;
  ctx.result.graduated = (await ctx.L.step(ctx.vm, "graduated", graduatedInstallCommand(g, APT_UPDATE_COMMAND), 540_000)).trim().split("\n").at(-1);
}

/** The npm cache a first `npm install` finds (dep-cache.ts); the image record's size is read after clean. */
async function prefillDepCaches(ctx: Ctx): Promise<void> {
  await ctx.L.step(ctx.vm, "npm-cache-prefill", npmCachePrefillCommand(), 290_000);
}

/**
 * Role desktop in the image record (the platform's desktop capability): an --agent-tools image carries the
 * cmux-rd host. Recorded by bake() from the lock, so a layered bake whose agents layer came from cache records
 * it too.
 */
export function desktopRecord(lock: InputsLock): { role: "desktop"; program: string; version: string; socketUnit: string; socket: string } {
  rdHostPath(lock);
  const rd = lock.programs.find((p) => p.name === "cmux-rd")!;
  return { role: "desktop", program: rd.name, version: rd.version, socketUnit: RD_SOCKET_UNIT, socket: RD_SOCKET };
}

/**
 * --dev-tree: the lock's libclang closure from the dated snapshot (exactly, as installApt), then the
 * checkout at this commit (GITHUB_SHA; the branch head in a local run), Zig, Rust and the first build.
 */
async function installDevTree(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  const tree = devTreeLock(ctx.lock);
  await L.step(vm, "dev-tree-dpkg-before", `${DPKG_LIST} > /root/dev-tree-before.tsv`);
  await installUbuntuDebs(ctx, "dev-tree-apt", tree.apt, "/tmp/apt-dev-tree.log");
  await L.step(vm, "dev-tree-dpkg-after", `${DPKG_LIST} > /root/dev-tree-after.tsv`);
  const before = parseDpkgList(await readGuestText(vm, "/root/dev-tree-before.tsv"));
  const problems = aptClosureProblems(tree.apt, dpkgChanges(before, parseDpkgList(await readGuestText(vm, "/root/dev-tree-after.tsv"))), before);
  if (problems.length > 0) throw new Error(`dev tree apt closure differs from devTree.apt:\n${problems.join("\n")}`);
  await uploadDevTreeScript(vm);
  const phases: Record<string, number> = {};
  const head = await setUpDevTree(vm, tree, process.env.GITHUB_SHA ?? "", phases, (line) => L.log(line));
  await L.step(vm, "dev-tree-no-credentials", devTreeCredentialCheckCommand(tree));
  const bytes = await devTreeSizes(vm, tree);
  await L.step(vm, "dev-tree-done", `rm -f ${DEV_TREE_SCRIPT} /root/dev-tree-before.tsv /root/dev-tree-after.tsv /tmp/apt-dev-tree.log`);
  ctx.result.devTree = { head, dir: tree.dir, firstBuild: FIRST_BUILD.join(" "), phasesMs: phases, bytes };
}

async function startDaemon(ctx: Ctx): Promise<void> {
  const { vm, L } = ctx;
  await writeGuestFile(vm, `/etc/systemd/system/${DAEMON_UNIT}`, daemonUnit(ctx.options.agentTools ? agentToolsDaemonEnv(ctx.lock) : {}), 0o644);
  // The builder never updates itself (cmux host update): the snapshot carries the lock's
  // cmux-tui, and parkCommand removes the marker so every clone does update.
  await L.step(vm, "daemon-unit", `systemd-analyze verify /etc/systemd/system/${DAEMON_UNIT} && mkdir -p /etc/cmux && touch ${SELF_UPDATE_OFF} && rm -f /etc/cmux/bake-instance-id && systemctl daemon-reload && systemctl enable ${DAEMON_UNIT} >/dev/null 2>&1 && systemctl restart ${DAEMON_UNIT} && systemctl is-active ${DAEMON_UNIT}`);
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
  for (const file of AGENT_SIGN_IN_FILES) await writeGuestFile(vm, file.path, devboxFileBytes(file.name), 0o644);
  await L.step(vm, "agent-sign-in", agentSignInCheckCommand());
  // After wireCmuxTui, whose hook install wrote the work user's ~/.claude/settings.json; this only adds keys it lacks.
  await L.step(vm, "claude-settings-defaults", devboxClaudeSettingsDefaultsCommand());
  await L.step(vm, "agent-model-route-dirs", `install -d -m 755 /etc/claude-code /etc/codex ${AGENT_MODEL_ROUTE_DIR}`);
  for (const file of agentModelRouteFiles()) await writeGuestFile(vm, file.path, file.text, file.mode);
  await writeGuestFile(vm, AGENT_MODEL_ROUTE_SYNC_PATH, agentModelRouteSyncScript(), 0o755);
  for (const file of agentModelRouteUnitFiles()) await writeGuestFile(vm, file.path, file.text, file.mode);
  await L.step(vm, "agent-model-route", agentModelRouteCheckCommand());
  // --now: a clone resumes this running system (no boot); the builder never binds, so no pass runs here.
  await L.step(vm, "agent-model-route-path", `test ! -e ${AGENT_MODEL_ROUTE_TRIGGER} && systemd-analyze verify /etc/systemd/system/${AGENT_MODEL_ROUTE_UNIT}.service /etc/systemd/system/${AGENT_MODEL_ROUTE_UNIT}.path && systemctl daemon-reload && systemctl enable --now --quiet ${AGENT_MODEL_ROUTE_UNIT}.path && systemctl is-active ${AGENT_MODEL_ROUTE_UNIT}.path`);
  await L.step(vm, "model-plane-env", `sh -n ${VM_GUEST_MODEL_PLANE_ENV_PATH} && bash -n /etc/cmux/agent-config.sh && ! grep -q crt_ ${VM_GUEST_MODEL_PLANE_ENV_PATH} && grep -q "^export OPENAI_BASE_URL='https://" ${VM_GUEST_MODEL_PLANE_ENV_PATH} && echo model-plane-env-baked`);
  await L.step(vm, "acpmux-login-env", acpmuxLoginEnvRefreshCommand());
  await L.step(vm, "acpmux-harness-checks", acpmuxHarnessChecksDoneCommand());
  await L.step(vm, "acpmux-probes-quiet", acpmuxProbesQuietCommand());
}

/**
 * acpmux (started in wireCmuxTui) read the login shell before the model plane existed, and a clone resumes that
 * process from the snapshot. Its cache's fingerprint (the startup files) cannot see the model-plane file they source,
 * so nothing re-reads it: Codex started without the edge's placeholder key (gateway-e2e run 42382330319). Drop the
 * cache and restart acpmux so the snapshot holds a daemon that read the final login shell; clean.py then drops the
 * cache this read writes, so a cold boot reads its own. `grep -q` checks the key's name only, never a value.
 */
export function acpmuxLoginEnvRefreshCommand(): string {
  const user = 'XDG_RUNTIME_DIR="/run/user/$(id -u "$CMUX_TUI_USER")" setpriv --reuid="$CMUX_TUI_USER" --regid="$CMUX_TUI_USER" --init-groups env HOME="$CMUX_TUI_HOME" USER="$CMUX_TUI_USER" LOGNAME="$CMUX_TUI_USER"';
  return [
    cmuxTuiLayoutSelector(),
    'if [ "$CMUX_TUI_LAYOUT" != user ]; then echo acpmux-login-env-no-service; exit 0; fi',
    'cache="$CMUX_TUI_HOME/.acpmux/login-env.json"',
    // acpmuxHarnessChecksDoneCommand waits for this start's harness check to write it again.
    'health="$CMUX_TUI_HOME/.acpmux/harness-health.json"',
    'rm -f "$cache" "$health"',
    `${user} systemctl --user restart acpmux.service`,
    'i=0; while [ "$i" -lt 60 ] && [ ! -s "$cache" ]; do i=$((i + 1)); sleep 1; done',
    'test -s "$cache" || { echo "acpmux did not read the login shell after its restart" >&2; exit 1; }',
    'grep -q OPENAI_API_KEY "$cache" || { echo "acpmux login environment lacks OPENAI_API_KEY" >&2; exit 1; }',
    "echo acpmux-login-env-fresh",
  ].join(" && ");
}

/**
 * acpmux's restart (acpmuxLoginEnvRefreshCommand) starts its harness check once it has read the login shell
 * (hub/health_view.rs run_health): every harness's `--version` and sign-in check, run by the daemon (probe.rs).
 * Those programs may write under /tmp, and a write that lands after clean ships in the snapshot (image roll
 * 42888042827: /tmp/opencode). The check saves `<acpmux home>/harness-health.json` once every probe has exited
 * (harness_health/mod.rs check, save), and the refresh removed that file before the restart, so its return is this
 * start's finished check. acpmux keeps running for the snapshot (snapshotReadyCommand).
 */
export function acpmuxHarnessChecksDoneCommand(limitSeconds = 180): string {
  return [
    cmuxTuiLayoutSelector(),
    'if [ "$CMUX_TUI_LAYOUT" != user ]; then echo acpmux-harness-checks-no-service; exit 0; fi',
    'health="$CMUX_TUI_HOME/.acpmux/harness-health.json"',
    `i=0; while [ "$i" -lt ${limitSeconds} ] && [ ! -s "$health" ]; do i=$((i + 1)); sleep 1; done`,
    `if [ ! -s "$health" ]; then echo "acpmux's harness check did not finish in ${limitSeconds}s (no $health); its processes:" >&2; ps -o pid,ppid,lstart,args -u "$CMUX_TUI_USER" >&2; exit 1; fi`,
    'echo "acpmux-harness-checks-done after ${i}s"',
  ].join(" && ");
}

/**
 * harness-health.json marks the end of the `--version` and sign-in checks, not of the model probes the same start
 * runs (hub/model_probe.rs for the ACP harnesses, hub/live_models.rs for Claude and Codex): each spawns its CLI,
 * which writes under /tmp (/tmp/opencode, /tmp/claude-<uid>, /tmp/cursor-agent-logs-<uid>), for up to 60 s before
 * acpmux kills it. A probe still running at clean writes again after tmp-empty and fails tmp-no-writer. Every probe
 * runs in `<acpmux home>/unattended` (protected_folders.rs unattended_cwd), so wait until no process of the daemon
 * user has its cwd there. At the bound, name the probes still running and stop them (TERM, then KILL): a probe CLI
 * that hangs past acpmux's own kill (2026-11-26 roll 45732114266: two `cursor-agent acp` probes alive after 120 s)
 * is the bake's own process and must not fail the roll; only a probe that survives KILL does. `unattended` is for
 * tests.
 */
export function acpmuxProbesQuietCommand(limitSeconds = 120, unattended?: string): string {
  const dir = unattended === undefined ? '"$CMUX_TUI_HOME/.acpmux/unattended"' : sq(unattended);
  // One find over /proc (a readlink per process forks hundreds of times); -lname matches the cwd link's target.
  const probes = [
    'find /proc -mindepth 2 -maxdepth 2 -name cwd \\( -lname "$dir" -o -lname "$dir/*" \\) 2>/dev/null | while IFS= read -r c; do',
    '  pid="${c#/proc/}"; pid="${pid%%/*}"; echo "  probe pid $pid: $(tr \'\\0\' \' \' < "/proc/$pid/cmdline" 2>/dev/null)"',
    "done",
  ].join("\n");
  return [
    ...(unattended === undefined ? [cmuxTuiLayoutSelector(), 'if [ "$CMUX_TUI_LAYOUT" != user ]; then echo acpmux-probes-no-service; exit 0; fi'] : []),
    `dir=${dir}`,
    `probes() {\n${probes}\n}`,
    `i=0; while [ "$i" -lt ${limitSeconds} ] && [ -n "$(probes)" ]; do i=$((i + 1)); sleep 1; done`,
    `left="$(probes)"`,
    'if [ -z "$left" ]; then echo "acpmux-probes-quiet after ${i}s"; exit 0; fi',
    `echo "acpmux's model probes still run after ${limitSeconds}s; stopping them:"; printf '%s\\n' "$left"`,
    `stop() { for p in $(probes | sed -n 's/^  probe pid \\([0-9]*\\):.*/\\1/p'); do kill "-$1" "$p" 2>/dev/null || true; done; }`,
    'stop TERM; j=0; while [ "$j" -lt 5 ] && [ -n "$(probes)" ]; do j=$((j + 1)); sleep 1; done',
    'if [ -n "$(probes)" ]; then stop KILL; j=0; while [ "$j" -lt 5 ] && [ -n "$(probes)" ]; do j=$((j + 1)); sleep 1; done; fi',
    `left="$(probes)"; if [ -n "$left" ]; then echo "acpmux's model probes survived KILL:" >&2; printf '%s\\n' "$left" >&2; exit 1; fi`,
    'echo "acpmux-probes-quiet after ${i}s (stopped the rest)"',
  ].join(" && ");
}

/**
 * The fresh image's df, inodes and depth-2 du (disk-record.ts), after clean and before the snapshot: in the image
 * record as `disk` and alone as disk-<name>.json. Information only: a failure is recorded, never fails the bake.
 */
async function recordDisk(ctx: Ctx): Promise<void> {
  const { vm, L, options, result, name } = ctx;
  try {
    const disk = parseDiskOutput(await L.step(vm, "disk-record", DISK_RECORD_COMMAND), { image: name, measured_at: new Date().toISOString(), source: "bake" });
    result.disk = disk;
    writeFileSync(path.join(options.outDir, `disk-${name}.json`), `${JSON.stringify(disk, null, 2)}\n`);
  } catch (error) {
    result.diskError = error instanceof Error ? error.message : String(error);
  }
}

async function finalizeAndCollect(ctx: Ctx): Promise<void> {
  const { vm, L, options, result, name, lock } = ctx;
  await L.step(vm, "identity-final", devboxIdentityCheckCommand());
  await L.step(vm, "image-stamp", `printf '%s\\n' ${sq(`cmux-vm inputs=${lockDigest(ctx.lockText)} ${name} ${new Date().toISOString()}`)} > /etc/cmux/image-stamp && cat /etc/cmux/image-stamp`);
  ctx.result.imagePackages = (await L.step(vm, "image-packages", imagePackagesCommand())).trim();
  await L.step(vm, "apt-sources-live", `mv -f /etc/apt/ubuntu.sources.live /etc/apt/sources.list.d/ubuntu.sources && printf 'Types: deb\\nURIs: https://apt.postgresql.org/pub/repos/apt\\nSuites: noble-pgdg\\nComponents: main\\nSigned-By: ${PGDG_KEY}\\n' > /etc/apt/sources.list.d/pgdg.sources && rm -f /root/base-dpkg.tsv /root/after-dpkg.tsv`);
  result.dfBeforeClean = (await L.step(vm, "df-before-clean", "df -B1 --output=used / | tail -1")).trim();
  await writeGuestFile(vm, "/root/cmux-clean.py", readFileSync(path.join(GUEST_DIR, "clean.py")), 0o755);
  const clean = await L.step(vm, "clean", `python3 /root/cmux-clean.py && rm -f /root/cmux-clean.py && ${devboxJournalResetCommand}`);
  result.clean = JSON.parse(clean.split("CLEAN_JSON ")[1].split("\n")[0]);
  // What the image ships, whether the agents layer was built this run or came from cache.
  result.npmCacheMb = Number((await L.step(vm, "npm-cache-size", npmCacheSizeCommand())).trim());
  // The SBOM and file manifest: here, or after the snapshot on the same builder (--defer-inventory).
  if (!options.deferInventory) await collectInventory(vm, L, options, lock, result, name);
  await L.step(vm, "tmp-empty", `rm -rf /tmp/cmux-out /tmp/cmux-out-syft /root/.cache && ${TMP_LEFTOVERS} | head -5; test -z "$(${TMP_LEFTOVERS})"`);
  result.dfAfterClean = (await L.step(vm, "df-after-clean", "df -B1 --output=used,iused / | tail -1")).trim();
  await recordDisk(ctx);
  result.fstrim = (await L.step(vm, "fstrim", "fstrim -v / 2>&1 || true")).trim();
  result.pageCache = (await L.step(vm, "drop-cache-warm-bind-path", warmBindPathCommand())).trim();
  await L.step(vm, "tmp-no-writer", tmpWritersCommand());
  await L.step(vm, "snapshot-ready", snapshotReadyCommand());
  await L.step(vm, "machine-health-arm", MACHINE_HEALTH_ARM_COMMAND);
}

/**
 * The SBOM and file-hash manifest of the final tree, written under /tmp (excluded from both) and downloaded.
 * With --defer-inventory it runs on the builder right after the snapshot (inventory.ts, beside the smoke), so the
 * tree it reads is the snapshot's: nothing else runs on the builder in between.
 */
/** The error the collect throws when a step rejected, if any: a step that ran and failed wins over the other step's
 * cut connection, so inventory.ts never retries past a guest failure. */
export function inventoryFailure(settled: ReadonlyArray<PromiseSettledResult<unknown>>): unknown {
  const failed = settled.filter((s): s is PromiseRejectedResult => s.status === "rejected").map((s) => s.reason as unknown);
  return failed.find((reason) => /\bstep \S+ failed\b/.test(String(reason))) ?? failed[0];
}

/**
 * Fetch and unpack syft into `dir`, resuming a download a capped run left there: a whole file is kept, a partial one
 * continues (`curl -C -`), a whole file with the wrong sha256 is removed so the next run starts over.
 */
export function syftFetchCommand(syft: { url: string; sha256: string; size: number }, dir: string): string {
  const tgz = `${dir}/syft.tgz`;
  return [
    `mkdir -p ${dir}`,
    `{ test "$(stat -c %s ${tgz} 2>/dev/null)" = ${syft.size} || curl -fsSL --retry 3 -C - -o ${tgz} ${sq(syft.url)}; }`,
    `{ printf '%s  %s\\n' ${syft.sha256} ${tgz} | sha256sum -c --quiet - || { rm -f ${tgz}; false; }; }`,
    `test "$(stat -c %s ${tgz})" = ${syft.size}`,
    `tar -xzf ${tgz} -C ${dir} syft`,
    `test -x ${dir}/syft`,
  ].join(" && ");
}

export async function collectInventory(vm: Vm, L: StepLog, options: Pick<BakeOptions, "devTree" | "outDir">, lock: InputsLock, result: Record<string, unknown>, name: string, out = "/tmp/cmux-out"): Promise<void> {
  const syft = lock.tools.syft;
  await L.step(vm, "out-dir", `mkdir -p ${out}`);
  await writeGuestFile(vm, `${out}/manifest.py`, readFileSync(path.join(GUEST_DIR, "manifest.py")), 0o755);
  // The dev tree is the recorded commit, public crates and toolchains (result.devTree), not hashed or catalogued file by file.
  const skip = options.devTree ? devTreeUserPaths(devTreeLock(lock)) : [];
  // Both read the final tree and write only under /tmp (which both exclude), so they run at once. A retry (inventory.ts)
  // passes its own OUT, so a cut-off try still running on the guest never shares its files.
  // allSettled: neither step is left running here when this throws.
  // syft comes from GitHub releases, which ran at about 100 KB/s into the builder on 2026-11-23: its 29 MB took about
  // 230 s of the sbom step's 285 s in roll 45119294989 and pushed it past the guest's 5-minute exec cap in roll
  // 45126299464 (status 124). The download is its own resumed, retried step (installStoreProgram); the scan follows.
  const scanSbom = async (): Promise<string> => {
    await installStoreProgram(L, vm, "sbom-syft", syftFetchCommand(syft, `${out}-syft`));
    return L.step(vm, "sbom", [
    "t=$(date +%s)",
    `cd / && SYFT_CHECK_FOR_APP_UPDATE=false HOME=${out}-syft timeout 280 ${out}-syft/syft scan dir:/ --select-catalogers +javascript-package-cataloger --exclude './proc/**' --exclude './sys/**' --exclude './dev/**' --exclude './run/**' --exclude './tmp/**' ${skip.map((p) => `--exclude ${sq(`.${p}/**`)}`).join(" ")} -o cyclonedx-json=${out}/sbom.cdx.json -q`,
    "echo syft-secs $(( $(date +%s) - t ))",
    `gzip -9f ${out}/sbom.cdx.json`,
  ].join(" && "));
  };
  const settled = await Promise.allSettled([L.step(vm, "file-manifest", `python3 ${out}/manifest.py ${out}/manifest.tsv ${skip.map(sq).join(" ")} && gzip -9f ${out}/manifest.tsv`), scanSbom()]);
  const failed = inventoryFailure(settled);
  if (failed !== undefined) throw failed;
  const [manifest, sbomOut] = settled.map((s) => (s as PromiseFulfilledResult<string>).value);
  result.manifest = manifest.trim();
  result.syft = sbomOut.trim();
  const sbomFile = path.join(options.outDir, `sbom-${name}.cdx.json`);
  const manifestFile = path.join(options.outDir, `manifest-${name}.tsv`);
  Object.assign(result, { sbomFile, manifestFile });
  writeFileSync(sbomFile, gunzipSync(Buffer.from(await vm.fs.readFile(`${out}/sbom.cdx.json.gz`))));
  writeFileSync(manifestFile, gunzipSync(Buffer.from(await vm.fs.readFile(`${out}/manifest.tsv.gz`))));
  const sbom = JSON.parse(readFileSync(sbomFile, "utf8")) as { components?: unknown[] };
  result.sbomComponents = sbom.components?.length ?? 0;
  await L.step(vm, "inventory-tmp-clean", `rm -rf ${out} ${out}-syft`);
}

/** Every step of a full bake, from the provider base to the finalized tree (before the snapshot). */
async function baseSteps(ctx: Ctx): Promise<void> {
  const { options, L, result } = ctx;
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
  await installMetadataGuard(ctx);
  await configureSshd(ctx);
  if (options.teamVm) ctx.result.teamFilesRoot = (await L.step(ctx.vm, "team-files-root", teamVmDirsCommand())).trim();
  await configureRoles(ctx);
  if (options.agentTools) await installAgentTools(ctx);
  // A layered bake fills it in the agents layer (overlaySteps), not twice.
  if (!options.layered) await installGraduated(ctx);
  if (!options.layered) await prefillDepCaches(ctx);
  if (options.devTree) await installDevTree(ctx);
  await installMachineHealth(ctx);
  await installChiefHost(ctx);
  await installHostConfig(ctx);
  await startDaemon(ctx);
  await writeModelPlane(ctx);
  await finalizeAndCollect(ctx);
}

/**
 * An overlay layer on a parent clone (layers.ts): the layer's store entries swapped in (an unchanged pin is
 * already on disk), the profile flipped, the parent's replaced entries pruned, then the steps that read them.
 * The agents layer reruns what reads agent pins (roles manifest, agent-tools links); the app layer reruns
 * what reads cmux-tui, and the finalize, as a full bake runs them.
 */
async function overlaySteps(ctx: Ctx, layer: "agents" | "app"): Promise<void> {
  const { vm, L, lock } = ctx;
  const programs = bakedPrograms(lock).filter((p) => isAppProgram(p.name) === (layer === "app"));
  await L.step(vm, `${layer}-prepare`, overlayPrepareCommand(programs.flatMap((p) => Object.keys(p.bin))));
  await parallelSteps(programs.map((p) => () => installStoreProgram(L, vm, `store-${p.name}`, cachedInstallCommand(storeEntry(p.sha256), programInstallCommand(p), p.name))));
  await L.step(vm, "store-profile", `${profileCommand(lock)} && chown -R root:root /opt/cmux`);
  await L.step(vm, `${layer}-prune`, overlayPruneCommand());
  if (layer === "agents") {
    await configureRoles(ctx);
    if (ctx.options.agentTools) await installAgentTools(ctx);
    await installGraduated(ctx);
    await prefillDepCaches(ctx);
    await L.step(vm, "agents-done", "rm -rf /tmp/cmux-dl && echo agents-layer-ok");
    return;
  }
  await wireCmuxTui(ctx);
  await installChiefHost(ctx);
  await installHostConfig(ctx);
  await startDaemon(ctx);
  await writeModelPlane(ctx);
  await finalizeAndCollect(ctx);
}

/** Run `jobs` at most `width` at a time (separate guest execs); the first failure fails the batch after the rest settle. */
async function parallelSteps(jobs: Array<() => Promise<unknown>>, width = STORE_PARALLEL): Promise<void> {
  const queue = [...jobs];
  const errors: unknown[] = [];
  await Promise.all(Array.from({ length: Math.min(width, queue.length) }, async () => {
    for (let job = queue.shift(); job; job = queue.shift()) await job().catch((error) => errors.push(error));
  }));
  if (errors.length > 0) throw errors[0];
}

/** Store downloads at once: each is one curl and unpack, bound by the mirror's per-connection speed, not the VM. */
const STORE_PARALLEL = 6;

/** The repository root (layers.ts reads the base inputs' blobs from git here). */
const REPO_ROOT = path.resolve(HERE, "../../..");

/** The flags that change what the base layer holds. */
export function layerFlags(options: BakeOptions): string[] {
  return [options.agentTools && "agent-tools", options.teamVm && "team-vm", options.devTree && "dev-tree"].filter((f): f is string => Boolean(f));
}

/**
 * The image's inputs_sha256 (layers.ts imageInputsSha256) from the lock, this bake's layerFlags and the input
 * tree. The full and the layered bake both call this, so one lock gives one value. Undefined where the key would
 * not cover the image: --dev-tree carries a checkout of this commit, and --update-lock can rewrite the lock
 * mid-bake. The platform then falls back to the image's id@revision.
 */
export function bakeInputsSha256(options: BakeOptions, lockText: string, inputTree: string): string | undefined {
  if (options.devTree || options.updateLock) return undefined;
  return imageInputsSha256(lockText, layerFlags(options), inputTree);
}

/** Every snapshot on the account, page by page (one default page can miss a cached layer's slug). */
async function allSnapshots(fs: ReturnType<typeof freestyleClient>): Promise<Array<{ id: string; slug?: string | null }>> {
  const all: Array<{ id: string; slug?: string | null }> = [];
  for (let offset = 0; ; offset += SNAPSHOT_PAGE) {
    const page = await fs.vms.snapshots.list({ limit: SNAPSHOT_PAGE, offset });
    all.push(...page.snapshots);
    if (page.snapshots.length < SNAPSHOT_PAGE || all.length >= (page.totalCount ?? Infinity)) return all;
  }
}
const SNAPSHOT_PAGE = 100;

/**
 * The large image (large-image.ts): the builder, already snapshotted as the image, grown to LARGE_IMAGE_SHAPE and
 * snapshotted again as `<name>-large`. Only the resize and checks run in between, so both snapshots hold one tree;
 * the checks that guard the image's snapshot (nothing writing under /tmp, no per-machine file, the health timer
 * armed with no pass recorded) run again right before this one.
 */
async function snapshotLarge(vm: Vm, name: string, options: BakeOptions, ledger: Ledger, L: StepLog, parentSlug?: string): Promise<LargeImageRecord> {
  const t0 = Date.now();
  const largeName = largeImageName(name);
  const grow = await growToShape(vm);
  L.log(`LARGE grow ${JSON.stringify(grow)}`);
  // The memory guards are percentages systemd resolved at the small size: reload them, and refuse a stale one.
  const guards = memoryGuardProblems(await L.step(vm, "large-memory-guards", MEMORY_GUARD_REFRESH_COMMAND));
  if (guards.length > 0) throw new Error(`the memory guards did not follow the new size: ${guards.join("; ")}`);
  const rootDevice = (await L.step(vm, "large-root-device", ROOT_DEVICE_COMMAND)).trim();
  await L.step(vm, "large-tmp-no-writer", tmpWritersCommand());
  await L.step(vm, "large-snapshot-ready", snapshotReadyCommand());
  await L.step(vm, "large-machine-health-arm", MACHINE_HEALTH_ARM_COMMAND);
  const tSnap = Date.now();
  // The same parent label as the image's own snapshot, so gc-layers.ts keeps the layers this one was built on.
  const snap = await vm.snapshot({ displayName: options.layered ? layerLabel(largeName, parentSlug) : largeName, slug: largeName });
  if (!snap?.snapshotId) throw new Error("large snapshot response carried no id");
  ledger.record(snap.snapshotId, "snapshot", largeName);
  const snapshotMs = Date.now() - tSnap;
  L.log(`SNAPSHOT ${largeName} ${snap.snapshotId} (${snapshotMs} ms)`);
  return { name: largeName, snapshotId: snap.snapshotId, size: { ...LARGE_IMAGE_SHAPE }, grow, rootDevice, snapshotMs, ms: Date.now() - t0 };
}

/**
 * One builder from `from`, `steps` on it, its snapshot slugged `name`; the builder is deleted unless kept. With
 * `large`, the builder is then grown and snapshotted again (snapshotLarge) and the outcome goes into `large.into`.
 */
async function bakeOn(
  fs: ReturnType<typeof freestyleClient>,
  ledger: Ledger,
  from: string,
  name: string,
  options: BakeOptions,
  steps: (vm: Vm) => Promise<void>,
  result: Record<string, unknown>,
  L: StepLog,
  keepForInventory = false,
  parentSlug?: string,
  large?: { ledger: Ledger; into: Record<string, unknown> },
): Promise<string> {
  let builder: Awaited<ReturnType<typeof createVm>> | null = null;
  let kept = false;
  try {
    builder = await createVm(fs, ledger, { name, snapshotId: from, allowUnprefixed: options.promotion || options.prodCopy === true });
    result.builderVmId = builder.vmId;
    // A layer's builder boots its parent: this is what a chain of snapshots costs per link.
    result.builderFirstExecMs = await firstExec(builder.vm, builder.t0);
    await steps(builder.vm);
    const tSnap = Date.now();
    // A layered snapshot records its parent layer in its label (layers.ts layerLabel), which gc-layers.ts follows
    // so it never deletes a layer a kept image was built on.
    const snap = await builder.vm.snapshot({ displayName: options.layered ? layerLabel(name, parentSlug) : name, slug: name });
    if (!snap?.snapshotId) throw new Error("snapshot response carried no id");
    ledger.record(snap.snapshotId, "snapshot", name);
    result.snapshotMs = Date.now() - tSnap;
    L.log(`SNAPSHOT ${name} ${snap.snapshotId} (${result.snapshotMs} ms)`);
    // After the image's own snapshot, which it cannot change. The builder may be left grown: the inventory reads
    // files, and no file differs.
    if (large) {
      try {
        large.into.large = await snapshotLarge(builder.vm, name, options, large.ledger, L, parentSlug);
      } catch (error) {
        large.into.largeError = String(error);
        L.log(`LARGE IMAGE FAILED (the image ${name} is unaffected): ${large.into.largeError}`);
      }
    }
    // inventory.ts reads this builder next and deletes it; the run's cleanup deletes it from the ledger if not.
    kept = keepForInventory;
    if (kept) result.inventoryVmId = builder.vmId;
    return snap.snapshotId;
  } finally {
    if (builder && !options.keepBuilder && !kept) await deleteVm(builder.vm, builder.vmId, name, ledger);
  }
}

/** Bakes one snapshot. Never throws: failures land in result.error; the builder is always deleted. */
export async function bake(options: BakeOptions): Promise<BakeResult> {
  mkdirSync(options.outDir, { recursive: true });
  const lockText = readFileSync(options.lockPath, "utf8");
  const lock = parseInputsLock(lockText);
  const sha = (process.env.GITHUB_SHA ?? "0000000000").toLowerCase();
  const name = imageResourceName({ promotion: options.promotion, prodCopy: options.prodCopy, tag: options.tag, date: new Date().toISOString().slice(0, 10).replace(/-/g, ""), sha });
  const ledger = new Ledger(path.join(options.outDir, "resources.tsv"));
  const L = new StepLog(path.join(options.outDir, `bake-${name}.log`));
  // lockPath: inventory.ts reads the same lock (its Syft pin) after a deferred snapshot.
  const result: BakeResult = { name, lockSha256: lockDigest(lockText), base: lock.base.snapshot, lockPath: options.lockPath };
  const fs = freestyleClient();
  const t0 = Date.now();
  const ctxFor = (vm: Vm, as: string): Ctx => ({ vm, L, lock, lockText, options, result, name: as });
  // A ledger of its own (as the cached layers have): the run keeps or deletes the large snapshot by its own smoke.
  const large = options.large ? { ledger: new Ledger(path.join(options.outDir, "large", "resources.tsv")), into: result } : undefined;
  try {
    // --agent-tools needs the cmux-rd release pinned: fail before any builder exists.
    if (options.agentTools) {
      agentToolsFiles(lock);
      result.desktop = desktopRecord(lock);
    }
    // The full bake records the key too, but needs no git for it: without the tree it records none.
    let inputTree: string | undefined;
    try {
      inputTree = baseInputTree(REPO_ROOT);
    } catch (error) {
      if (options.layered) throw error;
      L.log(`no inputs_sha256: ${String(error)}`);
    }
    if (inputTree !== undefined) result.inputsSha256 = bakeInputsSha256(options, lockText, inputTree);
    if (options.layered) {
      // layers.ts: system -> agents -> app. A cached layer is reused by its slug; a missing one is built on its
      // parent and kept (its builder is on a ledger of its own, which the run's cleanup never reads).
      const keys = layerKeys(lockText, layerFlags(options), inputTree!);
      const layerLedger = new Ledger(path.join(options.outDir, "layers", "resources.tsv"));
      const snapshots = await allSnapshots(fs);
      const layers: Array<Record<string, unknown>> = [];
      result.layers = layers;
      let parent = lock.base.snapshot;
      let parentSlug: string | undefined;
      for (const layer of ["system", "agents"] as LayerName[]) {
        const slug = layerName(layer, keys[layer]);
        const cached = snapshots.find((snapshot) => snapshot.slug === slug)?.id;
        const row: Record<string, unknown> = { layer, key: keys[layer], slug, hit: Boolean(cached), parent };
        layers.push(row);
        L.log(cached ? `LAYER HIT ${layer} ${slug} ${cached}` : `LAYER MISS ${layer} ${slug}: building on ${parent}`);
        if (!cached) {
          const t = Date.now();
          const steps = layer === "system" ? (vm: Vm) => baseSteps(ctxFor(vm, slug)) : (vm: Vm) => overlaySteps(ctxFor(vm, slug), "agents");
          parent = await bakeOn(fs, layerLedger, parent, slug, options, steps, row, L, false, parentSlug);
          row.ms = Date.now() - t;
        } else parent = cached;
        row.snapshotId = parent;
        parentSlug = slug;
      }
      const app: Record<string, unknown> = { layer: "app", hit: false, parent };
      layers.push(app);
      const t = Date.now();
      result.snapshotId = await bakeOn(fs, ledger, parent, name, options, (vm) => overlaySteps(ctxFor(vm, name), "app"), app, L, Boolean(options.deferInventory), parentSlug, large);
      if (app.inventoryVmId) result.inventoryVmId = app.inventoryVmId;
      app.ms = Date.now() - t;
      app.snapshotId = result.snapshotId;
    } else {
      result.snapshotId = await bakeOn(fs, ledger, lock.base.snapshot, name, options, (vm) => baseSteps(ctxFor(vm, name)), result, L, false, undefined, large);
    }
  } catch (error) {
    result.error = String(error);
    L.log(`BAKE FAILED: ${result.error}`);
  }
  result.bakeMs = Date.now() - t0;
  result.steps = L.steps;
  writeFileSync(path.join(options.outDir, `bake-${name}.json`), `${JSON.stringify(result, null, 2)}\n`);
  L.log(`BAKE_DONE ${name} ${(Number(result.bakeMs) / 1000).toFixed(1)}s snapshot=${result.snapshotId ?? "none"}`);
  return result;
}

/**
 * --large, refused with the flags it has no image for: the large image is a personal Cloud machine's default size;
 * a team image, a dev tree, a production copy and a promotion have none yet.
 */
function largeFlag(argv: string[]): boolean {
  if (!hasFlag("--large", argv)) return false;
  const other = ["--promotion", "--prod-copy", "--team-vm", "--dev-tree"].find((flag) => hasFlag(flag, argv));
  if (other) throw new Error(`--large is for dev snapshots of the personal Cloud image; it cannot be combined with ${other}`);
  return true;
}

export function bakeOptionsFromArgv(argv = process.argv): BakeOptions {
  const tag = argValue("--tag", argv);
  if (!tag) throw new Error("usage: bake.ts --tag <tag> [--out-dir <dir>] [--lock <path>] [--update-lock] [--keep-builder] [--promotion] [--prod-copy] [--agent-tools] [--team-vm] [--dev-tree] [--layered [--defer-inventory]] [--large]");
  if (hasFlag("--prod-copy", argv) && hasFlag("--promotion", argv)) throw new Error("--prod-copy cannot be combined with --promotion");
  if (hasFlag("--layered", argv) && (hasFlag("--prod-copy", argv) || hasFlag("--promotion", argv) || hasFlag("--update-lock", argv))) throw new Error("--layered is for dev snapshots from a fixed lock; the full bake makes production copies and promotions");
  if (hasFlag("--defer-inventory", argv) && !hasFlag("--layered", argv)) throw new Error("--defer-inventory needs --layered; the full bake records its SBOM and manifest before the snapshot");
  // The dev tree is a checkout of this commit, so a cached system layer would carry a stale one.
  if (hasFlag("--layered", argv) && hasFlag("--dev-tree", argv)) throw new Error("--layered cannot cache --dev-tree (a per-commit checkout); use the full bake");
  if (hasFlag("--prod-copy", argv) && hasFlag("--dev-tree", argv)) throw new Error("--dev-tree is for dev snapshots only; it cannot be combined with --prod-copy");
  if (hasFlag("--prod-copy", argv) && hasFlag("--update-lock", argv)) throw new Error("--prod-copy bakes the dev image's lock unchanged; it cannot be combined with --update-lock");
  if (hasFlag("--agent-tools", argv) && hasFlag("--promotion", argv)) throw new Error("--agent-tools is for dev snapshots only; it cannot be combined with --promotion");
  if (hasFlag("--dev-tree", argv) && hasFlag("--promotion", argv)) throw new Error("--dev-tree is for dev snapshots only; it cannot be combined with --promotion");
  const large = largeFlag(argv);
  const promotion = hasFlag("--promotion", argv);
  return {
    tag,
    outDir: path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${tag}`),
    lockPath: path.resolve(argValue("--lock", argv) ?? DEFAULT_LOCK_PATH),
    updateLock: hasFlag("--update-lock", argv),
    keepBuilder: hasFlag("--keep-builder", argv),
    promotion,
    // Cloud Native images always carry the desktop closure. The legacy promotion
    // path is the only image bake that intentionally keeps it off.
    agentTools: !promotion,
    teamVm: hasFlag("--team-vm", argv),
    devTree: hasFlag("--dev-tree", argv),
    prodCopy: hasFlag("--prod-copy", argv),
    layered: hasFlag("--layered", argv),
    deferInventory: hasFlag("--defer-inventory", argv),
    large,
  };
}

/** CLI entry (images/cmux-vm/bake.ts). */
export async function main(argv = process.argv): Promise<number> {
  const result = await bake(bakeOptionsFromArgv(argv));
  if (result.error || !result.snapshotId) return 1;
  console.log(`IMAGE_ID ${result.snapshotId}`);
  // Its own line and prefix: a reader of IMAGE_ID never sees the large image's id.
  const large = result.large as LargeImageRecord | undefined;
  if (large) console.log(`LARGE_IMAGE_ID ${large.snapshotId}`);
  return 0;
}
