/**
 * Shared plumbing for the cmux Cloud devbox image bake
 * (build-devbox-freestyle.ts), the post-bake verifier
 * (verify-devbox-image.ts), and the promote step (promote-devbox-image.ts).
 *
 * The image source of truth is web/services/vms/images/devbox/: a plain
 * Dockerfile plus the files it COPYs (the desktop layer under desktop/). The
 * pins the Freestyle replay installs (agent versions, the cua driver, the
 * desktop apt packages, the Ghostty .deb) are read from the Dockerfile's ARG
 * and ENV lines here, never kept as a second copy. No daemon binary is baked
 * into the container image: cmux-tui is installed by the drivers at create
 * time from the pinned files.cmux.com manifest
 * (web/services/vms/drivers/cmuxTuiDaemon.ts); the image only ships the
 * cmux-devbox-boot supervisor.
 */
import { execFileSync, execSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { Buffer } from "node:buffer";
import { existsSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { CMUX_TUI_SESSION, cmuxTuiAsDaemonUser, cmuxTuiLayoutSelector, cmuxTuiRunCommand, shellQuote } from "../services/vms/drivers/cmuxTuiDaemon";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../services/vms/images/workUser";
import { VM_IMAGE_SIZES, VM_IMAGE_SIZE_NAMES, vmImageSizeRank, type VmImageSizeName } from "../services/vms/images/sizes";
import { DEVBOX_HOSTNAME, DEVBOX_HOSTNAME_LOOPBACK, DEVBOX_PROVIDER_HOSTNAME } from "../services/vms/images/identity";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const webRoot = path.resolve(__dirname, "..");
export const repoRoot = path.resolve(webRoot, "..");
export const devboxDir = path.join(webRoot, "services/vms/images/devbox");
export const devboxDockerfilePath = path.join(devboxDir, "Dockerfile");

/** Files the Dockerfile COPYs plus the Dockerfile itself; all must exist. */
export const DEVBOX_TEMPLATE_FILES = [
  "Dockerfile",
  "agent-config.sh",
  "chrome-managed-policy.json",
  "cmux-bashrc",
  "cmux-devbox-boot",
  "cmux-motd",
  "cmux-prompt.bash",
  "cmux-terminfo.sh",
  "cmux-terminfo.src",
  "codex-managed.toml",
  "seed-history",
] as const;

/**
 * Proves the guest resolves every TERM name cmux may export to the overlay,
 * including indexed bright colors instead of SGR 90. The explicit path check
 * ensures a stock entry or a user's home directory cannot shadow it.
 */
export const devboxTerminfoCheckCommand = [
  "for t in xterm-ghostty ghostty xterm-256color; do",
  '[ "$(tput -T$t colors)" = 256 ]',
  "&& infocmp -x $t | grep -qw Tc && infocmp -x $t | grep -qw Su",
  "&& infocmp -x $t | head -1 | grep -q /etc/terminfo/",
  "&& [ \"$(tput -T$t setaf 8 | od -An -tx1 | tr -d ' \\n')\" = 1b5b33383b353b386d ]",
  "&& [ \"$(tput -T$t setab 8 | od -An -tx1 | tr -d ' \\n')\" = 1b5b34383b353b386d ]",
  "&& [ \"$(tput -T$t setaf 7 | od -An -tx1 | tr -d ' \\n')\" = 1b5b33376d ]",
  "&& [ \"$(tput -T$t setaf 16 | od -An -tx1 | tr -d ' \\n')\" = 1b5b33383b353b31366d ]",
  '|| { echo "terminfo check failed for $t"; exit 1; }; done && echo terminfo-ok',
].join(" ");

/** Compile the checked-in overlay before any per-TERM cache is seeded. */
export const devboxTerminfoInstallCommand =
  `test -s /etc/cmux/terminfo.src && tic -x -o /etc/terminfo /etc/cmux/terminfo.src && chmod -R a+rX /etc/terminfo && ${devboxTerminfoCheckCommand}`;

/**
 * Proves the baked daemon's direct-WebSocket path, not only its TCP listener.
 * The client runs inside the guest, so this also works when the operator's
 * Mac has no IPv6 route or VPC tunnel. It enrolls a temporary device,
 * performs authenticated RPC, creates a PTY, takes a terminal snapshot,
 * reconnects, and confirms that the marker survives. Cleanup revokes the
 * temporary device and removes the workspace before a snapshot can capture
 * test state.
 */
export function cmuxTuiWebsocketSmokeCommand(session = "cloud", binary?: string): string {
  const identity = `${DEVBOX_WORK_USER}@${DEVBOX_HOSTNAME}`;
  // Runs as the daemon's own user with the daemon's HOME: enrollment reads and
  // writes the session state the daemon owns, and as root that state dir is a
  // different (empty) one on a work-user machine.
  // The layout is selected by the caller (as root, the only user that can drop
  // privileges) and handed in: re-running the selector here, already dropped to
  // the daemon's user, would fail every probe and fall back to root's path.
  const shell = `#!/usr/bin/env bash
set -euo pipefail
BIN="\${CMUX_TUI_BIN:?cmux-tui binary not provided}"
: "\${HOME:?home not provided}"
SESSION=${session}
ROOT=/tmp/cmux-tui-websocket-smoke
ROUTE='ws://[::1]:1337/v1/link'
MARKER="CMUX_WS_SMOKE_${session}_$$"
CONNECT_PID=""
INVITATION_ID=""
DEVICE_FINGERPRINT=""
WORKSPACE_ID=""
PROCESS_ID=""
rm -rf "$ROOT"
mkdir -m 700 -p "$ROOT/state"
rpc() {
  "$BIN" remote rpc "$ROUTE" --state-dir "$ROOT/state" --lanes single --connect-timeout-seconds 45 --reconnect-attempts 1 --request "$1"
}
cleanup() {
  if [ -n "$CONNECT_PID" ]; then
    kill "$CONNECT_PID" 2>/dev/null || true
    wait "$CONNECT_PID" 2>/dev/null || true
  fi
  if [ -n "$PROCESS_ID" ]; then
    KILL_REQUEST="$(jq -nc --arg process "$PROCESS_ID" '{type:"signal-process",process:$process,signal:"kill"}')"
    rpc "$KILL_REQUEST" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORKSPACE_ID" ]; then
    CLOSE_REQUEST="$(jq -nc --arg workspace "$WORKSPACE_ID" '{type:"close-workspace",workspace:$workspace}')"
    rpc "$CLOSE_REQUEST" >/dev/null 2>&1 || true
  fi
  if [ -n "$DEVICE_FINGERPRINT" ]; then
    "$BIN" remote enroll revoke "$DEVICE_FINGERPRINT" --session "$SESSION" --json >/dev/null 2>&1 || true
  fi
  if [ -n "$INVITATION_ID" ]; then
    "$BIN" remote enroll deny "$INVITATION_ID" --session "$SESSION" --json >/dev/null 2>&1 || true
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT

"$BIN" remote enroll create --session "$SESSION" --ttl 300 --advertise "$ROUTE" --json >"$ROOT/create.json"
jq -r '.. | strings | select(startswith("cmux://enroll/"))' "$ROOT/create.json" | head -1 >"$ROOT/invitation"
test -s "$ROOT/invitation"
chmod 600 "$ROOT/invitation"
("$BIN" remote connect --invite-file "$ROOT/invitation" --device-name "snapshot-websocket-smoke" --state-dir "$ROOT/state" --session "$SESSION" --headless --json --lanes single --connect-timeout-seconds 60 --reconnect-attempts 2 >"$ROOT/connect.out" 2>"$ROOT/connect.err") &
CONNECT_PID=$!
for attempt in $(seq 1 90); do
  PENDING="$("$BIN" remote enroll pending --session "$SESSION" --json 2>/dev/null || true)"
  INVITATION_ID="$(printf '%s' "$PENDING" | jq -r 'if type == "array" then (.[0].invitation_id // empty) else (.pending[0].invitation_id // .invitations[0].invitation_id // empty) end' 2>/dev/null || true)"
  DEVICE_FINGERPRINT="$(printf '%s' "$PENDING" | jq -r 'if type == "array" then (.[0].device_fingerprint // empty) else (.pending[0].device_fingerprint // .invitations[0].device_fingerprint // empty) end' 2>/dev/null || true)"
  if [ -n "$INVITATION_ID" ]; then break; fi
  sleep 1
done
test -n "$INVITATION_ID"
"$BIN" remote enroll approve "$INVITATION_ID" --session "$SESSION" --json >/dev/null
sleep 2
kill "$CONNECT_PID" 2>/dev/null || true
wait "$CONNECT_PID" 2>/dev/null || true
CONNECT_PID=""

CAPABILITIES="$(rpc '{"type":"capabilities"}')"
echo "$CAPABILITIES" | jq -e '.type == "capabilities"' >/dev/null
WORKSPACE="$(rpc '{"type":"open-workspace","root":"/tmp"}')"
WORKSPACE_ID="$(echo "$WORKSPACE" | jq -r '.id // .result.Ok.id')"
test -n "$WORKSPACE_ID" && test "$WORKSPACE_ID" != "null"
SPAWN_REQUEST="$(jq -nc --arg workspace "$WORKSPACE_ID" --arg marker "$MARKER" '{type:"spawn-process",workspace:$workspace,argv:["bash","-lc",("printf %s:%s@%s "+$marker+" \\"$(id -un)\\" \\"$(hostname)\\"; sleep 60")],cwd:null,env:{},io:{type:"pty",cols:120,rows:40,term:"xterm-256color",eof:"control-d"},lifetime:"detached"}')"
SPAWN="$(rpc "$SPAWN_REQUEST")"
PROCESS_ID="$(echo "$SPAWN" | jq -r '.process // .result.Ok.process')"
test -n "$PROCESS_ID" && test "$PROCESS_ID" != "null"
sleep 2
SNAPSHOT_REQUEST="$(jq -nc --arg process "$PROCESS_ID" '{type:"snapshot-process-terminal",process:$process}')"
FIRST="$(rpc "$SNAPSHOT_REQUEST")"
echo "$FIRST" | jq -e --arg marker "$MARKER" 'tostring | contains($marker)' >/dev/null
# The whole point of the daemon layout: a pane it opens is a shell of the work
# user on a machine named cmux, which is what the prompt shows a person.
echo "$FIRST" | jq -e --arg who "$MARKER:${identity}" 'tostring | contains($who)' >/dev/null
FIRST_SEQUENCE="$(echo "$FIRST" | jq -r '.snapshot.through_sequence // .result.Ok.snapshot.through_sequence')"
test "$FIRST_SEQUENCE" -ge 1
SECOND="$(rpc "$SNAPSHOT_REQUEST")"
echo "$SECOND" | jq -e --arg marker "$MARKER" 'tostring | contains($marker)' >/dev/null
SECOND_SEQUENCE="$(echo "$SECOND" | jq -r '.snapshot.through_sequence // .result.Ok.snapshot.through_sequence')"
test "$SECOND_SEQUENCE" -ge "$FIRST_SEQUENCE"
echo "websocket-smoke-ok marker=$MARKER through_sequence=$FIRST_SEQUENCE->$SECOND_SEQUENCE"
`;
  const encoded = Buffer.from(shell, "utf8").toString("base64");
  const script = "/tmp/cmux-tui-websocket-smoke.sh";
  return (
    `printf %s ${encoded} | base64 -d >${script} && chmod 755 ${script} && ` +
    `${cmuxTuiLayoutSelector()} && ` +
    // `binary` overrides only the client: the reachability check drives a
    // freshly downloaded build against the daemon the image baked. HOME still
    // comes from the layout, because enrollment reads the daemon's own state.
    `${cmuxTuiAsDaemonUser(`CMUX_TUI_BIN=${binary ? shellQuote(binary) : '"$CMUX_TUI_BIN"'} bash ${script}`)}`
  );
}



/**
 * The desktop layer (ported from the retired Blaxel cmux-devbox image): an
 * openbox/TigerVNC desktop with a tint2 dock, Ghostty, Chrome, Thunar, the
 * accessibility bus for computer-use, and noVNC on 6901
 * (web/services/vms/images/desktop.ts is the contract). The Dockerfile bakes
 * it and starts it from cmux-devbox-boot; build-devbox-freestyle.ts installs
 * the same files and runs it from the cmux-desktop systemd unit.
 */
export const devboxDesktopDir = path.join(devboxDir, "desktop");
export const DEVBOX_DESKTOP_FILES = [
  "WALLPAPER.md",
  "cmux-desktop-boot",
  "cmux-desktop.service",
  "desktop-env.sh",
  "ghostty-cmux.desktop",
  "google-chrome-cmux.desktop",
  "start-vnc.sh",
  "thunar-cmux.desktop",
  "tint2rc",
  "wallpaper.jpg",
] as const;

export type DevboxDesktopInstall = {
  /** The checked-in file, relative to the devbox template dir. */
  readonly source: `desktop/${string}`;
  /** Where the image carries it. */
  readonly target: string;
  readonly mode: number;
};

/**
 * Where every desktop file lands in the image. The one map the Dockerfile's
 * COPY lines, the Freestyle bake's file writes, and the verifier's
 * byte-identity checks are all pinned to (tests/vm-devbox-desktop.test.ts),
 * so a path can only change in one place.
 */
export const DEVBOX_DESKTOP_INSTALLS: readonly DevboxDesktopInstall[] = [
  { source: "desktop/google-chrome-cmux.desktop", target: "/etc/cmux/apps/google-chrome-cmux.desktop", mode: 0o644 },
  { source: "desktop/thunar-cmux.desktop", target: "/etc/cmux/apps/thunar-cmux.desktop", mode: 0o644 },
  { source: "desktop/ghostty-cmux.desktop", target: "/etc/cmux/apps/ghostty-cmux.desktop", mode: 0o644 },
  { source: "desktop/tint2rc", target: "/etc/cmux/tint2rc", mode: 0o644 },
  { source: "desktop/wallpaper.jpg", target: "/usr/share/backgrounds/cmux/wallpaper.jpg", mode: 0o644 },
  { source: "desktop/start-vnc.sh", target: "/usr/local/bin/start-vnc.sh", mode: 0o755 },
  { source: "desktop/cmux-desktop-boot", target: "/usr/local/bin/cmux-desktop-boot", mode: 0o755 },
  { source: "desktop/cmux-desktop.service", target: "/etc/systemd/system/cmux-desktop.service", mode: 0o644 },
  { source: "desktop/desktop-env.sh", target: "/etc/cmux/desktop-env.sh", mode: 0o644 },
];

/**
 * The desktop apt packages, from the Dockerfile's
 * `ARG CMUX_IMAGE_DESKTOP_PACKAGES="..."` (a quoted list; Docker joins its
 * continuation lines). The Freestyle bake installs exactly this list.
 */
export function devboxDesktopPackages(dockerfile = readDevboxDockerfile()): string[] {
  const joined = dockerfile.replace(/\\\n/g, " ");
  const match = /^ARG CMUX_IMAGE_DESKTOP_PACKAGES="([^"]+)"/m.exec(joined);
  if (!match) throw new Error("devbox Dockerfile is missing ARG CMUX_IMAGE_DESKTOP_PACKAGES");
  const packages = match[1].split(/\s+/).filter(Boolean);
  if (packages.length === 0) throw new Error("devbox Dockerfile's CMUX_IMAGE_DESKTOP_PACKAGES is empty");
  return packages;
}

