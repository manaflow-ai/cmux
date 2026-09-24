import { dirname } from "node:path";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../images/workUser";
import {
  ProviderError,
  ProviderArtifactUnavailableError,
  type CmuxRemoteEndpoint,
  type ExecResult,
  type ProviderId,
} from "./types";

// cmux-tui is the ONE session daemon on every cmux Cloud machine
// (docs/cloud-cmux-tui-daemon.md). This module carries everything about it
// that is not provider-specific: the pinned-manifest source resolution, the
// sha256-verified install command, the daemon command, and the enrollment
// flows, parameterized over a provider exec so freestyle.ts keeps only its
// transport mechanics: how the daemon process is supervised and how port 1337
// is reached from outside.

export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

export const CMUX_TUI_PORT = 1337;
export const CMUX_TUI_SESSION = "cloud";
/**
 * The daemon's cloud listener is reachable only inside the owner's private
 * network (every member is the owner's Mac or another of the owner's machines),
 * so it grants carrier authentication to every link: no device enrollment, no
 * invitation, no approval. The env form is what a systemd drop-in sets on a
 * machine whose baked launch line predates the flag; the daemon reads either.
 */
export const CMUX_TUI_TRUSTED_CARRIER_ENV = "CMUX_TUI_REMOTE_WS_TRUSTED_CARRIER";
export const CMUX_TUI_TRUSTED_CARRIER_FLAG = "--remote-ws-trusted-carrier";
export const CMUX_TUI_INSTALL_TIMEOUT_MS = 5 * 60 * 1000;

/**
 * Terminals on a cmux Cloud machine run as the image's work user, never root:
 * coding agents refuse root outright (`claude --dangerously-skip-permissions`
 * exits before it starts), and root is one passwordless `sudo` away anyway.
 * The user, its home and the machine name are the image contract
 * (services/vms/images/workUser.ts); everything here is the runtime half.
 *
 * Machines created from an image baked before that contract have no such user
 * and carry their daemon, binary and state under /root. Every command below
 * therefore picks the layout ON the machine (cmuxTuiLayoutSelector) instead of
 * assuming one, so one driver serves both until the last legacy machine is
 * recreated.
 */
export const CMUX_CLOUD_USER = DEVBOX_WORK_USER;
export const CMUX_CLOUD_HOME = DEVBOX_WORK_HOME;
/** The home, and so the daemon user, of a machine from a pre-work-user image. */
export const CMUX_TUI_LEGACY_HOME = "/root";
export const CMUX_TUI_BINARY_PATH = `${CMUX_CLOUD_HOME}/.cmux/bin/cmux-tui`;
export const CMUX_TUI_LEGACY_BINARY_PATH = `${CMUX_TUI_LEGACY_HOME}/.cmux/bin/cmux-tui`;
/** Which layout the running daemon chose; a breadcrumb for operators, not an input. */
export const CMUX_TUI_LAYOUT_MARKER_PATH = "/etc/cmux/daemon-layout";

/** Returns the durable cmux-tui binary path for a daemon home. */
export function cmuxTuiBinaryPath(home: string): string {
  return `${home}/.cmux/bin/cmux-tui`;
}

/**
 * Shell that sets CMUX_TUI_USER, CMUX_TUI_HOME, CMUX_TUI_BIN and
 * CMUX_TUI_LAYOUT to the layout this machine can actually serve. The work user
 * is used only when it can do the job it promises: it exists, its home is
 * writable by it, and it really has passwordless sudo. Anything else (a legacy
 * image, a broken sudoers) is the root layout — a degraded but working machine
 * beats a crash-looping daemon or a session trapped unprivileged.
 *
 * Install, pin check, daemon launch and every driver-side `cmux-tui` call run
 * this same selector, so they can never disagree about where the binary and
 * the daemon's state live.
 */
export function cmuxTuiLayoutSelector(): string {
  const user = CMUX_CLOUD_USER;
  const home = CMUX_CLOUD_HOME;
  return (
    `if id -u ${user} >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1 && ` +
    `setpriv --reuid=${user} --regid=${user} --init-groups test -w ${home} 2>/dev/null && ` +
    `setpriv --reuid=${user} --regid=${user} --init-groups sudo -n true >/dev/null 2>&1; then ` +
    `CMUX_TUI_USER=${user}; CMUX_TUI_HOME=${home}; CMUX_TUI_LAYOUT=user; ` +
    `else CMUX_TUI_USER=root; CMUX_TUI_HOME=${CMUX_TUI_LEGACY_HOME}; CMUX_TUI_LAYOUT=root; fi; ` +
    `CMUX_TUI_BIN="$CMUX_TUI_HOME/.cmux/bin/cmux-tui"`
  );
}

/**
 * Runs `cmux-tui <args>` as the daemon's own user, home and state dir. Every
 * driver-side call (status, enrollment, snapshots) goes through this: reading
 * the daemon's state as root when the daemon runs as the work user would find
 * an empty state dir and report a healthy machine as broken.
 */
