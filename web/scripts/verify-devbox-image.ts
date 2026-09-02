#!/usr/bin/env bun
/**
 * Post-bake verification for the cmux Cloud devbox images, run directly
 * against the provider SDKs. Boots ONE sandbox for the named provider,
 * asserts everything the devbox promises (pinned agents, mise toolchain,
 * devtools, Chrome + cua-driver, ble.sh ghost text under a real PTY, the
 * agent-config generator byte-identical to this checkout), then asserts the
 * daemon contract with NO bootstrap of its own: the baked cmux-tui daemon must
 * come up by itself after resume, bound to this machine's instance id, with
 * the binary at the current files.cmux.com pin. A second machine from the same
 * snapshot must hold a different daemon identity (the snapshot is a memory
 * image; see cmux-devbox-boot). Both sandboxes are deleted.
 *
 * Usage:
 *   FREESTYLE_API_KEY=... bun scripts/verify-devbox-image.ts freestyle <snapshot-id>
 *
 * Exit 0 means every check passed; record validationStatus "passed" in the
 * manifest entry then. Creates only its own sandboxes and deletes them in a
 * finally block.
 */
// The devbox freestyle bake targets the public platform (see
// build-devbox-freestyle.ts), the same platform the shipped driver speaks.
import { Freestyle } from "freestyle";
import path from "node:path";
import {
  CMUX_TUI_SESSION,
  resolveCmuxTuiSource,
} from "../services/vms/drivers/cmuxTuiDaemon";
import { DEVBOX_INSTANCE_ID_COMMAND, devboxAgentPins, devboxDesktopDir, devboxDir, sha256File } from "./devbox-image-common";

const pins = devboxAgentPins();
const shaOf = (name: string): string => sha256File(path.join(devboxDir, name));
const desktopShaOf = (name: string): string => sha256File(path.join(devboxDesktopDir, name));

// Every file the image bakes from this checkout must ship byte-identical.
const FILE_PIN_CHECKS = [
  ["cmux-bashrc", "/etc/cmux/bashrc"],
  ["agent-config.sh", "/etc/cmux/agent-config.sh"],
  ["seed-history", "/etc/cmux/seed-history"],
  ["cmux-devbox-boot", "/usr/local/bin/cmux-devbox-boot"],
  ["chrome-managed-policy.json", "/etc/opt/chrome/policies/managed/cmux.json"],
].map(([source, target]) => `echo '${shaOf(source)}  ${target}' | sha256sum -c -`);