/**
 * Ghostty ships no upstream .deb; the Dockerfile pins a community build for
 * Ubuntu 24.04 by release tag (`ARG CMUX_IMAGE_GHOSTTY_DEB_URL=`), and the
 * Freestyle bake installs that exact file.
 */
export function devboxGhosttyDebUrl(dockerfile = readDevboxDockerfile()): string {
  const url = /^ARG CMUX_IMAGE_GHOSTTY_DEB_URL=(\S+)$/m.exec(dockerfile)?.[1];
  if (!url) throw new Error("devbox Dockerfile is missing ARG CMUX_IMAGE_GHOSTTY_DEB_URL");
  return url;
}

/**
 * The SHA-256 of that .deb (`ARG CMUX_IMAGE_GHOSTTY_DEB_SHA256=`): both
 * recipes verify the downloaded bytes against it before dpkg runs as root, so
 * a moved or tampered release asset fails the bake instead of installing.
 */
/**
 * The Ghostty release the image is built against, from the .deb pin: the
 * version panes export as TERM_PROGRAM_VERSION (cmux-devbox-boot reads it from
 * /etc/cmux/ghostty-version). Base images ship no Ghostty binary, so the pin,
 * not `ghostty +version`, is the source.
 */
export function devboxGhosttyVersion(dockerfile = readDevboxDockerfile()): string {
  const version = /\/ghostty_(\d+\.\d+\.\d+)[-_]/.exec(devboxGhosttyDebUrl(dockerfile))?.[1];
  if (!version) throw new Error("devbox Dockerfile's CMUX_IMAGE_GHOSTTY_DEB_URL carries no ghostty_<x.y.z> version");
  return version;
}

export function devboxGhosttyDebSha256(dockerfile = readDevboxDockerfile()): string {
  const sha = /^ARG CMUX_IMAGE_GHOSTTY_DEB_SHA256=([0-9a-f]{64})$/m.exec(dockerfile)?.[1];
  if (!sha) throw new Error("devbox Dockerfile is missing a 64-hex ARG CMUX_IMAGE_GHOSTTY_DEB_SHA256");
  return sha;
}