export function cmuxTuiRunCommand(args: string): string {
  return `${cmuxTuiLayoutSelector()} && ${cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" ${args}`)}`;
}

/**
 * Runs `command` as the daemon's user, via setpriv rather than runuser or su.
 * setpriv EXECs in place, so the daemon is the direct child of its supervisor:
 * signals reach it (runuser does not forward SIGTERM, so stopping the unit
 * SIGKILLed the daemon and left a shutdown record its next start rejected with
 * "shutdown outcome belongs to a different daemon lifecycle"), `pgrep -f`
 * matches one process instead of a wrapper with a lower pid, and no PAM
 * session is opened and closed for every probe.
 */
export function cmuxTuiAsDaemonUser(command: string, options?: { readonly exec?: boolean }): string {
  // `exec` has to prefix the whole chain, not sit inside it: as an argument to
  // env it would name a program called "exec".
  const run = options?.exec === true ? "exec " : "";
  return (
    `if [ "$CMUX_TUI_USER" = root ]; then ${run}env HOME="$CMUX_TUI_HOME" ${CMUX_TUI_DAEMON_TERMINAL_ENV} ${command}; ` +
    `else ${run}setpriv --reuid="$CMUX_TUI_USER" --regid="$CMUX_TUI_USER" --init-groups ` +
    `env HOME="$CMUX_TUI_HOME" USER="$CMUX_TUI_USER" LOGNAME="$CMUX_TUI_USER" SHELL=/bin/bash ${CMUX_TUI_DAEMON_TERMINAL_ENV} ${command}; fi`
  );
}

/**
 * One commit's Linux build: the daemon binary and its `cmux-tui-hook` helper,
 * both from the same manifest so the hook records a daemon of its own
 * generation writes into the journal.
 */
export type CmuxTuiSource = {
  url: string;
  sha256: string;
  commit: string;
  builtAt: string | null;
  hookUrl: string;
  hookSha256: string;
};

export const CMUX_TUI_LINUX_TARGET = "cmux-tui-x86_64-unknown-linux-musl";
export const CMUX_TUI_HOOK_LINUX_TARGET = "cmux-tui-hook-x86_64-unknown-linux-musl";
/** The marker every cmux-owned coding-agent hook entry carries (agent_hook_install.rs COMMAND_MARKER). */
export const CMUX_TUI_HOOK_MARKER = "cmux-tui-journal-hook";
/**
 * Coding agents whose hooks every machine ships with; `cmux-tui agent hook install`
 * names them. Claude Code and Codex take hook entries in their settings
 * (codex also a trust table in config.toml); OpenCode and pi take a cmux-owned
 * plugin file (~/.config/opencode/plugins/cmux-tui-journal.js,
 * ~/.pi/agent/extensions/cmux-tui-journal.ts). The image ships all four agents.
 */
export const CMUX_TUI_HOOK_PROVIDERS = ["claude", "codex", "opencode", "pi"] as const;

/** Files each provider install writes under the daemon user's HOME (agent_hook_install.rs PROVIDERS). */
export const CMUX_TUI_HOOK_PROVIDER_FILES: Readonly<Record<(typeof CMUX_TUI_HOOK_PROVIDERS)[number], readonly string[]>> = {
  claude: [".claude/settings.json"],
  codex: [".codex/hooks.json", ".codex/config.toml"],
  opencode: [".config/opencode/plugins/cmux-tui-journal.js"],
  pi: [".pi/agent/extensions/cmux-tui-journal.ts"],
};
export const CMUX_TUI_DEFAULT_MANIFEST_URL = "https://files.cmux.com/cmux-tui/latest/manifest.json";
const CMUX_TUI_MANIFEST_CACHE_MS = 5 * 60 * 1000;

/**
 * CMUX_VM_CMUX_TUI_MANIFEST_URL pins a deployment to one commit's manifest
 * (`https://files.cmux.com/cmux-tui/<commit>/manifest.json`) instead of the rolling
 * `latest`. Nothing else is configured by hand: the build and its sha256 come from
 * the manifest the artifacts workflow publishes.
 */
export function cmuxTuiManifestUrl(provider: ProviderId = "freestyle"): string {
  const url = process.env.CMUX_VM_CMUX_TUI_MANIFEST_URL?.trim() || CMUX_TUI_DEFAULT_MANIFEST_URL;
  if (!/^https:\/\//.test(url)) {
    throw new ProviderError(provider, "CMUX_VM_CMUX_TUI_MANIFEST_URL must be an https:// URL");
  }
  return url;
}

/** Parses an artifacts manifest into the Linux source; the binary URL is a sibling of the manifest. */
export function parseCmuxTuiManifest(
  manifestUrl: string,
  manifest: unknown,
  provider: ProviderId = "freestyle",
): CmuxTuiSource {
  const record = manifest && typeof manifest === "object" ? manifest as Record<string, unknown> : {};
  const commit = typeof record.commit === "string" ? record.commit : "";
  const binaries = record.binaries && typeof record.binaries === "object" ? record.binaries as Record<string, unknown> : {};
  const digest = (target: string): string => (typeof binaries[target] === "string" ? (binaries[target] as string).toLowerCase() : "");
  const sha256 = digest(CMUX_TUI_LINUX_TARGET);
  const hookSha256 = digest(CMUX_TUI_HOOK_LINUX_TARGET);
  if (!/^[0-9a-f]{40}$/.test(commit)) {
    throw new ProviderError(provider, `cmux-tui manifest at ${manifestUrl} has no commit`);
  }
  if (!/^[0-9a-f]{64}$/.test(sha256)) {
    throw new ProviderError(provider, `cmux-tui manifest at ${manifestUrl} has no ${CMUX_TUI_LINUX_TARGET} sha256 — publish artifacts from a main with the musl target`);
  }
  if (!/^[0-9a-f]{64}$/.test(hookSha256)) {
    throw new ProviderArtifactUnavailableError(provider, { manifestUrl, target: CMUX_TUI_HOOK_LINUX_TARGET });
  }
  const base = manifestUrl.replace(/\/manifest\.json$/, "");
  return {
    url: `${base}/${CMUX_TUI_LINUX_TARGET}`,
    sha256,
    commit,
    builtAt: typeof record.builtAt === "string" ? record.builtAt : null,
    hookUrl: `${base}/${CMUX_TUI_HOOK_LINUX_TARGET}`,
    hookSha256,
  };
}

/** The manifest of one published commit, a sibling of the rolling `latest` pointer. */
export function cmuxTuiPinnedManifestUrl(commit: string, provider: ProviderId = "freestyle"): string {
  if (!/^[0-9a-f]{40}$/.test(commit)) {
    throw new ProviderError(provider, `cmux-tui pin commit ${JSON.stringify(commit)} is not a full sha`);
  }
  const url = new URL(cmuxTuiManifestUrl(provider));
  const segments = url.pathname.split("/");
  if (segments.at(-1) !== "manifest.json") {
    throw new ProviderError(provider, `cmux-tui manifest URL ${url.href} does not end in /manifest.json`);
  }
  // `<base>/<pointer>/manifest.json` -> `<base>/<commit>/manifest.json`; a
  // root-level `/manifest.json` gains the commit segment. Origin and query survive.
  if (segments.length >= 3) segments[segments.length - 2] = commit;
  else segments.splice(segments.length - 1, 0, commit);
  url.pathname = segments.join("/");
  return url.href;
}

let cmuxTuiSourceCache: { url: string; fetchedAt: number; source: CmuxTuiSource } | null = null;