const CHECKS: readonly string[] = [
  // Pinned coding agents: exact installed versions, not just runnable.
  `ls=$(npm ls -g --depth=0) && ${pins
    .map((pin) => `echo "$ls" | grep -F ' ${pin.spec}'`)
    .join(" && ")} && echo agent-pins-ok`,
  ...pins.map((pin) => `${pin.binary} --version`),
  // Toolchain present (where it comes from is provider-specific, below).
  "node --version && npm --version && python --version && python3 --version && bun --version && uv --version && echo toolchain-ok",
  "git --version; rg --version | head -1",
  "jq --version; fd --version; fzf --version; gh --version | head -1; sqlite3 --version; tmux -V; rsync --version | head -1; file --version | head -1; tree --version; vim --version | head -1",
  // Chrome + managed policy + browser/computer-use drivers.
  "google-chrome-stable --version",
  "jq -e '.DefaultSearchProviderSearchURL | test(\"duckduckgo\")' /etc/opt/chrome/policies/managed/cmux.json >/dev/null && echo chrome-ddg-policy-ok",
  "grep -q AGENT_BROWSER_EXECUTABLE_PATH /etc/profile.d/cmux-media.sh && echo media-profile-ok",
  "cua-driver --version",
  "ffmpeg -version | head -1 && command -v Xvfb && command -v xdpyinfo && command -v xdotool",
  // Baked files are byte-identical to this checkout.
  ...FILE_PIN_CHECKS,
  // Devshell: ble.sh installed, bashrc chained, tmux pinned to bash, seed
  // history lands on first interactive shell.
  "test -f /usr/local/share/blesh/ble.sh && grep -q '/etc/cmux/bashrc' /etc/skel/.bashrc && echo bashrc-chain-ok",
  "grep default-shell /etc/tmux.conf",
  "bash -ic 'head -2 ~/.bash_history'",
  // Ghost-text smoke under a real PTY: type "cl" and expect ble.sh to render
  // the seeded claude command as the history suggestion.
  "tmux new-session -d -s ghost -x 100 -y 24 && sleep 2 && tmux send-keys -t ghost cl && sleep 2 && tmux capture-pane -pt ghost | grep -o 'claude --dangerously-skip-permissions' | head -1; rc=$?; tmux kill-session -t ghost 2>/dev/null; exit $rc",
  // Quiet-marks smoke: the bashrc blanks ble.sh's status marks and pins USER
  // so no [ble: ...] or "insane environment" text ever renders.
  "tmux new-session -d -s marks -x 100 -y 24 && sleep 3 && tmux send-keys -t marks not-a-command Enter && sleep 2 && tmux send-keys -t marks 'printf no-newline' Enter && sleep 2 && out=$(tmux capture-pane -pt marks); tmux kill-session -t marks 2>/dev/null; printf '%s\\n' \"$out\" | grep -E '\\[ble:|ble\\.sh:' && exit 1; echo no-ble-marks",
  // Agent-config generator: a login shell under a throwaway HOME with fake
  // model-plane env materializes the codex custom provider plus the pi
  // openai-codex override (token-free, header env reference) and persists
  // the env 0600; the unreachable config endpoint writes no opencode
  // config; the image ships no pre-generated config for root.
  "rm -rf /tmp/cmux-agent-config-verify && env HOME=/tmp/cmux-agent-config-verify OPENAI_BASE_URL=https://example.invalid/v1 OPENAI_API_KEY=crt_check CMUX_CODEROUTER_URL=https://example.invalid bash -lc 'true' && grep -q 'model_provider = \"cmux\"' /tmp/cmux-agent-config-verify/.codex/config.toml && grep -q 'wire_api = \"responses\"' /tmp/cmux-agent-config-verify/.codex/config.toml && grep -q \"export OPENAI_API_KEY='crt_check'\" /tmp/cmux-agent-config-verify/.config/cmux/model-plane.env && [ \"$(stat -c %a /tmp/cmux-agent-config-verify/.config/cmux/model-plane.env)\" = \"600\" ] && grep -qF '\"x-coderouter-route-token\": \"$OPENAI_API_KEY\"' /tmp/cmux-agent-config-verify/.pi/agent/models.json && ! grep -q crt_check /tmp/cmux-agent-config-verify/.pi/agent/models.json && test ! -e /tmp/cmux-agent-config-verify/.config/opencode/opencode.json && rm -rf /tmp/cmux-agent-config-verify && test ! -e /root/.codex/config.toml && test ! -e /root/.pi/agent/models.json && test ! -e /root/.config/opencode/opencode.json && echo agent-config-ok",
  "grep -q cleanupPeriodDays /etc/claude-code/managed-settings.json && echo claude-retention-ok",
  "whoami; nproc; free -m | sed -n 2p; df -h / | tail -1",
];

// The daemon came up on its own after resume: it serves the session, listens
// on 1337 (hex 0539), the baked binary is the one on PATH, and its identity is
// bound to THIS machine's instance id, not the builder's.
const INSTANCE_ID = DEVBOX_INSTANCE_ID_COMMAND;
// cmux-remote keys per-session state by the base64url session name under its
// default root state dir; the Noise static identity lives in auth/.
const REMOTE_IDENTITY = `/root/.local/state/cmux/remote/sessions/${Buffer.from(CMUX_TUI_SESSION).toString("base64url")}/auth/identity.json`;
// cmux-tui's own per-machine secrets, regenerated on first start after the bake wiped them.
const MACHINE_SECRETS = "/root/.local/state/cmux-tui/sessions/machine-id /root/.local/state/cmux-tui/sessions/resource-effect-pepper";
const DAEMON_CHECKS: readonly string[] = [
  // [s]tart: the pattern must not match the exec shell carrying this very command line.
  "pgrep -f 'cmux-tui server [s]tart' >/dev/null && echo daemon-running",
  `env HOME=/root /root/.cmux/bin/cmux-tui server status --session ${CMUX_TUI_SESSION} >/dev/null && echo daemon-status-ok`,
  "awk '$2 ~ /:0539$/ && $4 == \"0A\" { found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 && echo daemon-port-1337-ok",
  "test \"$(readlink /usr/local/bin/cmux-tui)\" = /root/.cmux/bin/cmux-tui && echo cmux-tui-symlink-ok",
  `test -s ${REMOTE_IDENTITY} && echo daemon-identity-present`,
  `test "$(cat /etc/cmux/daemon-instance-id)" = "$(${INSTANCE_ID})" && echo daemon-identity-bound-to-this-instance`,
  `test -s /etc/cmux/bake-instance-id && test "$(cat /etc/cmux/bake-instance-id)" != "$(${INSTANCE_ID})" && echo builder-instance-differs`,
  "test -d /root/.config/cmux && echo model-plane-env-dir-baked",
  "systemctl is-active cmux-tui-daemon >/dev/null && echo systemd-supervisor-active",
];