export const AGENT_PIN_ARGS: readonly { arg: string; pkg: string; binary: string }[] = [
  { arg: "CMUX_IMAGE_CLAUDE_CODE_VERSION", pkg: "@anthropic-ai/claude-code", binary: "claude" },
  { arg: "CMUX_IMAGE_CODEX_VERSION", pkg: "@openai/codex", binary: "codex" },
  { arg: "CMUX_IMAGE_OPENCODE_VERSION", pkg: "opencode-ai", binary: "opencode" },
  { arg: "CMUX_IMAGE_PI_VERSION", pkg: "@earendil-works/pi-coding-agent", binary: "pi" },
  { arg: "CMUX_IMAGE_AGENT_BROWSER_VERSION", pkg: "agent-browser", binary: "agent-browser" },
];

export type AgentPin = { pkg: string; version: string; binary: string; spec: string };

/** The npm pins come from the Dockerfile ARG defaults, never a second copy. */
export function devboxAgentPins(dockerfile = readDevboxDockerfile()): AgentPin[] {
  return AGENT_PIN_ARGS.map(({ arg, pkg, binary }) => {
    const match = new RegExp(`^ARG ${arg}=(\\S+)$`, "m").exec(dockerfile);
    if (!match) throw new Error(`devbox Dockerfile is missing ARG ${arg}`);
    return { pkg, version: match[1], binary, spec: `${pkg}@${match[1]}` };
  });
}

export function readDevboxDockerfile(): string {
  return readFileSync(devboxDockerfilePath, "utf8");
}

/** An exact npm release: `x.y.z`, never a range, a tag, or a prerelease. */
export const EXACT_AGENT_PIN = /^\d+\.\d+\.\d+$/;

/**
 * Rewrites the Dockerfile's `ARG CMUX_IMAGE_<TOOL>_VERSION=` lines to
 * `versions` (keyed by npm package), leaving every other byte alone. The one
 * sanctioned way to bump a pin (`bun run devbox:pins:check --write`): a pin is
 * an exact release, a package the Dockerfile does not bake is a mistake, and
 * a missing ARG line means the recipe no longer matches this table.
 */
export function rewriteDevboxAgentPins(dockerfile: string, versions: Record<string, string>): string {
  let next = dockerfile;
  for (const [pkg, version] of Object.entries(versions)) {
    const pin = AGENT_PIN_ARGS.find((candidate) => candidate.pkg === pkg);
    if (!pin) throw new Error(`${pkg} is not a devbox agent pin (${AGENT_PIN_ARGS.map((row) => row.pkg).join(", ")})`);
    if (!EXACT_AGENT_PIN.test(version)) throw new Error(`${pkg}: ${version} is not an exact x.y.z release`);
    const line = new RegExp(`^ARG ${pin.arg}=\\S+$`, "m");
    if (!line.test(next)) throw new Error(`devbox Dockerfile is missing ARG ${pin.arg}`);
    next = next.replace(line, `ARG ${pin.arg}=${version}`);
  }
  return next;
}

export type AgentPinDrift = {
  readonly pkg: string;
  readonly binary: string;
  readonly pinned: string;
  readonly latest: string;
  /** The registry's latest is not the pin (a newer release, or a pin ahead of a yanked latest). */
  readonly behind: boolean;
};

/** Pins next to the registry's current release; `latest` is keyed by npm package. */
export function agentPinDrift(pins: readonly AgentPin[], latest: Readonly<Record<string, string>>): AgentPinDrift[] {
  return pins.map((pin) => {
    const current = latest[pin.pkg];
    if (!current) throw new Error(`no registry version for ${pin.pkg}`);
    return { pkg: pin.pkg, binary: pin.binary, pinned: pin.version, latest: current, behind: current !== pin.version };
  });
}

/** The cua computer-use driver pin, from the Dockerfile (never a second copy). */
export function devboxCuaDriverVersion(dockerfile = readDevboxDockerfile()): string {
  const version = /CUA_DRIVER_RS_VERSION=(\S+)/.exec(dockerfile)?.[1];
  if (!version) throw new Error("devbox Dockerfile is missing CUA_DRIVER_RS_VERSION");
  return version;
}