/** The Linux daemon build to install, from the manifest (cached 5 min per manifest URL). */
export async function resolveCmuxTuiSource(
  provider: ProviderId = "freestyle",
  manifestUrl: string = cmuxTuiManifestUrl(provider),
): Promise<CmuxTuiSource> {
  if (cmuxTuiSourceCache && cmuxTuiSourceCache.url === manifestUrl && Date.now() - cmuxTuiSourceCache.fetchedAt < CMUX_TUI_MANIFEST_CACHE_MS) {
    return cmuxTuiSourceCache.source;
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
  let manifest: unknown;
  try {
    const response = await fetch(manifestUrl, { signal: controller.signal, cache: "no-store" });
    if (!response.ok) {
      throw new ProviderError(provider, `cmux-tui manifest fetch ${manifestUrl} -> ${response.status}`);
    }
    manifest = await response.json();
  } catch (err) {
    if (cmuxTuiSourceCache?.url === manifestUrl) {
      // A transient manifest outage must not break creates: reuse the last good build.
      return cmuxTuiSourceCache.source;
    }
    throw err instanceof ProviderError ? err : new ProviderError(provider, `cmux-tui manifest fetch ${manifestUrl} failed`, err);
  } finally {
    clearTimeout(timer);
  }
  const source = parseCmuxTuiManifest(manifestUrl, manifest, provider);
  cmuxTuiSourceCache = { url: manifestUrl, fetchedAt: Date.now(), source };
  return source;
}

/** Test hook. */
export function resetCmuxTuiSourceCache(): void {
  cmuxTuiSourceCache = null;
}

/**
 * The userland agent screen-detection plugin (cmux-tui
 * bindings/examples/rust-agent-screen-detection). The daemon runs it as its
 * `agents.plugin` journal plugin: it samples every terminal's process identity
 * and screen, so codex, pi, opencode and claude are detected when they launch,
 * not only at their first hook event (codex emits its first hook at the first
 * prompt). The artifacts workflow publishes it commit-addressed next to
 * cmux-tui, at `cmux-agent-screen-detection/<commit>/manifest.json`.
 */
export const CMUX_AGENT_PLUGIN_ID = "agent-screen-detection";
export const CMUX_AGENT_PLUGIN_BINARY = "cmux-agent-screen-detection";
export const CMUX_AGENT_PLUGIN_ARTIFACT_PREFIX = "cmux-agent-screen-detection";
export const CMUX_AGENT_PLUGIN_LINUX_TARGET = "cmux-agent-screen-detection-x86_64-unknown-linux-musl";
/** `<sha256> <commit>` of the baked plugin, written by the bake and read by the image verifier. */
export const CMUX_AGENT_PLUGIN_PIN_PATH = "/etc/cmux/cmux-agent-plugin-pin";
/** Coding agents the plugin must detect on a Cloud machine; the image ships all four. */
export const CMUX_AGENT_PLUGIN_REQUIRED_DETECTORS = CMUX_TUI_HOOK_PROVIDERS;

/** One commit's Linux build of the agent screen-detection plugin. */
export type CmuxAgentPluginSource = {
  readonly url: string;
  readonly sha256: string;
  readonly commit: string;
  readonly manifestUrl: string;
};

/** A cmux-tui build plus the agent plugin of the SAME commit: what an image installs. */
export type CmuxTuiInstallSource = CmuxTuiSource & { readonly agentPlugin: CmuxAgentPluginSource };

/**
 * The plugin manifest of one commit, derived from the cmux-tui manifest URL so
 * a deployment pin on another origin keeps its origin and query:
 * `<base>/cmux-tui/<pointer>/manifest.json` becomes
 * `<base>/cmux-agent-screen-detection/<commit>/manifest.json`. A cmux-tui
 * manifest outside a `cmux-tui/` prefix has no known plugin location, so it
 * fails closed instead of guessing.
 */
export function cmuxAgentPluginManifestUrl(commit: string, provider: ProviderId = "freestyle"): string {
  const url = new URL(cmuxTuiPinnedManifestUrl(commit, provider));
  const segments = url.pathname.split("/");
  if (segments.length < 4 || segments.at(-3) !== "cmux-tui") {
    throw new ProviderError(
      provider,
      `cmux-tui manifest URL ${url.href} is not under a cmux-tui/ prefix; the agent plugin manifest cannot be derived from it`,
    );
  }
  segments[segments.length - 3] = CMUX_AGENT_PLUGIN_ARTIFACT_PREFIX;
  url.pathname = segments.join("/");
  return url.href;
}

/** Parses a plugin manifest; the commit must equal the daemon's so the two never drift apart. */
export function parseCmuxAgentPluginManifest(
  manifestUrl: string,
  manifest: unknown,
  expectedCommit: string,
  provider: ProviderId = "freestyle",
): CmuxAgentPluginSource {
  const record = manifest && typeof manifest === "object" ? manifest as Record<string, unknown> : {};
  const commit = typeof record.commit === "string" ? record.commit : "";
  if (commit !== expectedCommit) {
    throw new ProviderError(
      provider,
      `agent plugin manifest at ${manifestUrl} is for commit ${JSON.stringify(commit)}, not the daemon's ${expectedCommit}`,
    );
  }
  const binaries = record.binaries && typeof record.binaries === "object" ? record.binaries as Record<string, unknown> : {};
  const raw = binaries[CMUX_AGENT_PLUGIN_LINUX_TARGET];
  const sha256 = typeof raw === "string" ? raw.toLowerCase() : "";
  if (!/^[0-9a-f]{64}$/.test(sha256)) {
    throw new ProviderArtifactUnavailableError(provider, { manifestUrl, target: CMUX_AGENT_PLUGIN_LINUX_TARGET });
  }
  return {
    url: `${manifestUrl.replace(/\/manifest\.json(\?.*)?$/, "")}/${CMUX_AGENT_PLUGIN_LINUX_TARGET}`,
    sha256,
    commit,
    manifestUrl,
  };
}

/** The plugin build published for `commit` (the pinned cmux-tui commit). */
export async function resolveCmuxAgentPluginSource(
  commit: string,
  provider: ProviderId = "freestyle",
): Promise<CmuxAgentPluginSource> {
  const manifestUrl = cmuxAgentPluginManifestUrl(commit, provider);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
  let manifest: unknown;
  try {
    const response = await fetch(manifestUrl, { signal: controller.signal, cache: "no-store" });
    if (!response.ok) {
      throw new ProviderError(provider, `agent plugin manifest fetch ${manifestUrl} -> ${response.status}`);
    }
    manifest = await response.json();
  } catch (err) {
    throw err instanceof ProviderError ? err : new ProviderError(provider, `agent plugin manifest fetch ${manifestUrl} failed`, err);
  } finally {
    clearTimeout(timer);
  }
  return parseCmuxAgentPluginManifest(manifestUrl, manifest, commit, provider);
}

/**
 * The daemon build and the agent plugin of the same commit. An image bake
 * requires both: a machine without the plugin would only see agents after
 * their first hook event.
 */
export async function resolveCmuxTuiInstallSource(
  provider: ProviderId = "freestyle",
  manifestUrl: string = cmuxTuiManifestUrl(provider),
): Promise<CmuxTuiInstallSource> {
  const source = await resolveCmuxTuiSource(provider, manifestUrl);
  const agentPlugin = await resolveCmuxAgentPluginSource(source.commit, provider);
  return { ...source, agentPlugin };
}

/**
 * Installs the pinned cmux-tui binary onto the machine, skipping the download when
 * the installed copy already matches the pin. The VM fetches the ~50 MB static musl
 * binary itself (in-region, seconds) instead of the driver pushing a base64 payload
 * through the provider API on every cold create.
 *
 * Runs as root and installs into the daemon's own home, so a work-user machine
 * gets a binary its sessions can execute (/root is 0700) and a legacy machine
 * keeps the one it already has.
 *
 * The same command installs the coding-agent hooks (`cmuxTuiAgentHooksInstallCommand`),
 * so a machine from the bake and a machine healed on attach both ship them,
 * and the agent screen-detection plugin of the same commit, configured as
 * the daemon user's `agents.plugin` (see agentPluginInstallSteps).
 */
export function cmuxTuiInstallCommand(source: CmuxTuiInstallSource): string {
  const bin = '"$CMUX_TUI_BIN"';
  const tmp = '"$CMUX_TUI_TMP"';
  return [
    cmuxTuiLayoutSelector(),
    `CMUX_TUI_TMP="$CMUX_TUI_BIN.tmp"`,
    `mkdir -p "$(dirname "$CMUX_TUI_BIN")"`,
    `if [ -x ${bin} ] && ${pinnedFile(source.sha256, bin)}; then :; else ${fetchTo(tmp, source.url)} && ${pinnedFile(source.sha256, tmp)} && chmod 755 ${tmp} && mv -f ${tmp} ${bin}; fi`,
    `ln -sfn ${bin} /usr/local/bin/cmux-tui`,
    ...hookHelperInstallSteps(source),
    ...agentPluginBinaryInstallSteps(source.agentPlugin),
    // Only the nodes this install created, never the daemon's state tree.
    `if [ "$CMUX_TUI_USER" != root ]; then chown "$CMUX_TUI_USER:$CMUX_TUI_USER" "$CMUX_TUI_HOME/.cmux" "$CMUX_TUI_HOME/.cmux/bin" ${bin} ${HOOK_BIN} ${AGENT_PLUGIN_BIN} 2>/dev/null || true; fi`,
    `${bin} --version`,
    ...agentHooksInstallSteps(),
    ...agentPluginConfigSteps(source.agentPlugin),
  ].join(" && ");
}

const AGENT_PLUGIN_BIN = '"$CMUX_AGENT_PLUGIN_BIN"';
const AGENT_PLUGIN_TMP = '"$CMUX_AGENT_PLUGIN_TMP"';

/** Sets CMUX_AGENT_PLUGIN_BIN beside the daemon binary; needs cmuxTuiLayoutSelector first. */
function agentPluginBinVar(): string {
  return `CMUX_AGENT_PLUGIN_BIN="$(dirname "$CMUX_TUI_BIN")/${CMUX_AGENT_PLUGIN_BINARY}"`;
}

/** The plugin binary beside the daemon binary, with the same pin discipline. */
function agentPluginBinaryInstallSteps(plugin: CmuxAgentPluginSource): string[] {
  return [
    agentPluginBinVar(),
    `CMUX_AGENT_PLUGIN_TMP="$CMUX_AGENT_PLUGIN_BIN.tmp"`,
    `if [ -x ${AGENT_PLUGIN_BIN} ] && ${pinnedFile(plugin.sha256, AGENT_PLUGIN_BIN)}; then :; else ${fetchTo(AGENT_PLUGIN_TMP, plugin.url)} && ${pinnedFile(plugin.sha256, AGENT_PLUGIN_TMP)} && chmod 755 ${AGENT_PLUGIN_TMP} && mv -f ${AGENT_PLUGIN_TMP} ${AGENT_PLUGIN_BIN}; fi`,
  ];
}

/**
 * Merges `agents.plugin` into the daemon user's cmux-tui config, the same way
 * cmux-tui's own `write_agent_plugin_at_path` does: every other key is kept,
 * an unreadable or non-object file fails the install instead of being
 * replaced, and an unchanged file is not rewritten. The daemon reads
 * `$HOME/.config/cmux/cmux-tui.json`, or legacy `mux.json` when only that
 * exists; the daemon's environment sets neither XDG_CONFIG_HOME nor
 * CMUX_TUI_CONFIG, so neither is consulted here. The revision is the plugin's
 * sha256, so a daemon that re-reads its config restarts a replaced plugin.
 *
 * argv: plugin id, absolute plugin path, revision.
 */
const AGENT_PLUGIN_CONFIG_SCRIPT = [
  "import json, os, sys, tempfile",
  "plugin_id, command, revision = sys.argv[1:4]",
  'directory = os.path.join(os.environ["HOME"], ".config", "cmux")',
  "os.makedirs(directory, exist_ok=True)",
  'preferred = os.path.join(directory, "cmux-tui.json")',
  'legacy = os.path.join(directory, "mux.json")',
  "path = legacy if not os.path.exists(preferred) and os.path.exists(legacy) else preferred",
  "root = {}",
  "if os.path.exists(path):",
  '    with open(path, encoding="utf-8") as handle:',
  "        text = handle.read()",
  "    if text.strip():",
  "        root = json.loads(text)",
  "if not isinstance(root, dict):",
  '    sys.exit(path + " must contain a JSON object")',
  'agents = root.get("agents")',
  "if not isinstance(agents, dict):",
  "    agents = {}",
  'wanted = {"id": plugin_id, "command": [command], "revision": revision}',
  'if root.get("agents") is agents and agents.get("plugin") == wanted:',
  "    sys.exit(0)",
  'agents["plugin"] = wanted',
  'root["agents"] = agents',
  "mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644",
  'descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=".cmux-tui.json.")',
  "try:",
  '    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:',
  "        json.dump(root, handle, indent=2)",
  '        handle.write("\\n")',
  "    os.chmod(temporary, mode)",
  "    os.replace(temporary, path)",
  "except BaseException:",
  "    os.unlink(temporary)",
  "    raise",
].join("\n");

/** Shell that runs the config merge; needs CMUX_AGENT_PLUGIN_BIN and HOME set. */
export function cmuxAgentPluginConfigWriteCommand(revision: string): string {
  return `python3 -c ${shellQuote(AGENT_PLUGIN_CONFIG_SCRIPT)} ${shellQuote(CMUX_AGENT_PLUGIN_ID)} ${AGENT_PLUGIN_BIN} ${shellQuote(revision)}`;
}

/** Creates `dir` as the daemon user's when it does not exist (root creates it; the work user may not own its parent yet). */
function ensureDaemonUserDir(dir: string): string {
  return `{ [ -d ${dir} ] || { mkdir -m 755 ${dir} && { [ "$CMUX_TUI_USER" = root ] || chown "$CMUX_TUI_USER:$CMUX_TUI_USER" ${dir}; }; }; }`;
}

/**
 * Writes the daemon user's `agents.plugin` = {id, command: [<plugin path>],
 * revision: <sha256>} and proves the result. The daemon reads its config only
 * at start, so the bake writes this before it first starts the daemon
 * (cmux-tui-daemon-unit); an install into a machine whose daemon is already
 * running takes effect at the daemon's next start.
 */
function agentPluginConfigSteps(plugin: CmuxAgentPluginSource): string[] {
  return [
    ensureDaemonUserDir('"$CMUX_TUI_HOME/.config"'),
    ensureDaemonUserDir('"$CMUX_TUI_HOME/.config/cmux"'),
    cmuxTuiAsDaemonUser(cmuxAgentPluginConfigWriteCommand(plugin.sha256)),
    cmuxAgentPluginInstalledCheck(),
  ];
}

/**
 * Reads the config file the daemon would read and exits 0 when its
 * `agents.plugin` names this plugin id and exactly the installed binary.
 */
const AGENT_PLUGIN_CONFIG_CHECK_SCRIPT = [
  "import json, os, sys",
  "plugin_id, command = sys.argv[1:3]",
  'directory = os.path.join(os.environ["HOME"], ".config", "cmux")',
  'preferred = os.path.join(directory, "cmux-tui.json")',
  'legacy = os.path.join(directory, "mux.json")',
  "path = legacy if not os.path.exists(preferred) and os.path.exists(legacy) else preferred",
  "with open(path, encoding=\"utf-8\") as handle:",
  "    plugin = json.load(handle)[\"agents\"][\"plugin\"]",
  'sys.exit(0 if plugin.get("id") == plugin_id and plugin.get("command") == [command] else path + ": agents.plugin is " + json.dumps(plugin))',
].join("\n");

/** Exit 0 when the bundled detectors of every required agent are present in the plugin's `list` output. */
const AGENT_PLUGIN_LIST_CHECK_SCRIPT = [
  "import json, sys",
  "required = set(sys.argv[1:])",
  'found = {entry.get("id") for entry in json.load(sys.stdin).get("manifests", [])}',
  'sys.exit(0 if required <= found else "missing detectors: " + ", ".join(sorted(required - found)))',
].join("\n");

/**
 * The installed half of plugin readiness (no daemon needed): the binary
 * beside the daemon is executable, runs on this machine (a static musl build
 * with the default x86-64 baseline) and carries a detector for every shipped
 * agent, and the daemon user's config selects it. Needs the layout selector
 * and CMUX_AGENT_PLUGIN_BIN.
 */
function cmuxAgentPluginInstalledCheck(): string {
  return [
    `test -x ${AGENT_PLUGIN_BIN}`,
    cmuxTuiAsDaemonUser(`${AGENT_PLUGIN_BIN} list`) +
      ` | python3 -c ${shellQuote(AGENT_PLUGIN_LIST_CHECK_SCRIPT)} ${CMUX_AGENT_PLUGIN_REQUIRED_DETECTORS.join(" ")}`,
    cmuxTuiAsDaemonUser(
      `python3 -c ${shellQuote(AGENT_PLUGIN_CONFIG_CHECK_SCRIPT)} ${shellQuote(CMUX_AGENT_PLUGIN_ID)} ${AGENT_PLUGIN_BIN}`,
    ),
  ].join(" && ");
}

/** Exit 0 when the installed plugin matches its pin. */
export function cmuxAgentPluginPinCheckCommand(plugin: Pick<CmuxAgentPluginSource, "sha256">): string {
  return `${cmuxTuiLayoutSelector()} && ${agentPluginBinVar()} && test -x ${AGENT_PLUGIN_BIN} && ${pinnedFile(plugin.sha256, AGENT_PLUGIN_BIN)}`;
}

/** Exit 0 when a journal producer list (any JSON shape) contains the plugin's producer id. */
const AGENT_PLUGIN_PRODUCER_CHECK_SCRIPT = [
  "import json, sys",
  "wanted = sys.argv[1]",
  "def walk(value):",
  "    if isinstance(value, dict):",
  '        return value.get("producer_id") == wanted or any(walk(item) for item in value.values())',
  "    if isinstance(value, list):",
  "        return any(walk(item) for item in value)",
  "    return False",
  "sys.exit(0 if walk(json.load(sys.stdin)) else 1)",
].join("\n");

/**
 * Plugin readiness on a machine with a running daemon, for the bake and the
 * image verifier. Beyond the installed checks, it waits up to `attempts`
 * seconds for both runtime proofs:
 *  - the daemon supervises the plugin: a direct child of the process serving
 *    the cloud session runs the installed binary with
 *    CMUX_PLUGIN_ID=agent-screen-detection in its environment (the daemon
 *    supplies it from `agents.plugin.id`; the plugin exits without it);
 *  - the plugin reached the daemon: the session's journal producer list holds
 *    the plugin's producer, which it registers only after connecting.
 * The producer registration is durable, so on a clone the child-process proof
 * is the one that shows this daemon started it.
 */
export function cmuxAgentPluginReadyCommand(options?: { readonly attempts?: number }): string {
  const attempts = options?.attempts ?? 30;
  const producers = cmuxTuiAsDaemonUser(
    `"$CMUX_TUI_BIN" --session ${CMUX_TUI_SESSION} --json session current journal producer list`,
  );
  const childRunsPlugin =
    `for c in $(pgrep -P "$p" 2>/dev/null); do ` +
    `if [ "$(readlink -f "/proc/$c/exe" 2>/dev/null)" = "$(readlink -f ${AGENT_PLUGIN_BIN})" ] && ` +
    `tr '\\0' '\\n' < "/proc/$c/environ" 2>/dev/null | grep -qx ${shellQuote(`CMUX_PLUGIN_ID=${CMUX_AGENT_PLUGIN_ID}`)}; then ` +
    `cmux_agent_plugin_child=$c; fi; done`;
  return [
    cmuxTuiLayoutSelector(),
    agentPluginBinVar(),
    cmuxAgentPluginInstalledCheck(),
    `cmux_agent_plugin_ready=''; for cmux_agent_plugin_try in $(seq 1 ${attempts}); do ` +
      `cmux_agent_plugin_child=''; ${cmuxTuiDaemonPidSelector()}; ` +
      `if [ -n "$p" ]; then ${childRunsPlugin}; fi; ` +
      `if [ -n "$cmux_agent_plugin_child" ] && { ${producers}; } | python3 -c ${shellQuote(AGENT_PLUGIN_PRODUCER_CHECK_SCRIPT)} ${shellQuote(CMUX_AGENT_PLUGIN_ID)}; then ` +
      `cmux_agent_plugin_ready=1; break; fi; sleep 1; done`,
    `[ -n "$cmux_agent_plugin_ready" ]`,
    `echo "agent-plugin-running pid=$cmux_agent_plugin_child"`,
  ].join(" && ");
}

const HOOK_BIN = '"$CMUX_TUI_HOOK_BIN"';
const HOOK_TMP = '"$CMUX_TUI_HOOK_TMP"';
/** Where `cmux-tui agent hook install` copies the helper for the daemon user (agent_hook_install.rs installed_helper). */
const INSTALLED_HOOK = '"$CMUX_TUI_HOME/.local/share/cmux-tui/bin/cmux-tui-hook"';

function pinnedFile(sha256: string, path: string): string {
  return `printf '%s  %s\n' ${shellQuote(sha256)} ${path} | sha256sum -c >/dev/null 2>&1`;
}

function fetchTo(path: string, url: string): string {
  return (
    `if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o ${path} ${shellQuote(url)}; ` +
    `elif command -v wget >/dev/null 2>&1; then wget -q -O ${path} ${shellQuote(url)}; ` +
    `else false; fi`
  );
}

/**
 * The `cmux-tui-hook` helper lands beside the daemon binary: that is the one
 * place `cmux-tui agent hook install` looks for it without a PATH search
 * (agent_hook_install.rs locate_helper_source). Same pin discipline as the daemon.
 */
function hookHelperInstallSteps(source: CmuxTuiSource): string[] {
  return [
    `CMUX_TUI_HOOK_BIN="$(dirname "$CMUX_TUI_BIN")/cmux-tui-hook"`,
    `CMUX_TUI_HOOK_TMP="$CMUX_TUI_HOOK_BIN.tmp"`,
    `if [ -x ${HOOK_BIN} ] && ${pinnedFile(source.hookSha256, HOOK_BIN)}; then :; else ${fetchTo(HOOK_TMP, source.hookUrl)} && ${pinnedFile(source.hookSha256, HOOK_TMP)} && chmod 755 ${HOOK_TMP} && mv -f ${HOOK_TMP} ${HOOK_BIN}; fi`,
  ];
}

/**
 * Writes the hook entries (Claude Code, Codex) and plugin files (OpenCode, pi)
 * of every CMUX_TUI_HOOK_PROVIDERS agent for the daemon user and copies
 * the helper into that user's data dir, then proves it: the installed helper
 * is byte-equal to the pinned one and every provider config carries the
 * cmux marker. Idempotent (the installer rewrites nothing that already matches).
 * The daemon exports CMUX_TUI_HOOK into every pane it spawns, so no restart is
 * needed for an already running daemon; agents pick the hooks up at their
 * next launch.
 */
function agentHooksInstallSteps(): string[] {
  return [
    cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" agent hook install ${CMUX_TUI_HOOK_PROVIDERS.join(" ")} >/dev/null`),
    cmuxTuiHooksReadyCheck(),
  ];
}

/**
 * Readiness comes from the installer's own structured status, so a hook entry
 * a user edited or reordered (reported `partial`) is repaired instead of
 * passing a text grep; plus the helper beside the daemon must be byte-equal
 * to the one the daemon user runs.
 */
function cmuxTuiHooksReadyCheck(): string {
  const providers = CMUX_TUI_HOOK_PROVIDERS.join(" ");
  const installed = JSON.stringify([...CMUX_TUI_HOOK_PROVIDERS]);
  return [
    `test -x ${INSTALLED_HOOK}`,
    `cmp -s ${HOOK_BIN} ${INSTALLED_HOOK}`,
    cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" --json agent hook status ${providers}`) +
      ` | python3 -c 'import json, sys; r = json.load(sys.stdin); s = {p["provider"]: p["state"] for p in r.get("providers", [])}; sys.exit(0 if all(s.get(i) == "installed" for i in ${installed}) else 1)'`,
  ].join(" && ");
}

/**
 * Hooks alone, for a machine whose daemon is healthy and pinned but predates
 * hook installation: fetch the helper for the daemon's own commit and install
 * the provider entries. Never touches the daemon binary or its state.
 */
export function cmuxTuiAgentHooksInstallCommand(source: CmuxTuiSource): string {
  return [
    cmuxTuiLayoutSelector(),
    ...hookHelperInstallSteps(source),
    `if [ "$CMUX_TUI_USER" != root ]; then chown "$CMUX_TUI_USER:$CMUX_TUI_USER" ${HOOK_BIN} 2>/dev/null || true; fi`,
    ...agentHooksInstallSteps(),
  ].join(" && ");
}

/** Exit 0 when the daemon user's coding-agent hooks are installed and current. */
export function cmuxTuiHooksReadyCommand(): string {
  return `${cmuxTuiLayoutSelector()} && CMUX_TUI_HOOK_BIN="$(dirname "$CMUX_TUI_BIN")/cmux-tui-hook" && ${cmuxTuiHooksReadyCheck()}`;
}

/** True when the installed binary matches the manifest pin (exit 0 from this command). */
export function cmuxTuiPinCheckCommand(source: CmuxTuiSource): string {
  return (
    `${cmuxTuiLayoutSelector()} && ` +
    `test -x "$CMUX_TUI_BIN" && printf '%s  %s\n' ${shellQuote(source.sha256)} "$CMUX_TUI_BIN" | sha256sum -c >/dev/null 2>&1`
  );
}

/**
 * Terminal identity every daemon-spawned pane inherits. The Mac app renders
 * each pane in its embedded Ghostty and exports the same identity to local and
 * SSH shells, so panes get TERM=xterm-256color, TERM_PROGRAM=ghostty, and
 * TERM_PROGRAM_VERSION from /etc/cmux/ghostty-version (the image's Ghostty
 * .deb pin, written by the devbox bake and Dockerfile; empty on images that
 * predate it). The daemon itself adds COLORTERM=truecolor at spawn. Agents
 * gate synchronized output, progress reporting, strikethrough, and Cmd-click
 * on TERM_PROGRAM. cmux-devbox-boot repeats this string byte for byte.
 */
export const CMUX_TUI_DAEMON_TERMINAL_ENV =
  'TERM=xterm-256color TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION="$(cat /etc/cmux/ghostty-version 2>/dev/null)"';

/** The listener bind every container provider uses; cmux-devbox-boot's CMUX_TUI_REMOTE_WS_BIND default. */
export const CMUX_TUI_DEFAULT_REMOTE_WS_BIND = `0.0.0.0:${CMUX_TUI_PORT}`;

/**
 * The daemon command every supervisor runs: cmux-tui as the machine's daemon
 * user, cwd and HOME its home, so every terminal pane it opens is a shell of
 * that user in that home. `remoteWsBind` defaults to the IPv4 wildcard;
 * Freestyle machines are reached at a private VPC address and pass a
 * dual-stack `[::]` bind instead.
 *
 * The layout is chosen on the machine (cmuxTuiLayoutSelector), so a work-user
 * image serves non-root sessions and a machine from a pre-work-user image
 * keeps its root daemon and its /root state until it is recreated. The choice
 * is written to CMUX_TUI_LAYOUT_MARKER_PATH so a machine can be asked which
 * one it took.
 */
export function cmuxTuiDaemonCommand(
  remoteWsBind: string = CMUX_TUI_DEFAULT_REMOTE_WS_BIND,
): string {
  const args = `server start --session ${CMUX_TUI_SESSION} --remote-ws ${remoteWsBind} --remote-ws-insecure-bind ${CMUX_TUI_TRUSTED_CARRIER_FLAG}`;
  return (
    `${cmuxTuiLayoutSelector()}; ` +
    `{ mkdir -p /etc/cmux 2>/dev/null; printf '%s\\n' "$CMUX_TUI_LAYOUT" > ${CMUX_TUI_LAYOUT_MARKER_PATH}; } 2>/dev/null; ` +
    `cd "$CMUX_TUI_HOME" && ` +
    cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" ${args}`, { exec: true })
  );
}

export function parseJsonObject(text: string): Record<string, unknown> {
  try {
    const value = JSON.parse(text.trim());
    return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

export function parseJsonArray(text: string): Array<Record<string, unknown>> {
  try {
    const value = JSON.parse(text.trim());
    return Array.isArray(value)
      ? value.filter((entry): entry is Record<string, unknown> => !!entry && typeof entry === "object")
      : [];
  } catch {
    return [];
  }
}

/**
 * Runs `cmux-tui <args>` inside the VM as the daemon's own user and HOME (the
 * daemon's state home). Each provider supplies its own transport: Freestyle's
 * VM exec API.
 */
export type CmuxTuiInvoke = (args: string, timeoutMs?: number) => Promise<ExecResult>;

export async function waitForCmuxTuiReady(
  invoke: CmuxTuiInvoke,
  provider: ProviderId,
  vmId: string,
): Promise<void> {
  let last = "";
  for (let attempt = 0; attempt < 15; attempt += 1) {
    const status = await invoke(`server status --session ${CMUX_TUI_SESSION}`).catch(() => null);
    if (status?.exitCode === 0) return;
    last = status ? (status.stderr || status.stdout) : "status probe failed";
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new ProviderError(provider, `cmux-tui daemon in ${vmId} did not become ready: ${last}`);
}

/** The installed daemon's build identity and remote protocol, so clients can name a mismatch instead of hanging. */
export async function cmuxTuiDaemonBuild(
  invoke: CmuxTuiInvoke,
): Promise<CmuxRemoteEndpoint["daemonBuild"] | null> {
  const probe = await invoke("remote-probe --json").catch(() => null);
  if (!probe || probe.exitCode !== 0) return null;
  const record = parseJsonObject(probe.stdout);
  const commit = typeof record.build_identity === "string" ? record.build_identity : null;
  const remoteProtocol = typeof record.remote_protocol === "number" ? record.remote_protocol : null;
  const version = typeof record.version === "string" ? record.version : null;
  if (!commit && remoteProtocol === null) return null;
  return { commit, remoteProtocol, version };
}

/** Compatibility invitation mint for older provider callers during trusted-listener rollout. */
export async function mintCmuxTuiInvitation(
  invoke: CmuxTuiInvoke,
  provider: ProviderId,
  vmId: string,
): Promise<NonNullable<CmuxRemoteEndpoint["invitation"]>> {
  const created = await invoke(
    `remote enroll create --session ${CMUX_TUI_SESSION} --ttl 300 --json`,
  );
  if (created.exitCode !== 0) {
    throw new ProviderError(provider, `cmux-tui enrollment invitation in ${vmId} failed: ${created.stderr || created.stdout}`);
  }
  const uri = parseJsonObject(created.stdout).uri;
  if (typeof uri !== "string" || !uri) {
    throw new ProviderError(provider, `cmux-tui enrollment invitation in ${vmId} returned no uri`);
  }
  let parsed: URL;
  try { parsed = new URL(uri); } catch {
    throw new ProviderError(provider, `cmux-tui enrollment invitation in ${vmId} returned an invalid uri`);
  }
  const invitationId = parsed.protocol === "cmux:" && parsed.hostname === "enroll"
    ? parsed.pathname.slice(1)
    : parsed.searchParams.get("id");
  if (!invitationId) {
    throw new ProviderError(provider, `cmux-tui enrollment invitation in ${vmId} returned no id`);
  }
  return { uri, invitationId, expiresAtUnix: Math.floor(Date.now() / 1000) + 300 };
}

/** Compatibility approval bridge for pre trusted-carrier clients. */
export async function approveCmuxTuiEnrollment(
  invoke: CmuxTuiInvoke,
  provider: ProviderId,
  vmId: string,
  invitationId: string,
): Promise<{ approved: boolean; state: "approved" | "pending"; deviceFingerprint?: string }> {
  if (!/^[A-Za-z0-9._:=+/-]+$/.test(invitationId)) {
    throw new ProviderError(provider, "invitation id has an unexpected shape");
  }
  const result = await invoke(
    `remote enroll approve ${shellQuote(invitationId)} --session ${CMUX_TUI_SESSION} --json`,
    40_000,
  );
  if (result.exitCode !== 0) {
    throw new ProviderError(provider, `cmux-tui enrollment approval in ${vmId} failed: ${result.stderr || result.stdout}`);
  }
  const fingerprint = parseJsonObject(result.stdout).fingerprint;
  return {
    approved: true,
    state: "approved",
    ...(typeof fingerprint === "string" && fingerprint ? { deviceFingerprint: fingerprint } : {}),
  };
}

/**
 * Everything attach needs from the daemon in ONE guest exec: an optional
 * readiness gate (exit 3 when it fails, so the caller can run the heal), the
 * daemon build (`remote-probe`), the enrolled devices (so a machine where the
 * caller is already enrolled is never restarted under it), and whether the
 * running daemon serves the trusted-carrier listener. Each section is fenced
 * by a marker line so the outputs parse independently.
 */
export const CMUX_TUI_ATTACH_BUNDLE_NOT_READY_EXIT = 3;
const BUNDLE_MARKERS = { probe: "__CMUX_PROBE__", devices: "__CMUX_DEVICES__", trusted: "__CMUX_TRUSTED__", end: "__CMUX_END__" } as const;

/**
 * Prints `1` when the daemon process that owns the cloud session serves the
 * trusted-carrier listener: it was started with the flag or the env, AND the
 * binary it runs parses the flag (`--remote-ws-trusted-carrier --version`
 * exits 0; an older binary rejects the unknown argument with exit 2 before
 * it reaches `--version`). An older binary ignores the env, so the env alone
 * proves nothing; asking the running binary itself also keeps the answer
 * honest while the pinned manifest and the machine's install disagree.
 * Anything else prints `0`.
 */
export function cmuxTuiDaemonPidSelector(): string {
  // NOT `pgrep ... | head -n1`: when the daemon runs as the work user its
  // launcher is `runuser -u cmux -- … cmux-tui server start …`, whose cmdline
  // matches the same pattern and whose pid is LOWER. Picking that wrapper made
  // the trusted-listener probe exec `runuser --remote-ws-trusted-carrier
  // --version`, which fails, so attach refused a perfectly healthy machine.
  // Select the process that IS the binary; comm is `cmux-tui` on both layouts.
  return (
    "p=''; for cmux_tui_pid in $(pgrep -f 'cmux-tui server [s]tart' 2>/dev/null); do " +
    `if [ "$(cat /proc/$cmux_tui_pid/comm 2>/dev/null)" = cmux-tui ]; then p=$cmux_tui_pid; break; fi; done`
  );
}

export function cmuxTuiTrustedListenerProbe(): string {
  return (
    `${cmuxTuiDaemonPidSelector()}; ` +
    `if [ -n "$p" ] && { tr '\\0' '\\n' < "/proc/$p/environ" 2>/dev/null | grep -qx ${shellQuote(`${CMUX_TUI_TRUSTED_CARRIER_ENV}=1`)} || tr '\\0' '\\n' < "/proc/$p/cmdline" 2>/dev/null | grep -qx -- ${shellQuote(CMUX_TUI_TRUSTED_CARRIER_FLAG)}; }` +
    ` && "/proc/$p/exe" ${CMUX_TUI_TRUSTED_CARRIER_FLAG} --version >/dev/null 2>&1; then echo 1; else echo 0; fi`
  );
}

export function cmuxTuiAttachBundleCommand(options: {
  readonly readyGate?: string;
  readonly deviceFingerprint?: string;
  readonly binary?: string;
}): string {
  // The enrolled-device list lives in the DAEMON's state dir, so every call
  // here has to be the daemon's user and HOME. Reading it as root on a
  // work-user machine would find an empty state dir and report a healthy
  // machine as un-enrolled.
  const bin = options.binary ? shellQuote(options.binary) : '"$CMUX_TUI_BIN"';
  // The arguments go INSIDE the drop-to-user block: it is an `if … fi`
  // compound statement, so anything appended after it is a separate command.
  const run = (args: string) => cmuxTuiAsDaemonUser(`${bin} ${args}`);
  const fingerprint = options.deviceFingerprint?.trim();
  if (fingerprint !== undefined && fingerprint !== "" && !/^[A-Za-z0-9._:=+/-]+$/.test(fingerprint)) {
    throw new Error("device fingerprint has an unexpected shape");
  }
  return [
    // Run the readiness probe in a subshell. The Freestyle gate uses `exit` for
    // its success and failure branches; without a subshell those exits terminate
    // the entire attach bundle before the probe, device, and invitation sections.
    ...(options.readyGate ? [`( ${options.readyGate}; ) || exit ${CMUX_TUI_ATTACH_BUNDLE_NOT_READY_EXIT}`] : []),
    cmuxTuiLayoutSelector(),
    `echo ${BUNDLE_MARKERS.probe}`,
    `${run("remote-probe --json")}; echo`,
    `echo ${BUNDLE_MARKERS.devices}`,
    `${run(`remote enroll devices --session ${CMUX_TUI_SESSION} --json`)}; echo`,
    `echo ${BUNDLE_MARKERS.trusted}`,
    cmuxTuiTrustedListenerProbe(),
    `echo ${BUNDLE_MARKERS.end}`,
  ].join("; ");
}

export type CmuxTuiAttachBundle = {
  readonly daemonBuild: CmuxRemoteEndpoint["daemonBuild"] | null;
  /** The caller's device is on the daemon's enrolled list (only known when a fingerprint was given). */
  readonly enrolled: boolean;
  /** The running daemon grants carrier authentication on its cloud listener. */
  readonly trustedCarrier: boolean;
  /** Legacy invitation field; trusted listeners leave it null. */
  readonly invitation: NonNullable<CmuxRemoteEndpoint["invitation"]> | null;
};

/** Parses the fenced stdout of {@link cmuxTuiAttachBundleCommand}. */
export function parseCmuxTuiAttachBundle(
  stdout: string,
  provider: ProviderId,
  vmId: string,
  deviceFingerprint?: string,
): CmuxTuiAttachBundle {
  const section = (from: string, to: string): string => {
    const start = stdout.indexOf(from);
    const end = stdout.indexOf(to);
    if (start === -1 || end === -1 || end < start) return "";
    return stdout.slice(start + from.length, end).trim();
  };
  const probeText = section(BUNDLE_MARKERS.probe, BUNDLE_MARKERS.devices);
  const devicesText = section(BUNDLE_MARKERS.devices, BUNDLE_MARKERS.trusted);
  const trustedText = section(BUNDLE_MARKERS.trusted, BUNDLE_MARKERS.end);
  let daemonBuild: CmuxTuiAttachBundle["daemonBuild"] = null;
  try {
    const record = parseJsonObject(probeText);
    const commit = typeof record.build_identity === "string" ? record.build_identity : null;
    const remoteProtocol = typeof record.remote_protocol === "number" ? record.remote_protocol : null;
    const version = typeof record.version === "string" ? record.version : null;
    if (commit || remoteProtocol !== null) daemonBuild = { commit, remoteProtocol, version };
  } catch {
    daemonBuild = null;
  }
  let enrolled = false;
  if (deviceFingerprint) {
    try {
      enrolled = parseJsonArray(devicesText).some((device) =>
        device.fingerprint === deviceFingerprint && (device.revoked_at_unix === null || device.revoked_at_unix === undefined)
      );
    } catch {
      enrolled = false;
    }
  }
  // Fail closed: a missing or malformed section means the caller must heal.
  const trustedCarrier = trustedText.split("\n").pop()?.trim() === "1";
  void provider;
  void vmId;
  return { daemonBuild, enrolled, trustedCarrier, invitation: null };
}