// The desktop layer (Freestyle bakes; /etc/cmux/image-stamp says "desktop"):
// the cmux-desktop systemd unit runs start-vnc.sh as cua, RFB 5901 (hex 170D)
// is loopback-only, noVNC answers on 6901 (hex 1AF5), the dock and window
// manager are up, Ghostty and Chrome are installed with first run
// pre-accepted, and every desktop file ships byte-identical.
// Hashed lazily: a base-only verification must not read the desktop assets.
const desktopFilePinChecks = (): string[] => [
  ["start-vnc.sh", "/usr/local/bin/start-vnc.sh"],
  ["cmux-desktop-boot", "/usr/local/bin/cmux-desktop-boot"],
  ["cmux-desktop.service", "/etc/systemd/system/cmux-desktop.service"],
  ["tint2rc", "/etc/cmux/tint2rc"],
  ["wallpaper.jpg", "/usr/share/backgrounds/cmux/wallpaper.jpg"],
  ["google-chrome-cmux.desktop", "/etc/cmux/apps/google-chrome-cmux.desktop"],
  ["thunar-cmux.desktop", "/etc/cmux/apps/thunar-cmux.desktop"],
  ["ghostty-cmux.desktop", "/etc/cmux/apps/ghostty-cmux.desktop"],
].map(([source, target]) => `echo '${desktopShaOf(source)}  ${target}' | sha256sum -c -`);

const desktopChecks = (): readonly string[] => [
  "systemctl is-active cmux-desktop >/dev/null && echo desktop-unit-active",
  "awk '$2 ~ /:170D$/ && $4 == \"0A\" { found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 && echo vnc-5901-listening",
  // 5901 must be loopback-only: every listener on it is bound to 127.0.0.1 (0100007F) or ::1.
  "awk '$2 ~ /:170D$/ && $4 == \"0A\" && $2 !~ /^0100007F:/ && $2 !~ /^00000000000000000000000001000000:/ { bad=1 } END { exit bad }' /proc/net/tcp /proc/net/tcp6 && echo vnc-5901-loopback-only",
  "awk '$2 ~ /:1AF5$/ && $4 == \"0A\" { found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 && echo novnc-6901-listening",
  "curl -fsS http://127.0.0.1:6901/ | grep -qi novnc && echo novnc-6901-serves-client",
  // start-vnc.sh runs whichever of Xvnc/Xtigervnc is on PATH; the process
  // name follows the invoked path (Ubuntu's Xvnc is a symlink to Xtigervnc).
  "pgrep -u ubuntu -x 'Xvnc|Xtigervnc' >/dev/null && pgrep -u ubuntu -x openbox >/dev/null && pgrep -u ubuntu -x tint2 >/dev/null && echo desktop-session-ok",
  "runuser -u ubuntu -- env DISPLAY=:1 xdpyinfo | grep dimensions",
  "ghostty +version | head -1",
  "test -f '/home/ubuntu/.config/google-chrome/First Run' && echo chrome-first-run-ok",
  "test -s /etc/cmux/icons/google-chrome.png && test -s /etc/cmux/icons/thunar.png && test -s /etc/cmux/icons/ghostty.png && echo dock-icons-ok",
  ...desktopFilePinChecks(),
];