export function devboxImageEpoch(dockerfile = readDevboxDockerfile()): string {
  return /CMUX_IMAGE_EPOCH=([^\s"]+)/.exec(dockerfile)?.[1] ?? "none";
}

/**
 * The source-digest formula version a manifest entry was recorded with.
 * Schema 1 covered the verbatim files, the ARG pins and the epoch; schema 2
 * adds the Dockerfile's instructions (comments dropped by the Dockerfile
 * grammar) and every non-blank line of the Freestyle bake script, so a step
 * change such as a new apt package can no longer leave the digest unchanged.
 * Entries keep the schema they were recorded with and are checked with that
 * formula, so a formula change never forces a rebake of an already promoted
 * ladder; new bakes record the current schema, and
 * `upgradeDevboxSourceRecords` moves an entry up only when its provenance is
 * proven from what it already recorded.
 */
export const DEVBOX_SOURCE_SCHEMA = 2;
export const bakeScriptPath = path.join(webRoot, "scripts/build-devbox-freestyle.ts");

/**
 * A Dockerfile reduced to its instructions, by the Dockerfile grammar: a line
 * whose first non-blank character is `#` is a comment (also inside a
 * continued instruction) unless it is a parser directive (`# key=value`
 * before the first instruction), which changes how the file is read and is
 * kept. Blank lines dropped, trailing whitespace trimmed. The container
 * recipe and the Freestyle replay are kept in step by hand, so an
 * instruction edit is an image change even when no ARG moved; a comment is
 * not.
 */
export function normalizedDockerfileInstructions(dockerfile: string): string {
  const kept: string[] = [];
  let beforeFirstInstruction = true;
  for (const raw of dockerfile.split("\n")) {
    const line = raw.trimEnd();
    const trimmed = line.trim();
    if (trimmed === "") continue;
    if (trimmed.startsWith("#")) {
      if (beforeFirstInstruction && /^#\s*[A-Za-z][A-Za-z0-9]*\s*=/.test(trimmed)) kept.push(line);
      continue;
    }
    beforeFirstInstruction = false;
    kept.push(line);
  }
  return kept.join("\n");
}

/**
 * The bake script reduced to its non-blank lines, trailing whitespace
 * trimmed. Nothing else is dropped on purpose: telling a comment from code
 * in TypeScript needs a full lexer (block comments, strings, template
 * literals, regex literals), and any line heuristic can hide a code change
 * (a `*`-prefixed continuation, a generator method). So a comment edit to
 * build-devbox-freestyle.ts also moves the digest and asks for a
 * re-promotion; that is the price of a digest that cannot miss a step
 * change, and edits to the bake script are promoted anyway.
 */
export function normalizedBakeScript(source: string): string {
  return source
    .split("\n")
    .map((line) => line.trimEnd())
    .filter((line) => line.trim() !== "")
    .join("\n");
}

/**
 * Everything the Freestyle bake takes from this checkout for an image with
 * `layers` (the shell layer for `base`, plus the desktop layer for
 * `desktop`): the files shipped verbatim (sha256 each, the desktop files by
 * their DEVBOX_DESKTOP_INSTALLS path), the pins the Dockerfile ARGs carry
 * (agents, cua-driver, the Ghostty .deb, the desktop apt list), the epoch
 * and, from schema 2, the Dockerfile's instructions and the bake script's
 * non-blank lines (normalizedDockerfileInstructions, normalizedBakeScript).
 * Dockerfile prose is deliberately not part of it: a comment cannot change a
 * machine; bake-script prose is, for want of a lexer that could tell it from
 * code.
 * `devboxSourceDigest` is its sha256, recorded on every manifest entry at
 * bake time so `devboxSourceDriftProblems` can tell when main describes a
 * machine the promoted default no longer is.
 */
export function devboxSourceManifest(
  layers: DevboxImageKind,
  dockerfile = readDevboxDockerfile(),
  schema: number = DEVBOX_SOURCE_SCHEMA,
  bakeScript = () => readFileSync(bakeScriptPath, "utf8"),
): Record<string, unknown> {
  if (schema !== 1 && schema !== 2) throw new Error(`unknown devbox source schema ${schema}`);
  const files = Object.fromEntries(
    DEVBOX_TEMPLATE_FILES.filter((name) => name !== "Dockerfile").map((name) => [name, sha256File(path.join(devboxDir, name))]),
  );
  const shell: Record<string, unknown> = {
    schema,
    layers,
    epoch: devboxImageEpoch(dockerfile),
    agentPins: Object.fromEntries(devboxAgentPins(dockerfile).map((pin) => [pin.pkg, pin.version])),
    cuaDriver: devboxCuaDriverVersion(dockerfile),
    ghosttyVersion: devboxGhosttyVersion(dockerfile),
    files,
  };
  if (schema >= 2) {
    shell.dockerfileInstructions = createHash("sha256").update(normalizedDockerfileInstructions(dockerfile)).digest("hex");
    shell.bakeScript = createHash("sha256").update(normalizedBakeScript(bakeScript())).digest("hex");
  }
  if (layers === "base") return shell;
  return {
    ...shell,
    ghosttyDeb: { url: devboxGhosttyDebUrl(dockerfile), sha256: devboxGhosttyDebSha256(dockerfile) },
    desktopPackages: devboxDesktopPackages(dockerfile),
    desktopFiles: Object.fromEntries(
      DEVBOX_DESKTOP_INSTALLS.map((install) => [install.source, sha256File(path.join(devboxDir, install.source))]),
    ),
  };
}

export function devboxSourceDigest(
  layers: DevboxImageKind,
  dockerfile = readDevboxDockerfile(),
  schema: number = DEVBOX_SOURCE_SCHEMA,
  bakeScript?: () => string,
): string {
  return createHash("sha256").update(JSON.stringify(devboxSourceManifest(layers, dockerfile, schema, bakeScript))).digest("hex");
}

/** Which layers an image carries, the digest of the sources they were baked from, and the formula it was computed with (absent: schema 1). */
export type DevboxSourceRecord = {
  readonly layers: DevboxImageKind;
  readonly digest: string;
  readonly schema?: number;
};

export function devboxTemplateFile(name: string): string {
  return readFileSync(path.join(devboxDir, name), "utf8");
}

export function devboxDesktopFile(name: string): string {
  return readFileSync(path.join(devboxDesktopDir, name), "utf8");
}

/** Raw bytes of a devbox template file (`desktop/<name>` for the desktop layer). */
export function devboxFileBytes(name: string): Uint8Array {
  const file = name.startsWith("desktop/")
    ? path.join(devboxDesktopDir, name.slice("desktop/".length))
    : path.join(devboxDir, name);
  return new Uint8Array(readFileSync(file));
}

export function fileBase64(name: string): string {
  return readFileSync(path.join(devboxDir, name)).toString("base64");
}

export function sha256File(filePath: string): string {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function git(args: string, cwd: string): string {
  return execSync(`git ${args}`, { cwd, encoding: "utf8" }).trim();
}

/**
 * Stale-checkout guard (chatmux bake-preflight lineage): refuse to bake from
 * a checkout that silently missed a pull. The Dockerfile COPYs plain files,
 * so there are no base64 embeds to drift-check. Branch bakes are deliberate
 * with CMUX_BAKE_ALLOW_BRANCH=1.
 */
export function bakePreflight(options: { desktop?: boolean } = {}): { sha: string; epoch: string } {
  for (const name of DEVBOX_TEMPLATE_FILES) {
    if (!existsSync(path.join(devboxDir, name))) {
      throw new Error(`bake refused: ${name} is missing from ${devboxDir}`);
    }
  }
  if (options.desktop) {
    for (const name of DEVBOX_DESKTOP_FILES) {
      if (!existsSync(path.join(devboxDesktopDir, name))) {
        throw new Error(`bake refused: desktop/${name} is missing from ${devboxDesktopDir}`);
      }
    }
  }
  const allowBranch = process.env.CMUX_BAKE_ALLOW_BRANCH === "1";
  // Two promotions running at once (one ladder each) race on the ref lock, so
  // a lost race is retried rather than fatal. What must NOT happen is blessing
  // a stale ref: the whole point of the check below is to refuse a bake from
  // an obsolete checkout, and `HEAD === origin/main` can pass against a ref
  // that predates main. So an unrefreshed ref is only tolerated for a
  // deliberate branch bake, which is not making that claim anyway.
  let fetched = false;
  let fetchError = "";
  for (let attempt = 0; attempt < 3 && !fetched; attempt += 1) {
    try {
      execSync("git fetch --quiet origin main", { cwd: repoRoot, stdio: "pipe" });
      fetched = true;
    } catch (error) {
      fetchError = String(error).split("\n")[0];
      if (attempt < 2) execSync("sleep 2", { cwd: repoRoot });
    }
  }
  if (!fetched && !allowBranch) {
    throw new Error(
      `bake refused: could not refresh origin/main (${fetchError}), so the staleness check below cannot be trusted. ` +
        "Retry, or set CMUX_BAKE_ALLOW_BRANCH=1 for a deliberate branch bake.",
    );
  }
  if (!fetched) console.warn(`bake-preflight: could not refresh origin/main (${fetchError}); branch bake, continuing`);
  const head = git("rev-parse HEAD", repoRoot);
  const main = git("rev-parse origin/main", repoRoot);
  if (head !== main && !allowBranch) {
    throw new Error(
      `bake refused: HEAD ${head.slice(0, 10)} != origin/main ${main.slice(0, 10)} ` +
        "(pull first, or set CMUX_BAKE_ALLOW_BRANCH=1 for a deliberate branch bake)",
    );
  }
  const epoch = devboxImageEpoch();
  const state = head === main ? "== origin/main" : "!= origin/main (CMUX_BAKE_ALLOW_BRANCH=1)";
  console.log(`bake-preflight: HEAD ${head.slice(0, 10)} ${state}, devbox epoch ${epoch}`);
  return { sha: head, epoch };
}

// ---------------------------------------------------------------------------
// Identity: the machine is `cmux` (services/vms/images/identity.ts). The bake
// runs the install command once, early; the verifier and the size derive run
// the check on machines booted from the snapshot.
// ---------------------------------------------------------------------------

/** The roots the residue audit walks: everything the machine speaks for itself from. */
export const DEVBOX_IDENTITY_RESIDUE_ROOTS: readonly string[] = ["/etc", "/home", "/root", "/usr/local", "/opt"];

/**
 * Rewrites the loopback alias line of an /etc/hosts file so the machine's own
 * name resolves: the first `127.0.1.1` line becomes `127.0.1.1<TAB><hostname>`,
 * further ones are dropped, and one is appended when none exists. Every other
 * line (localhost, the IPv6 entries, the provider's TLS-egress block) is kept
 * byte for byte, and the file is rewritten in place through `cat >` so its
 * inode (and a bind mount over it) survives. Portable awk only.
 */
export function devboxHostsAliasRewriteCommand(hostname = DEVBOX_HOSTNAME, hostsPath = "/etc/hosts"): string {
  const program =
    `BEGIN { done = 0 } ` +
    `$1 == "${DEVBOX_HOSTNAME_LOOPBACK}" { if (!done) { print "${DEVBOX_HOSTNAME_LOOPBACK}\\t" h; done = 1 }; next } ` +
    `{ print } ` +
    `END { if (!done) print "${DEVBOX_HOSTNAME_LOOPBACK}\\t" h }`;
  return `awk -v h=${hostname} '${program}' ${hostsPath} > ${hostsPath}.cmux-identity && cat ${hostsPath}.cmux-identity > ${hostsPath} && rm -f ${hostsPath}.cmux-identity`;
}

/**
 * New SSH host keys under the machine's current name (the base's keys were
 * generated when Freestyle built its rootfs and are shared by every VM booted
 * from that base). They are generated into a staging dir on the same
 * filesystem and moved over the old ones only once all of them exist, so a
 * failed generation fails the step with the previous keys still in place;
 * sshd loads keys at start, so it is restarted where systemd runs it and left
 * alone where nothing does. cmux-devbox-boot does the same on every clone.
 */
export function devboxSshHostKeyRegenerateCommand(): string {
  return [
    'staging="$(mktemp -d /etc/ssh/.cmux-rekey.XXXXXX)"',
    'mkdir -p "$staging/etc/ssh"',
    'ssh-keygen -A -f "$staging" >/dev/null',
    '[ -n "$(ls "$staging"/etc/ssh/ssh_host_*_key 2>/dev/null)" ]',
    'for key in "$staging"/etc/ssh/ssh_host_*_key; do mv -f "$key.pub" /etc/ssh/ && mv -f "$key" /etc/ssh/ || exit 1; done',
    'rm -rf "$staging"',
    "{ [ ! -d /run/systemd/system ] || systemctl try-restart ssh; }",
  ].join(" && ");
}

/**
 * Fails when the provider's machine name survives as a whole word in any
 * text file under `roots` (the `freestyle-vms` agent, units and resolver
 * drop-in do not match). Package trees are skipped: a third-party module
 * mentioning the name is not the machine speaking for itself, and walking
 * the agents' node_modules would cost minutes.
 */
export function devboxProviderResidueCommand(
  name = DEVBOX_PROVIDER_HOSTNAME,
  roots: readonly string[] = DEVBOX_IDENTITY_RESIDUE_ROOTS,
): string {
  const skip = ["node_modules", "nvm", ".npm", ".cache", ".bun", "python", "python3"].map((dir) => `--exclude-dir=${dir}`).join(" ");
  // `grep -l` exits 1 when nothing matches, which is the good case; the group
  // keeps a failure of an earlier `&&` link from being reported as residue.
  return `{ residue="$(grep -rIlE ${skip} '(^|[^[:alnum:]_-])${name}([^[:alnum:]_-]|$)' ${roots.join(" ")} 2>/dev/null || true)"; [ -z "$residue" ] || { printf '%s residue:\\n%s\\n' ${name} "$residue"; exit 1; }; }`;
}

/**
 * Start the machine's log at its own name: archive and drop the journal files
 * written under the provider's name (the base's boot, the bake's first steps).
 */
export const devboxJournalResetCommand = "journalctl --rotate >/dev/null 2>&1; journalctl --vacuum-time=1s >/dev/null 2>&1; true";

/**
 * Proves the identity from every angle a person or a program meets it: the
 * kernel's hostname, the static one, `hostnamectl`, `$HOSTNAME` in a clean
 * root login shell, the loopback alias resolving (exactly one alias line),
 * sudo not warning about an unresolvable host, the SSH host keys' comment,
 * and no provider residue (devboxProviderResidueCommand). Run as root.
 */
export function devboxIdentityCheckCommand(hostname = DEVBOX_HOSTNAME): string {
  return [
    `[ "$(hostname)" = ${hostname} ]`,
    `[ "$(cat /proc/sys/kernel/hostname)" = ${hostname} ]`,
    `[ "$(cat /etc/hostname)" = ${hostname} ]`,
    `[ "$(hostnamectl --static 2>/dev/null || cat /etc/hostname)" = ${hostname} ]`,
    `[ "$(env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -lc 'echo "$HOSTNAME"')" = ${hostname} ]`,
    `getent hosts ${hostname} | grep -q '^${DEVBOX_HOSTNAME_LOOPBACK}[[:space:]]'`,
    `[ "$(grep -c '^${DEVBOX_HOSTNAME_LOOPBACK}[[:space:]]' /etc/hosts)" = 1 ]`,
    `! sudo -n true 2>&1 | grep -q 'unable to resolve host'`,
    `[ "$(awk '{ print $3 }' /etc/ssh/ssh_host_ed25519_key.pub)" = root@${hostname} ]`,
    devboxProviderResidueCommand(),
    `echo identity-${hostname}-ok`,
  ].join(" && ");
}

/**
 * The bake's identity step, run as root right after the base inventory, before
 * anything records the machine's name (SSH host keys, the ble.sh caches, the
 * daemon, the journal): the static and live hostname (systemd-hostnamed
 * activates over D-Bus on demand; an init without it gets the file plus
 * sethostname), the loopback alias, fresh host keys, and the check.
 */
export function devboxIdentityInstallCommand(hostname = DEVBOX_HOSTNAME): string {
  return [
    `{ hostnamectl set-hostname ${hostname} 2>/dev/null || { printf '%s\\n' ${hostname} > /etc/hostname && hostname ${hostname}; }; }`,
    `[ "$(cat /etc/hostname)" = ${hostname} ]`,
    devboxHostsAliasRewriteCommand(hostname),
    devboxSshHostKeyRegenerateCommand(),
    devboxIdentityCheckCommand(hostname),
  ].join(" && ");
}

/**
 * The platform's name for the machine running the command: the Firecracker
 * MMDS instance id (EC2-style token, then GET). Empty output means no metadata
 * service (a container). cmux-devbox-boot keys the daemon identity on it.
 */
export const DEVBOX_INSTANCE_ID_COMMAND =
  "curl -sf -m 2 -H \"X-aws-ec2-metadata-token: $(curl -sf -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-metadata-token-ttl-seconds: 60')\" http://169.254.169.254/latest/meta-data/instance-id";

/**
 * Guest-side condition for "the session daemon is fully up on THIS machine":
 * it answers on its control socket, it is listening dual-stack on 1337
 * (0x0539; a machine reached at a private VPC address needs the v6 table),
 * and the supervisor has bound its identity to this machine's instance id.
 *
 * This is the signal every phase used to approximate with `sleep 30`. It is
 * not slow: a machine resumed from a snapshot answers in well under a second
 * (the verifier prints the number), so waiting on it instead of on the clock
 * removes ~30 s per phase without weakening the check.
 */
export function devboxDaemonReadyCondition(): string {
  return (
    `${cmuxTuiRunCommand(`server status --session ${CMUX_TUI_SESSION}`)} >/dev/null 2>&1 && ` +
    `grep -qi ':0539 ' /proc/net/tcp6 && ` +
    // Not just "a marker exists": a machine cloned from a snapshot resumes the
    // SOURCE machine's daemon, which answers and listens with the source's
    // identity until cmux-devbox-boot notices the instance id changed and
    // re-keys it. A ready check that accepted the stale marker would hand the
    // next phase a daemon that is about to be stopped and rebuilt.
    //
    // Both sides must be non-empty. An unreachable metadata service yields an
    // empty id, and an unwritten marker reads empty too, so a bare comparison
    // would call "" = "" a bound identity and report ready immediately. This
    // command only ever runs on a Freestyle VM, which always has MMDS, so
    // failing closed here surfaces a broken machine instead of hiding it.
    `cmux_instance="$(${DEVBOX_INSTANCE_ID_COMMAND})" && [ -n "$cmux_instance" ] && ` +
    `[ "$(cat /etc/cmux/daemon-instance-id 2>/dev/null)" = "$cmux_instance" ]`
  );
}

/**
 * Blocks in the guest until {@link devboxDaemonReadyCondition} holds, then
 * exits 0. Bounded: on timeout it exits 1 with the elapsed budget on stderr,
 * so a daemon that never comes up fails the bake instead of hanging it.
 */
export function devboxWaitForDaemonCommand(timeoutSeconds = 120): string {
  return (
    `cmux_ready=0; for i in $(seq 1 ${timeoutSeconds * 2}); do ` +
    `if ${devboxDaemonReadyCondition()}; then cmux_ready=1; break; fi; sleep 0.5; done; ` +
    `if [ "$cmux_ready" = 1 ]; then echo daemon-ready; else ` +
    `echo "cmux-tui daemon not ready after ${timeoutSeconds}s" >&2; exit 1; fi`
  );
}

/**
 * Park the cmux-tui daemon on a machine about to be snapshotted: record this
 * machine's instance id as the bake id (cmux-devbox-boot keeps the daemon
 * stopped while the ids match), wait for the supervisor to stop it, wipe the
 * identity and session state it produced, and prove nothing listens on 1337.
 * Every machine created from the resulting snapshot has a different id, so
 * its supervisor starts a daemon with a fresh identity within one tick.
 * Run as root. Exits 0 only when the daemon is parked.
 */
export function devboxParkDaemonCommand(): string {
  return [
    cmuxTuiLayoutSelector(),
    `mkdir -p /etc/cmux && ${DEVBOX_INSTANCE_ID_COMMAND} > /etc/cmux/bake-instance-id && test -s /etc/cmux/bake-instance-id`,
    // [s]tart: the pattern must not match the exec shell carrying this command line.
    "for i in $(seq 1 30); do pgrep -f 'cmux-tui server [s]tart' >/dev/null || break; sleep 1; done",
    "! pgrep -f 'cmux-tui server [s]tart' >/dev/null",
    "systemctl is-active cmux-tui-daemon >/dev/null",
    'rm -rf "$CMUX_TUI_HOME/.local/state/cmux/remote" "$CMUX_TUI_HOME/.local/state/cmux-tui" /etc/cmux/daemon-instance-id',
    "! grep -qi ':0539 ' /proc/net/tcp6",
    "echo daemon-parked-for-clones",
  ].join(" && ");
}

export function defaultBakeTag(): string {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "").replace("T", "-");
  return `devbox-${stamp}`;
}

export function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  if (index === -1) return undefined;
  return process.argv[index + 1];
}

export function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

export type DevboxBakeMetadata = {
  readonly builtAt: string;
  readonly epoch: string;
  readonly repoCommit: string;
  readonly builderScriptVersion: string;
  readonly agentToolResolvedVersions: Record<string, string>;
  readonly devboxSource: DevboxSourceRecord;
};

export function bakeMetadata(
  preflight: { sha: string; epoch: string },
  builderScriptPath: string,
  layers: DevboxImageKind,
): DevboxBakeMetadata {
  return {
    builtAt: new Date().toISOString(),
    epoch: preflight.epoch,
    repoCommit: preflight.sha,
    builderScriptVersion: sha256File(builderScriptPath),
    agentToolResolvedVersions: Object.fromEntries(
      devboxAgentPins().map((pin) => [pin.pkg, pin.version]),
    ),
    devboxSource: { layers, digest: devboxSourceDigest(layers), schema: DEVBOX_SOURCE_SCHEMA },
  };
}

export type DevboxProvider = "freestyle";
export type DevboxImageKind = "desktop" | "base";
export type DevboxImageSize = {
  name: VmImageSizeName;
  cpu: number;
  memoryMb: number;
  storageMb: number;
};

/** One `images[]` row of services/vms/images/manifest.json, as the bake scripts emit it. */
export type DevboxManifestEntry = {
  provider: DevboxProvider;
  version: string;
  imageId: string;
  /** Legacy: nothing reads it; kept so old entries parse. */
  envVar: string;
  /** Legacy: local dev uses the same `defaultForKind` entry as production. */
  defaultForLocalDev?: boolean;
  kind?: DevboxImageKind;
  defaultForKind?: boolean;
  /** The shape this snapshot boots at (Freestyle ladder). Size-less entries are pre-ladder bakes. */
  size?: DevboxImageSize;
  cmuxdRemoteCommit: string;
  /** The cmux-tui build baked in the daemon user's home (files.cmux.com manifest pin at bake time). Absent on images that installed it at create time. */
  cmuxTuiCommit?: string;
  cmuxTuiSha256?: string;
  /** The cmux commit whose devbox definition produced this image. */
  repoCommit?: string;
  /** The Dockerfile's CMUX_IMAGE_EPOCH at bake time; older entries carry it in `notes` only (see manifestEntryEpoch). */
  epoch?: string;
  /** The layers the image carries and the digest of the sources they were baked from (devboxSourceDigest). Absent on older entries. */
  devboxSource?: DevboxSourceRecord;
  builtAt: string;
  builderScriptVersion: string;
  agentToolResolvedVersions: Record<string, string>;
  validationStatus: "passed" | "failed" | "unknown";
  notes?: string;
};

export function manifestEntrySkeleton(
  provider: DevboxProvider,
  version: string,
  imageId: string,
  envVar: string,
  metadata: DevboxBakeMetadata,
  extraNotes = "",
  kind?: DevboxImageKind,
): DevboxManifestEntry {
  return {
    provider,
    version,
    imageId,
    envVar,
    ...(kind ? { kind } : {}),
    // The session daemon is cmux-tui, installed at create time from the pinned
    // artifacts manifest; no cmuxd-remote build is baked.
    cmuxdRemoteCommit: "none-cmux-tui",
    repoCommit: metadata.repoCommit,
    epoch: metadata.epoch,
    devboxSource: metadata.devboxSource,
    builtAt: metadata.builtAt,
    builderScriptVersion: metadata.builderScriptVersion,
    agentToolResolvedVersions: metadata.agentToolResolvedVersions,
    // The bake alone never marks an image passed; verify-devbox-image.ts does.
    validationStatus: "unknown",
    notes: [
      `cmux devbox epoch ${metadata.epoch}`,
      extraNotes,
    ].filter(Boolean).join(" "),
  };
}

/**
 * The bake's machine-readable result. `--out <path>` on a bake script writes
 * it there so promote-devbox-image.ts never has to scrape build logs.
 */
export type DevboxBakeResult = {
  readonly provider: DevboxProvider;
  readonly imageId: string;
  readonly manifestEntry: DevboxManifestEntry;
  readonly next: string;
  readonly [extra: string]: unknown;
};

export function emitBakeResult(result: DevboxBakeResult): void {
  console.log(JSON.stringify(result, null, 2));
  const out = argValue("--out");
  if (out) {
    writeFileSync(out, `${JSON.stringify(result, null, 2)}\n`);
    console.log(`bake result written to ${out}`);
  }
  // The last stdout line is the image id alone, so shell callers can
  // `tail -n 1` it without parsing JSON.
  console.log(`IMAGE_ID ${result.imageId}`);
}

// ---------------------------------------------------------------------------
// Manifest promotion: the checked-in manifest is the source of truth for the
// image users get, so "promote" is a pure edit of that file that a PR
// carries. Only verified images are promotable, and a provider+kind has
// exactly one default at a time.
// ---------------------------------------------------------------------------

export const imageManifestPath = path.join(webRoot, "services/vms/images/manifest.json");

export type DevboxImageManifest = {
  schemaVersion: number;
  images: DevboxManifestEntry[];
};

/**
 * Serializes the manifest's read-modify-write across concurrent promotions.
 * Both ladders can then be promoted at once (they share nothing else), which
 * halves a full refresh; without it the second writer would silently drop the
 * first one's entries. Advisory and bounded: an abandoned lock older than its
 * TTL is taken over, so a killed promotion cannot wedge the next one.
 */
export async function withImageManifestLock<T>(run: () => Promise<T> | T): Promise<T> {
  const lockPath = `${imageManifestPath}.lock`;
  const deadline = Date.now() + 180_000;
  const staleAfterMs = 10 * 60 * 1000;
  const token = `${process.pid}:${randomUUID()}`;
  for (;;) {
    try {
      writeFileSync(lockPath, `${token}\n`, { flag: "wx" });
      break;
    } catch {
      let age = 0;
      try {
        age = Date.now() - statSync(lockPath).mtimeMs;
      } catch {
        continue; // released between the failed create and the stat
      }
      if (age > staleAfterMs) {
        console.warn(`taking over an abandoned manifest lock (${(age / 1000).toFixed(0)}s old)`);
        rmSync(lockPath, { force: true });
        continue;
      }
      if (Date.now() > deadline) {
        throw new Error(`another promotion has held ${lockPath} for over 3 minutes; re-run once it finishes`);
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
  try {
    return await run();
  } finally {
    // Only remove the lock if it is still ours: a stale takeover (or an
    // operator clearing it) may have handed it to another promotion, and
    // deleting that one would let a third in beside it.
    let held = "";
    try {
      held = readFileSync(lockPath, "utf8").trim();
    } catch {
      held = "";
    }
    if (held === token) rmSync(lockPath, { force: true });
    else if (held !== "") console.warn(`manifest lock was taken over by ${held}; leaving it in place`);
  }
}

export function readImageManifest(file = imageManifestPath): DevboxImageManifest {
  const parsed = JSON.parse(readFileSync(file, "utf8")) as DevboxImageManifest;
  if (parsed.schemaVersion !== 1 || !Array.isArray(parsed.images)) {
    throw new Error(`${file}: unsupported image manifest shape`);
  }
  return parsed;
}

export function writeImageManifest(manifest: DevboxImageManifest, file = imageManifestPath): void {
  writeFileSync(file, `${JSON.stringify(manifest, null, 2)}\n`);
}

export type PromoteImageOptions = {
  /** Kinds this image serves. Each gets its own entry flagged `defaultForKind`. */
  readonly kinds: readonly DevboxImageKind[];
  /**
   * Sized snapshots derived from the bake (derive-devbox-sizes.ts): one
   * manifest entry per kind and size, each the default for that kind+size.
   * Omitted: a single size-less entry per kind (a pre-ladder bake).
   */
  readonly sizes?: readonly { readonly imageId: string; readonly size: DevboxImageSize }[];
  /** Human-readable validation summary appended to `notes`. */
  readonly validationNotes?: string;
};

function sizeKey(entry: Pick<DevboxManifestEntry, "size">): string {
  return entry.size?.name ?? "";
}

/**
 * Appends fully-formed rows (each a promotion's output: `kind`,
 * `defaultForKind`, `size`, `validationStatus`) to the manifest, demoting the
 * provider's existing defaults for every kind+size a default row takes over
 * (a sized row also retires the size-less defaults of its kind: the ladder
 * replaces the single-shape image; a row carrying `defaultForLocalDev`
 * retires the previous one). Pure: returns a new manifest and never mutates
 * the input. Existing entries are only ever flag-flipped, never removed, so
 * rollback stays a one-line manifest change. This is the one edit a
 * promotion performs, and `promote --replay <summary.json>` re-applies the
 * rows an earlier run appended onto a manifest that changed underneath it
 * (another ladder merged first), so a merge conflict is resolved through the
 * sanctioned writer and never by hand.
 */
export function appendImageManifestEntries(
  manifest: DevboxImageManifest,
  rows: readonly DevboxManifestEntry[],
): DevboxImageManifest {
  if (rows.length === 0) throw new Error("refusing to append no manifest rows");
  for (const row of rows) {
    if (!row.provider || !row.version || !row.imageId) {
      throw new Error(`refusing to append a row without provider, version and imageId: ${JSON.stringify(row).slice(0, 200)}`);
    }
    if (row.defaultForKind && row.validationStatus !== "passed") {
      throw new Error(
        `refusing to promote ${row.provider} ${row.imageId}: validationStatus is ` +
          `${row.validationStatus}, not passed (run verify-devbox-image.ts first)`,
      );
    }
    const clash = manifest.images.find((candidate) =>
      candidate.provider === row.provider &&
      candidate.imageId === row.imageId &&
      (candidate.kind ?? "base") === (row.kind ?? "base") &&
      sizeKey(candidate) === sizeKey(row)
    );
    if (clash) {
      throw new Error(
        `refusing to promote ${row.provider} ${row.imageId}: already listed as ${clash.version} (${row.kind ?? "base"}${row.size ? `, ${row.size.name}` : ""})`,
      );
    }
  }
  // provider/kind -> the size keys its new default rows take over.
  const takeover = new Map<string, Set<string>>();
  const localDevProviders = new Set<string>();
  for (const row of rows) {
    if (row.defaultForLocalDev) localDevProviders.add(row.provider);
    if (!row.defaultForKind) continue;
    const key = `${row.provider}/${row.kind ?? "base"}`;
    takeover.set(key, new Set([...(takeover.get(key) ?? []), sizeKey(row)]));
  }
  const providers = new Set(rows.map((row) => row.provider));
  const demoted = manifest.images.map((candidate) => {
    if (!providers.has(candidate.provider)) return candidate;
    const next: DevboxManifestEntry = { ...candidate };
    if (localDevProviders.has(next.provider) && next.defaultForLocalDev) next.defaultForLocalDev = false;
    const sizes = takeover.get(`${next.provider}/${next.kind ?? "base"}`);
    if (sizes && next.defaultForKind) {
      const sized = [...sizes].some((size) => size !== "");
      if (sizes.has(sizeKey(next)) || (sizeKey(next) === "" && sized)) next.defaultForKind = false;
    }
    return next;
  });
  return { schemaVersion: manifest.schemaVersion, images: [...demoted, ...rows] };
}

/**
 * Appends a verified image to the manifest as the default for every kind in
 * `kinds` (and every size in `sizes`), demoting the provider's previous
 * defaults for those kind+size pairs (appendImageManifestEntries). A row the
 * manifest already lists for the same image, kind and size is left as it is:
 * a promotion is idempotent per kind, so a kind can be added to an image
 * promoted earlier (one snapshot serving both kinds) without re-listing the
 * rows it already has; only a promotion that would add nothing is refused.
 * Pure.
 */
export function promoteImageManifestEntry(
  manifest: DevboxImageManifest,
  entry: DevboxManifestEntry,
  options: PromoteImageOptions,
): DevboxImageManifest {
  if (entry.validationStatus !== "passed") {
    throw new Error(
      `refusing to promote ${entry.provider} ${entry.imageId}: validationStatus is ` +
        `${entry.validationStatus}, not passed (run verify-devbox-image.ts first)`,
    );
  }
  if (options.kinds.length === 0) {
    throw new Error(`refusing to promote ${entry.imageId}: no kinds given`);
  }
  const kinds = [...new Set(options.kinds)];
  const variants: Array<{ imageId: string; size?: DevboxImageSize }> =
    options.sizes && options.sizes.length > 0
      ? [...options.sizes].sort((a, b) => vmImageSizeRank(a.size.name) - vmImageSizeRank(b.size.name))
      : [{ imageId: entry.imageId }];
  const promotesLocalDevBase = kinds.includes("base") && variants.some((variant) => variant.size?.name === "sm");
  const notes = [entry.notes, options.validationNotes].filter(Boolean).join(" ");
  const promoted: DevboxManifestEntry[] = [];
  for (const kind of kinds) {
    for (const variant of variants) {
      const suffix = [variant.size ? variant.size.name : "", kind !== kinds[0] ? kind : ""].filter(Boolean).join("-");
      promoted.push({
        ...entry,
        version: suffix ? `${entry.version}-${suffix}` : entry.version,
        imageId: variant.imageId,
        kind,
        defaultForKind: true,
        ...(variant.size ? { size: variant.size } : {}),
        ...(promotesLocalDevBase && kind === "base" && variant.size?.name === "sm"
          ? { defaultForLocalDev: true }
          : {}),
        ...(notes ? { notes } : {}),
      });
    }
  }
  const listed = (row: DevboxManifestEntry) =>
    manifest.images.find((candidate) =>
      candidate.provider === row.provider &&
      candidate.imageId === row.imageId &&
      (candidate.kind ?? "base") === (row.kind ?? "base") &&
      sizeKey(candidate) === sizeKey(row)
    );
  const fresh = promoted.filter((row) => !listed(row));
  if (fresh.length === 0) {
    const clash = listed(promoted[0])!;
    throw new Error(
      `refusing to promote ${entry.provider} ${promoted[0].imageId}: already listed as ${clash.version} (${promoted[0].kind}${promoted[0].size ? `, ${promoted[0].size.name}` : ""})`,
    );
  }
  return appendImageManifestEntries(manifest, fresh);
}

/**
 * Invariants the checked-in manifest must hold; tests/vm-image-manifest.test.ts
 * runs this against the real file, promote-devbox-image.ts against its output.
 */
export function imageManifestProblems(manifest: DevboxImageManifest): string[] {
  const problems: string[] = [];
  const defaults = new Map<string, DevboxManifestEntry[]>();
  for (const entry of manifest.images) {
    for (const field of ["provider", "version", "imageId", "envVar", "builtAt", "validationStatus"] as const) {
      if (!entry[field]) problems.push(`${entry.version ?? entry.imageId ?? "?"}: missing ${field}`);
    }
    if (!["passed", "failed", "unknown"].includes(entry.validationStatus)) {
      problems.push(`${entry.version}: validationStatus ${String(entry.validationStatus)} is not passed|failed|unknown`);
    }
    if (entry.kind !== undefined && entry.kind !== "desktop" && entry.kind !== "base") {
      problems.push(`${entry.version}: kind ${String(entry.kind)} is not desktop|base`);
    }
    if (entry.size !== undefined) {
      const { name, cpu, memoryMb, storageMb } = entry.size;
      if (vmImageSizeRank(name) < 0) problems.push(`${entry.version}: size ${String(name)} is not on the ladder`);
      if (![cpu, memoryMb, storageMb].every((n) => Number.isInteger(n) && n > 0)) {
        problems.push(`${entry.version}: size ${String(name)} needs positive integer cpu/memoryMb/storageMb`);
      }
    }
    if (entry.defaultForKind) {
      if (entry.validationStatus !== "passed") {
        problems.push(`${entry.version}: defaultForKind but validationStatus is ${entry.validationStatus}`);
      }
      const key = `${entry.provider}/${entry.kind ?? "base"}${entry.size ? `/${entry.size.name}` : ""}`;
      defaults.set(key, [...(defaults.get(key) ?? []), entry]);
    }
  }
  const versions = manifest.images.map((entry) => `${entry.provider}/${entry.version}`);
  for (const dup of versions.filter((v, i) => versions.indexOf(v) !== i)) {
    problems.push(`${dup}: version listed more than once`);
  }
  const shapesByKind = new Map<string, Set<string>>();
  for (const entry of manifest.images) {
    if (!entry.defaultForKind) continue;
    const key = `${entry.provider}/${entry.kind ?? "base"}`;
    shapesByKind.set(key, new Set([...(shapesByKind.get(key) ?? []), entry.size ? "sized" : "size-less"]));
  }
  for (const [key, shapes] of shapesByKind) {
    if (shapes.size > 1) problems.push(`${key}: defaults mix sized and size-less entries`);
  }
  for (const [key, entries] of defaults) {
    if (entries.length > 1) {
      problems.push(`${key}: ${entries.length} entries flagged defaultForKind (${entries.map((e) => e.version).join(", ")})`);
    }
  }
  return problems;
}

/**
 * Checks the production Freestyle defaults as a complete machine-size
 * ladder. Historical, size-less entries remain valid for rollback, but active
 * defaults must cover every size with the exact shape that the resolver uses.
 */
export function devboxImageLadderProblems(
  manifest: DevboxImageManifest,
  provider: DevboxProvider = "freestyle",
): string[] {
  const problems: string[] = devboxUnifiedSnapshotProblems(manifest, provider);
  for (const kind of ["base", "desktop"] as const) {
    const defaults = manifest.images.filter(
      (entry) => entry.provider === provider && (entry.kind ?? "base") === kind && entry.defaultForKind,
    );
    if (defaults.length === 0) {
      problems.push(`${provider}/${kind}: no default image ladder`);
      continue;
    }
    const byName = new Map<string, DevboxManifestEntry>();
    for (const entry of defaults) {
      const sizeName = entry.size?.name;
      if (!sizeName) {
        problems.push(`${entry.version}: ${provider}/${kind} default is size-less`);
        continue;
      }
      if (byName.has(sizeName)) {
        problems.push(`${provider}/${kind}/${sizeName}: duplicate default images`);
        continue;
      }
      byName.set(sizeName, entry);
      const expected = VM_IMAGE_SIZES.find((size) => size.name === sizeName);
      if (!expected) continue;
      if (
        entry.size?.cpu !== expected.cpu ||
        entry.size.memoryMb !== expected.memoryMb ||
        entry.size.storageMb !== expected.storageMb
      ) {
        problems.push(
          `${entry.version}: ${provider}/${kind}/${sizeName} shape is ` +
            `${entry.size?.cpu} vCPU/${entry.size?.memoryMb} MiB/${entry.size?.storageMb} MiB; ` +
            `expected ${expected.cpu} vCPU/${expected.memoryMb} MiB/${expected.storageMb} MiB`,
        );
      }
    }
    for (const name of VM_IMAGE_SIZE_NAMES) {
      if (!byName.has(name)) problems.push(`${provider}/${kind}: missing default size ${name}`);
    }
    const ids = new Map<string, string>();
    for (const [name, entry] of byName) {
      const previous = ids.get(entry.imageId);
      if (previous) {
        problems.push(`${provider}/${kind}: image ${entry.imageId} is used for sizes ${previous} and ${name}`);
      } else {
        ids.set(entry.imageId, name);
      }
    }
  }
  const localDefaults = manifest.images.filter((entry) => entry.provider === provider && entry.defaultForLocalDev);
  if (localDefaults.length !== 1) {
    problems.push(`${provider}: expected exactly one defaultForLocalDev entry, found ${localDefaults.length}`);
  } else {
    const local = localDefaults[0];
    if ((local.kind ?? "base") !== "base" || local.size?.name !== "sm" || !local.defaultForKind) {
      problems.push(`${local.version}: defaultForLocalDev must be the base sm default`);
    }
  }
  return problems;
}

/** Product defaults share one desktop-capable snapshot at each size across legacy kinds. */
export function devboxUnifiedSnapshotProblems(
  manifest: DevboxImageManifest,
  provider: DevboxProvider = "freestyle",
): string[] {
  const problems: string[] = [];
  const snapshots = new Map<string, string>();
  for (const entry of manifest.images) {
    if (entry.provider !== provider || !entry.defaultForKind || !entry.size) continue;
    if (entry.devboxSource?.layers !== "desktop") {
      problems.push(`${entry.version}: default devbox must include the desktop layer`);
    }
    const previous = snapshots.get(entry.size.name);
    if (previous && previous !== entry.imageId) {
      problems.push(`${provider}/${entry.size.name}: all kinds must share one snapshot`);
    }
    snapshots.set(entry.size.name, entry.imageId);
  }
  return problems;
}


/**
 * The devbox Dockerfile as committed at `commit`, or null when the commit or
 * the file is not available here. `commit` comes from a manifest entry, which
 * may have been written on a branch this checkout did not author, so it is
 * accepted only as a full 40-hex object id and passed to git as an argument,
 * never through a shell.
 */
export function devboxDockerfileAtCommit(commit: string): string | null {
  if (!/^[0-9a-f]{40}$/i.test(commit)) return null;
  try {
    return execFileSync("git", ["show", `${commit}:web/services/vms/images/devbox/Dockerfile`], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null;
  }
}

/**
 * Moves default entries recorded at an older source schema to the current
 * one without a rebake, only where every input the newer schema adds is
 * proven from what the entry recorded, never synthesized from the checkout:
 * its digest at its own schema must equal this checkout's (the verbatim
 * files, pins and epoch are the bake's); its `builderScriptVersion` must
 * equal this checkout's bake script; and the Dockerfile's instructions at
 * its `repoCommit` (read from git; a commit or file that is not available
 * here is not proof) must equal this checkout's. Anything else is left alone
 * and reported: a rebake is the only other way up. Pure but for the git read,
 * which `dockerfileAt` replaces in tests.
 */
export function upgradeDevboxSourceRecords(
  manifest: DevboxImageManifest,
  options: {
    provider?: DevboxProvider;
    dockerfile?: string;
    bakeScript?: () => string;
    dockerfileAt?: (commit: string) => string | null;
  } = {},
): { manifest: DevboxImageManifest; upgraded: string[]; skipped: Array<{ version: string; reason: string }> } {
  const provider = options.provider ?? "freestyle";
  const dockerfile = options.dockerfile ?? readDevboxDockerfile();
  const bakeScript = options.bakeScript ?? (() => readFileSync(bakeScriptPath, "utf8"));
  const dockerfileAt = options.dockerfileAt ?? devboxDockerfileAtCommit;
  const bakeScriptSha256 = createHash("sha256").update(bakeScript()).digest("hex");
  const instructions = normalizedDockerfileInstructions(dockerfile);
  const upgraded: string[] = [];
  const skipped: Array<{ version: string; reason: string }> = [];
  const images = manifest.images.map((entry) => {
    const source = entry.devboxSource;
    if (entry.provider !== provider || !entry.defaultForKind || !source) return entry;
    const schema = source.schema ?? 1;
    if (schema >= DEVBOX_SOURCE_SCHEMA) return entry;
    if (source.layers !== "desktop" && source.layers !== "base") {
      skipped.push({ version: entry.version, reason: `devboxSource.layers ${String(source.layers)} is not desktop|base` });
      return entry;
    }
    if (source.digest !== devboxSourceDigest(source.layers, dockerfile, schema, bakeScript)) {
      skipped.push({ version: entry.version, reason: `schema ${schema} digest does not match this checkout` });
      return entry;
    }
    if (entry.builderScriptVersion !== bakeScriptSha256) {
      skipped.push({ version: entry.version, reason: "builderScriptVersion does not match this checkout's bake script" });
      return entry;
    }
    const bakedDockerfile = entry.repoCommit ? dockerfileAt(entry.repoCommit) : null;
    if (bakedDockerfile === null) {
      skipped.push({ version: entry.version, reason: `Dockerfile at repoCommit ${entry.repoCommit ?? "(none)"} is not available here; rebake to record schema ${DEVBOX_SOURCE_SCHEMA}` });
      return entry;
    }
    if (normalizedDockerfileInstructions(bakedDockerfile) !== instructions) {
      skipped.push({ version: entry.version, reason: `Dockerfile instructions changed since repoCommit ${entry.repoCommit}; rebake to record schema ${DEVBOX_SOURCE_SCHEMA}` });
      return entry;
    }
    upgraded.push(entry.version);
    return {
      ...entry,
      devboxSource: { layers: source.layers, digest: devboxSourceDigest(source.layers, dockerfile, DEVBOX_SOURCE_SCHEMA, bakeScript), schema: DEVBOX_SOURCE_SCHEMA },
    };
  });
  return { manifest: { schemaVersion: manifest.schemaVersion, images }, upgraded, skipped };
}

/** The epoch an entry was baked at: the field, or the `cmux devbox epoch <x>` prefix every bake writes into `notes`. */
export function manifestEntryEpoch(entry: Pick<DevboxManifestEntry, "epoch" | "notes">): string | undefined {
  return entry.epoch ?? /cmux devbox epoch (\S+)/.exec(entry.notes ?? "")?.[1];
}

/**
 * The invariant that makes the checked-in manifest describe the machine
 * users get: every default of `provider` was baked at the Dockerfile's
 * current CMUX_IMAGE_EPOCH (a bumped epoch without a promotion, or a
 * rollback to an older ladder without reverting the sources, fails), and an
 * entry that recorded its source digest was baked from exactly the files and
 * pins in this checkout (a template or pin change without a re-promotion
 * fails). Rollback therefore reverts the promotion commit as a whole, sources
 * included, never the manifest flags alone. Entries without a digest predate
 * the record and are held to the epoch only.
 */
export function devboxSourceDriftProblems(
  manifest: DevboxImageManifest,
  provider: DevboxProvider = "freestyle",
  dockerfile = readDevboxDockerfile(),
): string[] {
  const problems: string[] = [];
  const epoch = devboxImageEpoch(dockerfile);
  const digests = new Map<string, string>();
  for (const entry of manifest.images) {
    if (entry.provider !== provider || !entry.defaultForKind) continue;
    const bakedEpoch = manifestEntryEpoch(entry);
    if (bakedEpoch !== epoch) {
      problems.push(`${entry.version}: baked at devbox epoch ${bakedEpoch ?? "(unknown)"}, the Dockerfile is at ${epoch}; promote a new bake or revert the sources with the manifest`);
    }
    const source = entry.devboxSource;
    if (!source) continue;
    if (source.layers !== "desktop" && source.layers !== "base") {
      problems.push(`${entry.version}: devboxSource.layers ${String(source.layers)} is not desktop|base`);
      continue;
    }
    const schema = source.schema ?? 1;
    if (schema !== 1 && schema !== 2) {
      problems.push(`${entry.version}: devboxSource.schema ${String(source.schema)} is not a known formula (1 or 2)`);
      continue;
    }
    const key = `${source.layers}/${schema}`;
    const current = digests.get(key) ?? devboxSourceDigest(source.layers, dockerfile, schema);
    digests.set(key, current);
    if (source.digest !== current) {
      problems.push(`${entry.version}: baked from devbox sources ${source.digest.slice(0, 12)}… (schema ${schema}), this checkout's ${source.layers} sources are ${current.slice(0, 12)}…; promote a new bake or revert the sources with the manifest`);
    }
  }
  return problems;
}