// Freestyle: the work user is the base's `ubuntu` (uid 1000, passwordless
// sudo, the API's default exec user and the SSH default), the toolchain is
// the base's (Node under nvm symlinked into /usr/local/bin, Bun, Python, uv,
// Docker) with the pinned agents installed on top, and the pins must win in
// every shell family: a clean login shell (no PATH help from this verifier)
// and a daemon pane (non-login, the unit's PATH).
const FREESTYLE_BASE_CHECKS: readonly string[] = [
  "[ \"$(id -u ubuntu)\" = 1000 ] && sudo -n -u ubuntu sudo -n true && echo ubuntu-user-sudo-ok",
  "sudo -n -u ubuntu bash -ic 'head -1 ~/.bash_history' | grep -q claude && echo ubuntu-user-shell-ok",
  "test ! -e /opt/mise && test ! -e /usr/local/bin/mise && readlink /usr/local/bin/node | grep -q /usr/local/nvm/ && echo base-toolchain-in-use",
  "for b in node claude codex opencode pi agent-browser bun; do test -L /usr/local/bin/$b || exit 1; done && echo agent-symlinks-ok",
  ...pins.map((pin) => `env -i HOME=/home/ubuntu TERM=xterm sudo -n -u ubuntu bash -lc '${pin.binary} --version' | grep -F '${pin.version}' >/dev/null && echo ${pin.binary}-login-pin-ok`),
  // Non-login probe, as the work user: probing as root with HOME=/home/ubuntu
  // would itself leave root-owned state dirs behind.
  ...pins.map((pin) => `sudo -n -u ubuntu env -i HOME=/home/ubuntu USER=ubuntu TERM=xterm PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ${pin.binary} --version | grep -F '${pin.version}' >/dev/null && echo ${pin.binary}-nonlogin-pin-ok`),
  "systemctl show cmux-tui-daemon -p Environment | grep -q 'PATH=/usr/local/sbin:/usr/local/bin:' && echo daemon-env-path-ok",
  "docker --version && sudo -n -u ubuntu docker ps >/dev/null && echo docker-ok",
  // Home hygiene: nothing root-owned in the work user's home, ble.sh's
  // fallback state dir writable, the legal-notice marker present, and two
  // real interactive logins as the work user print nothing from ble.sh or
  // the shell (a `bash -c` probe would not load ble.sh at all).
  "[ \"$(find /home/ubuntu -not -user ubuntu | wc -l)\" = 0 ] && echo home-owned-by-ubuntu",
  "[ \"$(stat -c %a /usr/local/share/blesh/state.d)\" = 1777 ] && [ \"$(stat -c %a /usr/local/share/blesh/cache.d)\" = 1777 ] && echo blesh-dirs-ok",
  "test -f /home/ubuntu/.cache/motd.legal-displayed && test -f /root/.cache/motd.legal-displayed && test -f /etc/skel/.cache/motd.legal-displayed && echo legal-notice-silenced",
  ...[1, 2].map((run) =>
    `sudo -n -u ubuntu env -i HOME=/home/ubuntu USER=ubuntu TERM=xterm-256color PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -c 'tmux -L vprobe${run} new-session -d -s login -x 120 -y 30 && sleep 3 && pane="$(tmux -L vprobe${run} capture-pane -pt login)"; tmux -L vprobe${run} kill-server 2>/dev/null; printf "%s\\n" "$pane" | grep -iE "ble\\.sh|bleopt|ble-face|denied|not found|WARRANTY${run > 1 ? "|updating tput" : ""}" && { printf "%s\\n" "$pane"; exit 1; }; printf "%s\\n" "$pane" | grep -q "λ" && echo ubuntu-login-silent-${run}'`,
  ),
  // The devshell chain lives in the per-user rc files (after Ubuntu's own
  // PS1), never in /etc/bash.bashrc, so it loads once and the cmux prompt wins.
  "grep -q '/etc/cmux/bashrc' /home/ubuntu/.bashrc && grep -q '/etc/cmux/bashrc' /etc/skel/.bashrc && ! grep -q '/etc/cmux/bashrc' /etc/bash.bashrc && echo devshell-sourced-once",
  // The login banner is cmux's and offline.
  "run-parts /etc/update-motd.d | grep -q 'persistent cloud VM' && ! run-parts /etc/update-motd.d | grep -qi 'ubuntu.com' && test ! -s /etc/motd && echo motd-ok",
  // ble.sh tput-cache seeds are readable by the work user and land in its
  // XDG cache verbatim on first shell, so no login prints the tput notice.
  "[ \"$(find /etc/cmux/blesh-cache-seed -not -perm -o+r | wc -l)\" = 0 ] && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.xterm-ghostty && echo blesh-seeds-readable",
  "sudo -n -u ubuntu env -i HOME=/home/ubuntu USER=ubuntu TERM=xterm-256color PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -c 'rm -rf ~/.cache/blesh; tmux -L seed new-session -d -s s -x 100 -y 24 \"env TERM=xterm-256color bash -i\" && sleep 3; tmux -L seed kill-server 2>/dev/null; cmp ~/.cache/blesh/*/term.xterm-256color /etc/cmux/blesh-cache-seed/blesh/*/term.xterm-256color' && echo blesh-cache-seeded",
  `echo '${shaOf("cmux-motd")}  /etc/update-motd.d/00-cmux' | sha256sum -c -`,
  "cat /etc/cmux/tool-versions",
  "cat /etc/cmux/image-stamp",
];

type Exec = (cmd: string, timeoutMs?: number) => Promise<{ exitCode: number; output: string }>;

async function runChecks(label: string, checks: readonly string[], exec: Exec): Promise<boolean> {
  let ok = true;
  for (const cmd of checks) {
    const r = await exec(cmd);
    if (r.exitCode !== 0) ok = false;
    console.log(
      `  $ ${cmd}\n    exit=${r.exitCode}\n    ${r.output.trim().split("\n").join("\n    ")}`,
    );
  }
  console.log(ok ? `[${label}] ALL CHECKS PASSED` : `[${label}] CHECKS FAILED`);
  return ok;
}

/**
 * Waits for the baked daemon to answer on its own. Nothing is installed or
 * started here: a machine the driver creates gets exactly this treatment
 * (vms.create, then the Mac dials), so this is the contract being verified.
 * Returns the milliseconds from the call until the session answered.
 */
async function waitForBakedDaemon(provider: string, exec: Exec): Promise<number> {
  const t0 = Date.now();
  for (let attempt = 0; attempt < 45; attempt += 1) {
    const status = await exec(`env HOME=/root /root/.cmux/bin/cmux-tui server status --session ${CMUX_TUI_SESSION}`, 30_000);
    if (status.exitCode === 0) return Date.now() - t0;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(`${provider}: baked cmux-tui daemon did not come up by itself`);
}

const provider = process.argv[2] ?? "";
const image = process.argv[3] ?? "";
if (!image) {
  throw new Error("usage: bun scripts/verify-devbox-image.ts freestyle <snapshot-id> [--expect-kind desktop|base]");
}
// The caller's belief about the image (promote-devbox-image.ts derives it from
// --no-desktop). The stamp baked into the image is the truth; a mismatch fails
// the verification so a base image is never promoted as the desktop default.
const expectKindIndex = process.argv.indexOf("--expect-kind");
const expectKind = expectKindIndex === -1 ? undefined : process.argv[expectKindIndex + 1];
if (expectKind !== undefined && expectKind !== "desktop" && expectKind !== "base") {
  throw new Error(`--expect-kind: expected desktop or base, got ${expectKind ?? "(nothing)"}`);
}
let pass = false;

if (provider === "freestyle") {
  console.log(`===== freestyle (snapshot ${image}, public platform) =====`);
  const apiKey = process.env.FREESTYLE_API_KEY;
  const stackToken = process.env.FREESTYLE_STACK_ACCESS_TOKEN;
  const teamId = process.env.FREESTYLE_TEAM_ID;
  const baseUrl = process.env.FREESTYLE_API_URL?.trim() || undefined;
  const fs = apiKey
    ? new Freestyle({ apiKey, baseUrl })
    : stackToken && teamId
      ? new Freestyle({ stackAccessToken: stackToken, teamId, baseUrl })
      : (() => {
          throw new Error("set FREESTYLE_API_KEY, or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID");
        })();
  // Creates require an explicit firewall; outbound only, like the driver's
  // private-network machines. Nothing here needs inbound.
  const firewall = { rules: [{ action: "allow" as const, source: {}, destination: { public: true as const } }] };
  const execFor = (vm: Awaited<ReturnType<typeof fs.vms.create>>["vm"]): Exec => async (cmd, timeoutMs = 120_000) => {
    // Login bash for the mise shims; Freestyle guest exec has an empty HOME.
    const wrapped = `bash -lc 'export HOME="$\{HOME:-$(getent passwd $(id -u) | cut -d: -f6)\}"; export PATH="/opt/mise/shims:$\{PATH\}"; ${cmd.replace(/'/g, `'\\''`)}'`;
    // The 0.2 API defaults to uid 1000; the driver runs everything as root.
    const r = await vm.exec({ command: wrapped, timeoutMs: Math.min(timeoutMs, 300_000), linuxUser: "root" });
    return {
      exitCode: r.statusCode ?? 124,
      output: `${r.stdout ?? ""}${r.stderr ?? ""}`,
    };
  };
  const t0 = Date.now();
  const { vm, vmId } = await fs.vms.create({ snapshotId: image, displayName: "cmux-devbox-verify", firewall });
  console.log(`provisioned ${vmId} in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  try {
    const exec = execFor(vm);
    const daemonMs = await waitForBakedDaemon("freestyle", exec);
    console.log(`baked daemon answered ${daemonMs} ms after the first probe (${Date.now() - t0} ms after create)`);
    // The baked binary must be the pin the bake resolved and recorded in
    // /etc/cmux/cmux-tui-pin (that is the image's contract; the manifest entry
    // carries the same commit). The live files.cmux.com pin moves with every
    // cmux-tui release, so drift from it is reported, not failed: a new pin
    // reaches machines through a rebake.
    const bakedPin = await exec("cat /etc/cmux/cmux-tui-pin", 30_000);
    const [bakedSha, bakedCommit] = bakedPin.output.trim().split(/\s+/);
    if (bakedPin.exitCode !== 0 || !/^[0-9a-f]{64}$/.test(bakedSha ?? "")) {
      throw new Error(`image carries no readable /etc/cmux/cmux-tui-pin: ${bakedPin.output.slice(-300)}`);
    }
    const pin = await exec(`printf '%s  %s\\n' ${bakedSha} /root/.cmux/bin/cmux-tui | sha256sum -c >/dev/null 2>&1 && echo baked-pin-ok`, 30_000);
    if (pin.exitCode !== 0) {
      throw new Error(`baked cmux-tui does not match the pin recorded at bake time: ${pin.output.slice(-500)}`);
    }
    const live = await resolveCmuxTuiSource("freestyle");
    console.log(
      live.sha256 === bakedSha
        ? `cmux-tui pin: ${bakedCommit} (${bakedSha.slice(0, 12)}…), the current files.cmux.com pin`
        : `cmux-tui pin: baked ${bakedCommit} (${bakedSha.slice(0, 12)}…); files.cmux.com now pins ${live.commit} (${live.sha256.slice(0, 12)}…), a rebake picks it up`,
    );
    // A second machine from the same memory snapshot must mint its own
    // identity; a shared one would let every machine impersonate every other.
    const second = await fs.vms.create({ snapshotId: image, displayName: "cmux-devbox-verify-2", firewall });
    try {
      const exec2 = execFor(second.vm);
      await waitForBakedDaemon("freestyle", exec2);
      const digest = `cat ${REMOTE_IDENTITY} ${MACHINE_SECRETS} | sha256sum | cut -c1-64`;
      const [a, b] = await Promise.all([exec(digest, 30_000), exec2(digest, 30_000)]);
      const digestA = a.output.trim();
      const digestB = b.output.trim();
      if (a.exitCode !== 0 || b.exitCode !== 0 || digestA.length !== 64 || digestB.length !== 64) {
        throw new Error(`could not read both daemon identities: ${a.output.slice(-200)} / ${b.output.slice(-200)}`);
      }
      if (digestA === digestB) {
        throw new Error(`two machines from ${image} share one daemon identity (${digestA.slice(0, 12)}…)`);
      }
      console.log(`daemon identity + machine secrets differ across machines: ${digestA.slice(0, 12)}… vs ${digestB.slice(0, 12)}…`);
    } finally {
      await second.vm.delete();
      console.log(`deleted ${second.vmId}`);
    }
    // The image stamp says which layers were baked; a desktop image must
    // pass the desktop contract, a base image must not carry a desktop.
    const stamp = await exec("cat /etc/cmux/image-stamp 2>/dev/null || true", 30_000);
    const desktop = /\bdesktop\b/.test(stamp.output);
    console.log(`image stamp: ${stamp.output.trim() || "(none)"} -> desktop checks ${desktop ? "on" : "off"}`);
    const stampKind = desktop ? "desktop" : "base";
    if (expectKind !== undefined && expectKind !== stampKind) {
      throw new Error(`image stamp says ${stampKind} but --expect-kind ${expectKind} was requested`);
    }
    pass = await runChecks("freestyle", [
      ...CHECKS,
      ...DAEMON_CHECKS,
      ...FREESTYLE_BASE_CHECKS,
      ...(desktop
        ? desktopChecks()
        : ["test ! -e /usr/local/bin/start-vnc.sh && echo base-image-has-no-desktop"]),
    ], exec);
  } finally {
    await vm.delete();
    console.log(`deleted ${vmId}`);
  }
} else {
  throw new Error("usage: bun scripts/verify-devbox-image.ts freestyle <snapshot-id>");
}

if (!pass) process.exit(1);
