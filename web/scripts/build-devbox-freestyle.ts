#!/usr/bin/env bun
/**
 * Build the cmux Cloud devbox Freestyle snapshot on the public platform
 * (freestyle@0.2.x; api.freestyle.sh) on top of the `freestyle/ubuntu` base,
 * plus the desktop layer (web/services/vms/images/devbox/desktop, ported
 * from the retired Blaxel cmux-devbox image): an openbox/TigerVNC desktop
 * with a tint2 dock, Ghostty, Chrome, Thunar, and noVNC on 6901.
 *
 * Usage:
 *   bun scripts/build-devbox-freestyle.ts <snapshot-slug> [--out <json>]
 *       [--replace-slug] [--no-desktop] [--keep-builder]
 *
 * Prints the bake result as JSON (and writes it to --out); the LAST stdout
 * line is `IMAGE_ID sh-…`. promote-devbox-image.ts drives this, verifies the
 * snapshot, and records the id in the manifest.
 *
 * Uses what the base already ships instead of replaying the container
 * Dockerfile's toolchain: `freestyle/ubuntu` comes with Node LTS under nvm
 * (symlinked into /usr/local/bin), Bun, Python 3.12, uv, Docker (running from
 * boot), git, jq, tmux, and an `ubuntu` user (uid 1000, passwordless sudo,
 * the API's default exec user and the SSH default). The bake adds the
 * chatmux-devbox devtools, gh, Chrome + cua-driver, the pinned coding agents
 * (`npm install -g` on the base's Node, so the exact Dockerfile pins replace
 * the base's copies), the ble.sh devshell, the agent-config generator, the
 * login banner, and the desktop. No mise, no extra users: `ubuntu` is the
 * work user for terminals, agents, SSH, and the desktop session.
 *
 * Auth: FREESTYLE_API_KEY (permanent key from the Freestyle dashboard or
 * `freestyle tokens create`), or FREESTYLE_STACK_ACCESS_TOKEN +
 * FREESTYLE_TEAM_ID for interactive use (mint via `npx freestyle login`).
 * FREESTYLE_API_URL overrides the edge.
 *
 * Snapshot slugs are unique per account and reassignable
 * (freestyle.vms.snapshots.update); the immutable sh-… id is still the
 * pointer the manifest pins. With --replace-slug the bake moves a taken slug
 * onto the new snapshot (the old holder keeps its data under its id);
 * without it a collision leaves the new snapshot slugless.
 *
 * Builder VM: freestyle/ubuntu-sm (2 vCPU / 4 GiB / 16 GB), the floor of
 * Freestyle's size ladder. VMs boot at their snapshot's size and resizing is
 * grow-only, so the bake happens once at the smallest shape and
 * derive-devbox-sizes.ts turns it into one snapshot per ladder size.
 * CMUX_FREESTYLE_BUILDER_SNAPSHOT overrides the base.
 * Outbound-only firewall; deleted whatever happens (unless --keep-builder).
 *
 * Daemon contract: the session daemon is cmux-tui (docs/cloud-cmux-tui-daemon.md).
 * The bake installs the pinned files.cmux.com build (sha256-verified, the same
 * install command the driver's attach-time heal uses) at /root/.cmux/bin/cmux-tui
 * and the cmux-tui-daemon systemd unit runs /usr/local/bin/cmux-devbox-boot,
 * which starts and supervises it. The bake proves the daemon answers on
 * [::]:1337, then parks it: a snapshot is a memory image, so a daemon left
 * running would give every machine the builder's Noise identity. The
 * supervisor binds the identity to the platform instance id (see the boot
 * script) and every machine created from the snapshot starts its own daemon,
 * with a fresh identity, within one supervisor tick of resume. The driver
 * (web/services/vms/drivers/freestyle.ts) therefore runs no install, start, or
 * readiness exec at create; it writes the model-plane env file and returns.
 * The unit binds the listener dual-stack (CMUX_TUI_REMOTE_WS_BIND=[::]:1337)
 * because the driver routes attaches to the VM's stable public IPv6. The
 * daemon still runs as root until the driver adopts the ubuntu user for
 * sessions.
 *
 * Desktop contract (desktop/start-vnc.sh): RFB 5901 loopback, noVNC 6901,
 * run as `ubuntu` by the cmux-desktop systemd unit.
 */
import { Freestyle } from "freestyle";
import { fileURLToPath } from "node:url";
import {
  CMUX_TUI_SESSION,
  cmuxTuiInstallCommand,
  cmuxTuiPinCheckCommand,
  resolveCmuxTuiSource,
} from "../services/vms/drivers/cmuxTuiDaemon";
import {
  DEVBOX_GHOSTTY_DEB_URL,
  DEVBOX_INSTANCE_ID_COMMAND,
  bakeMetadata,
  bakePreflight,
  devboxAgentPins,
  devboxCuaDriverVersion,
  devboxFileBytes,
  devboxParkDaemonCommand,
  emitBakeResult,
  hasFlag,
  manifestEntrySkeleton,
} from "./devbox-image-common";

const apiKey = process.env.FREESTYLE_API_KEY;
const stackToken = process.env.FREESTYLE_STACK_ACCESS_TOKEN;
const teamId = process.env.FREESTYLE_TEAM_ID;
const baseUrl = process.env.FREESTYLE_API_URL?.trim() || undefined;
const fs = (() => {
  if (apiKey) return new Freestyle({ apiKey, baseUrl });
  if (stackToken && teamId) return new Freestyle({ stackAccessToken: stackToken, teamId, baseUrl });
  throw new Error("set FREESTYLE_API_KEY, or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID");
})();

const slug = process.argv[2];
if (!slug || slug.startsWith("--")) {
  throw new Error("usage: bun scripts/build-devbox-freestyle.ts <snapshot-slug> [--out <json>] [--replace-slug] [--no-desktop] [--keep-builder]");
}
if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(slug) || slug.includes("--")) {
  throw new Error(`snapshot slug ${slug} must be 1–63 chars of [a-z0-9-] with no leading, trailing, or repeated hyphens`);
}
const withDesktop = !hasFlag("--no-desktop");
const keepBuilder = hasFlag("--keep-builder");
const replaceSlug = hasFlag("--replace-slug");

const preflight = bakePreflight({ desktop: withDesktop });
// Resolved before the builder exists so a manifest outage fails the bake for free.
const cmuxTuiSource = await resolveCmuxTuiSource("freestyle");

// The exec API caps timeoutMs at 300000 (5 minutes per step).
const STEP_TIMEOUT_MS = 300_000;

// Per-exec env (the API replays it into every step). The base's login PATH
// puts the nvm bin dir first; /usr/local/bin carries the same tools as
// symlinks, so this is what a non-login shell sees too.
const BUILD_ENV = {
  PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
  DEBIAN_FRONTEND: "noninteractive",
  LANG: "C.UTF-8",
};

/** The work user: the base's uid-1000 account, the API and SSH default. */
const WORK_USER = "ubuntu";

const instanceIdCommand = DEVBOX_INSTANCE_ID_COMMAND;
const WORK_HOME = `/home/${WORK_USER}`;

const builderSnapshot = process.env.CMUX_FREESTYLE_BUILDER_SNAPSHOT?.trim() || "freestyle/ubuntu-sm";
const { vm, vmId } = await fs.vms.create({
  snapshotId: builderSnapshot,
  displayName: `cmux-devbox-builder ${slug}`,
  firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] },
});
console.log(`builder VM ${vmId} (base ${builderSnapshot}, desktop=${withDesktop})`);

async function deleteBuilder(): Promise<void> {
  if (keepBuilder) {
    console.log(`--keep-builder: leaving ${vmId} running`);
    return;
  }
  await vm.delete().catch((error: unknown) => console.warn(`builder delete failed: ${String(error)}`));
}

// Freestyle guest exec starts with an EMPTY $HOME; restore it before every
// step (npm and the installers all read it).
const HOME_PREFIX = 'export HOME="${HOME:-$(getent passwd $(id -u) | cut -d: -f6)}"';

async function step(label: string, command: string): Promise<void> {
  const t0 = Date.now();
  const r = await vm.exec({
    command: `${HOME_PREFIX} && ${command}`,
    env: BUILD_ENV,
    timeoutMs: STEP_TIMEOUT_MS,
    // The 0.2 API's default guest user is uid 1000 (ubuntu). Every build step
    // writes to /usr/local and /etc, so the bake runs as root.
    linuxUser: "root",
  });
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  const exitCode = r.statusCode ?? 124;
  if (exitCode !== 0) {
    console.error(`STEP FAILED [${label}] status=${exitCode} (${secs}s)`);
    console.error("stdout:", (r.stdout ?? "").slice(-3000));
    console.error("stderr:", (r.stderr ?? "").slice(-3000));
    await deleteBuilder();
    process.exit(1);
  }
  const tail = (r.stdout ?? "").trim().split("\n").slice(-3).join(" | ");
  console.log(`ok [${label}] ${secs}s :: ${tail}`);
}

/**
 * Ship a checked-in template file into the guest. The fs API writes as root,
 * atomically and sha256-verified, so no base64 smuggling through exec; the
 * mode is explicit because the API defaults new files to 0600.
 */
async function put(source: string, target: string, mode = 0o644): Promise<void> {
  const t0 = Date.now();
  await vm.fs.writeFile(target, devboxFileBytes(source), { mode });
  console.log(`put ${source} -> ${target} (${(mode).toString(8)}) ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}

// The devshell chain goes into the per-user rc files, not /etc/bash.bashrc:
// bash sources the system file BEFORE ~/.bashrc, and Ubuntu's stock ~/.bashrc
// sets its own PS1, which would clobber the cmux prompt. Per-user only also
// loads ble.sh exactly once per shell (the container Dockerfile appends to
// both because its homes are shadowed by volumes at runtime).
const rcFiles = ["/etc/skel/.bashrc", "/root/.bashrc", `${WORK_HOME}/.bashrc`];
const pins = devboxAgentPins();
/**
 * A real interactive shell as the work user under a tmux pty (ble.sh refuses
 * `bash -c` and ttyless shells; `script` with a closed stdin is not a faithful
 * login either). Fails if the pane shows anything ble.sh or bash complained
 * about, the Ubuntu legal text, or (on the second run, once caches are seeded)
 * the tput-cache notice, and requires the cmux prompt. Runs as the work user
 * so nothing it creates is root-owned.
 */
const interactiveShellProbe = (run: number): string =>
  `sudo -n -u ${WORK_USER} env -i HOME=${WORK_HOME} USER=${WORK_USER} TERM=xterm-256color PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -c 'tmux -L probe${run} new-session -d -s login -x 120 -y 30 && sleep 3 && pane="$(tmux -L probe${run} capture-pane -pt login)"; tmux -L probe${run} kill-server 2>/dev/null; printf "%s\\n" "$pane" | grep -iE "ble\\.sh|bleopt|ble-face|denied|not found|WARRANTY${run > 1 ? "|updating tput" : ""}" && { printf "%s\\n" "$pane"; exit 1; }; printf "%s\\n" "$pane" | grep -q "λ" || { printf "%s\\n" "$pane"; echo "no cmux prompt"; exit 1; }'`;

try {
  await step(
    "base-inventory",
    `id ${WORK_USER} && [ "$(id -u ${WORK_USER})" = 1000 ] && sudo -n -u ${WORK_USER} sudo -n true && node --version && npm --version && bun --version && python3 --version && uv --version && docker --version && test -L /usr/local/bin/node && readlink /usr/local/bin/node | grep -q /usr/local/nvm/ && echo base-ok`,
  );

  await step(
    "apt-devtools",
    "apt-get update -q && apt-get install -y --no-install-recommends git ripgrep build-essential curl ca-certificates unzip zip xz-utils zstd procps iproute2 openssh-client pkg-config jq fd-find fzf sqlite3 tmux less rsync file tree nano vim sudo util-linux && rm -rf /var/lib/apt/lists/* && ln -sf $(command -v fdfind) /usr/local/bin/fd && echo 'LANG=C.UTF-8' > /etc/default/locale && fd --version && jq --version && fzf --version && sqlite3 --version && tmux -V",
  );

  await step(
    "gh-cli",
    "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" > /etc/apt/sources.list.d/github-cli.list && apt-get update -q && apt-get install -y --no-install-recommends gh && rm -rf /var/lib/apt/lists/* && gh --version",
  );

  await step(
    "media-apt",
    "apt-get update -q && apt-get install -y --no-install-recommends ffmpeg xvfb xauth x11-utils xdotool fonts-dejavu-core fonts-liberation && rm -rf /var/lib/apt/lists/* && command -v Xvfb && command -v xdpyinfo && command -v xdotool",
  );

  await step(
    "chrome",
    "curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && apt-get update -q && apt-get install -y --no-install-recommends /tmp/chrome.deb && rm -f /tmp/chrome.deb && rm -rf /var/lib/apt/lists/* && google-chrome-stable --version",
  );

  await step("chrome-policy-dir", "mkdir -p /etc/opt/chrome/policies/managed");
  await put("chrome-managed-policy.json", "/etc/opt/chrome/policies/managed/cmux.json");
  await step(
    "chrome-policy",
    "jq -e '.DefaultSearchProviderSearchURL | test(\"duckduckgo\")' /etc/opt/chrome/policies/managed/cmux.json && echo 'export AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable' > /etc/profile.d/cmux-media.sh",
  );

  const cuaVersion = devboxCuaDriverVersion();
  await step(
    "cua-driver",
    `curl -fsSL https://cua.ai/driver/install.sh -o /tmp/cua-install.sh && CUA_DRIVER_RS_HOME=/opt/cua-driver CUA_DRIVER_RS_VERSION=${cuaVersion} CUA_DRIVER_BIN_DIR=/usr/local/bin CUA_DRIVER_NO_MODIFY_PATH=1 bash /tmp/cua-install.sh && rm -f /tmp/cua-install.sh && chmod -R a+rX /opt/cua-driver && cua-driver --version`,
  );

  // Pinned coding agents on the base's Node: the exact Dockerfile pins
  // replace the base's own copies of claude/codex/opencode in nvm's global
  // node_modules, and every agent bin is symlinked into /usr/local/bin the
  // way the base does it, so non-login shells (daemon panes) find them too.
  await step(
    "agents",
    // The pin probes run AS the work user: an agent run as root with
    // HOME=/home/ubuntu leaves root-owned state dirs behind that break
    // ble.sh for every later login.
    `npm install -g --foreground-scripts ${pins.map((pin) => `'${pin.spec}'`).join(" ")} && nvm_bin="$(dirname "$(readlink -f /usr/local/bin/node)")" && ${pins.map((pin) => `ln -sfn "$nvm_bin/${pin.binary}" /usr/local/bin/${pin.binary}`).join(" && ")} && ${pins.map((pin) => `${pin.binary} --version`).join(" && ")} && ${pins.map((pin) => `sudo -n -u ${WORK_USER} env -i HOME=${WORK_HOME} USER=${WORK_USER} TERM=xterm bash -lc '${pin.binary} --version' | grep -F '${pin.version}'`).join(" && ")} && echo agents-pinned`,
  );

  await step(
    "claude-managed-settings",
    `mkdir -p /etc/claude-code && echo '{ "cleanupPeriodDays": 99999 }' > /etc/claude-code/managed-settings.json && node -e 'JSON.parse(require("fs").readFileSync("/etc/claude-code/managed-settings.json","utf8"))'`,
  );

  // devshell replays the Dockerfile devshell + ble.sh tput cache bake (same
  // echo-fed seed shells and test -s guards; see ../services/vms/images/devbox/Dockerfile).
  // Cache seeds cover root and the ubuntu work user (uid 1000).
  await step("cmux-etc", "mkdir -p /etc/cmux /etc/skel");
  await put("cmux-bashrc", "/etc/cmux/bashrc");
  await put("seed-history", "/etc/cmux/seed-history");
  await step(
    "devshell",
    `curl -fsSL https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz -o /tmp/ble.tar.xz && tar xJf /tmp/ble.tar.xz -C /tmp && rm -rf /usr/local/share/blesh && mv /tmp/ble-nightly /usr/local/share/blesh && rm -f /tmp/ble.tar.xz && test -f /usr/local/share/blesh/ble.sh && bash -n /etc/cmux/bashrc && ${rcFiles.map((rc) => `echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> ${rc}`).join(" && ")} && echo 'set -g default-shell /bin/bash' >> /etc/tmux.conf && bash -ic 'head -2 $HOME/.bash_history' && mkdir -p /etc/cmux/blesh-cache-seed /tmp/blesh-seed-home && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' > /tmp/blesh-seed-home/.bashrc && for term in xterm-256color screen-256color tmux-256color linux xterm-ghostty; do echo exit | TERM="$term" HOME=/tmp/blesh-seed-home XDG_CACHE_HOME=/etc/cmux/blesh-cache-seed script -qec 'bash -i' /dev/null >/dev/null 2>&1 || true; done && rm -rf /tmp/blesh-seed-home && chmod -R a+rX /etc/cmux/blesh-cache-seed && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.xterm-256color && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.screen-256color && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.tmux-256color && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.linux && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.xterm-ghostty && mkdir -p /usr/local/share/blesh/cache.d/0 /usr/local/share/blesh/cache.d/1000 && chmod a+rwxt /usr/local/share/blesh/cache.d && cp /etc/cmux/blesh-cache-seed/blesh/*/term.* /usr/local/share/blesh/cache.d/0/ && cp /etc/cmux/blesh-cache-seed/blesh/*/term.* /usr/local/share/blesh/cache.d/1000/ && chmod 700 /usr/local/share/blesh/cache.d/0 /usr/local/share/blesh/cache.d/1000 && chown -R 1000:1000 /usr/local/share/blesh/cache.d/1000`,
  );

  await put("agent-config.sh", "/etc/cmux/agent-config.sh");
  await step(
    "agent-config",
    `bash -n /etc/cmux/agent-config.sh && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' > /etc/profile.d/cmux-agents.sh && ${rcFiles.map((rc) => `echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> ${rc}`).join(" && ")} && mkdir -p /tmp/agent-config-check && env HOME=/tmp/agent-config-check OPENAI_BASE_URL=https://example.invalid/v1 OPENAI_API_KEY=crt_check CMUX_CODEROUTER_URL=https://example.invalid bash -lc 'true' && grep -q 'model_provider = "cmux"' /tmp/agent-config-check/.codex/config.toml && grep -q 'wire_api = "responses"' /tmp/agent-config-check/.codex/config.toml && grep -q 'supports_websockets = false' /tmp/agent-config-check/.codex/config.toml && grep -q "export OPENAI_API_KEY='crt_check'" /tmp/agent-config-check/.config/cmux/model-plane.env && [ "$(stat -c %a /tmp/agent-config-check/.config/cmux/model-plane.env)" = "600" ] && grep -qF '"x-coderouter-route-token": "$OPENAI_API_KEY"' /tmp/agent-config-check/.pi/agent/models.json && ! grep -q crt_check /tmp/agent-config-check/.pi/agent/models.json && test ! -e /tmp/agent-config-check/.config/opencode/opencode.json && rm -rf /tmp/agent-config-check && test ! -e /root/.codex/config.toml && test ! -e /root/.pi/agent/models.json && test ! -e /root/.config/opencode/opencode.json && test ! -e ${WORK_HOME}/.codex/config.toml`,
  );

  // Login banner: pam_motd renders /etc/update-motd.d on SSH logins. The
  // stock Ubuntu scripts stay but go silent, Freestyle's static /etc/motd is
  // emptied, and the versions the banner prints are written once here (the
  // agent line straight from the Dockerfile pins) so login never runs a tool.
  await put("cmux-motd", "/etc/update-motd.d/00-cmux", 0o755);
  await step(
    "motd",
    `sh -n /etc/update-motd.d/00-cmux && for f in /etc/update-motd.d/*; do [ "$f" = /etc/update-motd.d/00-cmux ] || chmod -x "$f"; done && : > /etc/motd && echo '${pins.filter((pin) => pin.binary !== "agent-browser").map((pin) => `${pin.binary} ${pin.version}`).join(" · ")}' > /etc/cmux/tool-versions && echo "node $(node --version) · python $(python3 --version | awk '{print $2}') · bun $(bun --version) · uv $(uv --version | awk '{print $2}') · gh $(gh --version | head -1 | awk '{print $3}') · docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)" >> /etc/cmux/tool-versions && cat /etc/cmux/tool-versions && run-parts /etc/update-motd.d | grep -q 'persistent cloud VM' && ! run-parts /etc/update-motd.d | grep -qi 'ubuntu.com' && echo motd-ok`,
  );

  if (withDesktop) {
    // Desktop + media stack (Blaxel cmux-devbox apt list): TigerVNC, openbox,
    // tint2, Thunar, feh, noVNC + websockify, and the GL/Vulkan/xkb libraries
    // Ghostty and Chrome render with under Xvnc.
    await step(
      "desktop-apt",
      "apt-get update -q && apt-get install -y --no-install-recommends tigervnc-standalone-server tigervnc-tools openbox tint2 thunar feh novnc websockify at-spi2-core dbus-x11 x11-xserver-utils xdg-utils adwaita-icon-theme libgl1-mesa-dri mesa-vulkan-drivers libvulkan1 libxkbcommon0 libxkbcommon-x11-0 netcat-openbsd && rm -rf /var/lib/apt/lists/* && { [ -e /usr/share/novnc/index.html ] || ln -s vnc.html /usr/share/novnc/index.html; } && command -v Xtigervnc && command -v websockify && command -v openbox && command -v tint2",
    );

    // Ghostty: pinned community .deb for Ubuntu 24.04 (no upstream .deb
    // exists). libgl1-mesa-dri above is the software GL its renderer uses.
    await step(
      "ghostty",
      `curl -fsSL -o /tmp/ghostty.deb ${DEVBOX_GHOSTTY_DEB_URL} && apt-get update -q && apt-get install -y --no-install-recommends /tmp/ghostty.deb && rm -rf /var/lib/apt/lists/* /tmp/ghostty.deb && ghostty +version | head -1`,
    );

    // Dock launchers and icons live under /etc/cmux so the dock never depends
    // on a distro's /usr/share/applications or icon-theme layout.
    await step("desktop-dirs", "mkdir -p /etc/cmux/apps /etc/cmux/icons /usr/share/backgrounds/cmux");
    await put("desktop/google-chrome-cmux.desktop", "/etc/cmux/apps/google-chrome-cmux.desktop");
    await put("desktop/thunar-cmux.desktop", "/etc/cmux/apps/thunar-cmux.desktop");
    await put("desktop/ghostty-cmux.desktop", "/etc/cmux/apps/ghostty-cmux.desktop");
    await put("desktop/tint2rc", "/etc/cmux/tint2rc");
    await put("desktop/wallpaper.jpg", "/usr/share/backgrounds/cmux/wallpaper.jpg");
    await put("desktop/start-vnc.sh", "/usr/local/bin/start-vnc.sh", 0o755);
    await put("desktop/cmux-desktop-boot", "/usr/local/bin/cmux-desktop-boot", 0o755);
    await put("desktop/cmux-desktop.service", "/etc/systemd/system/cmux-desktop.service");
    await step(
      "desktop-icons",
      "cp /opt/google/chrome/product_logo_128.png /etc/cmux/icons/google-chrome.png && cp \"$(find /usr/share/icons -name 'org.xfce.thunar.png' -path '*128*' | head -1)\" /etc/cmux/icons/thunar.png && cp \"$(find /usr/share/icons -name 'com.mitchellh.ghostty.png' -path '*128*' | head -1)\" /etc/cmux/icons/ghostty.png && test -s /etc/cmux/icons/thunar.png && test -s /etc/cmux/icons/ghostty.png && test -s /etc/cmux/icons/google-chrome.png",
    );

    // Bring the desktop up under systemd as the work user and prove the
    // contract ports answer. The "First Run" marker pre-accepts Chrome's
    // first-run/ToS dialog (cmux-desktop-boot re-asserts it on every boot).
    await step(
      "desktop-unit",
      `bash -n /usr/local/bin/start-vnc.sh && sh -n /usr/local/bin/cmux-desktop-boot && grep -q '^User=${WORK_USER}$' /etc/systemd/system/cmux-desktop.service && mkdir -p ${WORK_HOME}/.config/google-chrome && touch '${WORK_HOME}/.config/google-chrome/First Run' && chown -R ${WORK_USER}:${WORK_USER} ${WORK_HOME}/.config && systemctl daemon-reload && systemctl enable --now cmux-desktop && for i in $(seq 1 60); do ss -tln | grep -q ':6901 ' && ss -tln | grep -q ':5901 ' && break; sleep 1; done && ss -tln | grep -q ':5901 ' && ss -tln | grep -q ':6901 ' && curl -fsS http://127.0.0.1:6901/ | grep -qi novnc && pgrep -u ${WORK_USER} -x openbox >/dev/null && pgrep -u ${WORK_USER} -x tint2 >/dev/null && systemctl is-active cmux-desktop && runuser -u ${WORK_USER} -- env DISPLAY=:1 xdpyinfo | grep dimensions`,
    );
  }

  // The pinned cmux-tui build, installed with the driver's own command so the
  // bake and the attach-time heal can never disagree about path or digest.
  console.log(`cmux-tui pin: commit ${cmuxTuiSource.commit} sha256 ${cmuxTuiSource.sha256.slice(0, 12)}…`);
  await step("cmux-tui-install", cmuxTuiInstallCommand(cmuxTuiSource));
  await step(
    "cmux-tui-pin",
    `${cmuxTuiPinCheckCommand(cmuxTuiSource)} && mkdir -p /etc/cmux /root/.config/cmux && printf '%s %s\n' ${cmuxTuiSource.sha256} ${cmuxTuiSource.commit} > /etc/cmux/cmux-tui-pin && cat /etc/cmux/cmux-tui-pin`,
  );

  // The cmux-tui daemon supervisor + its systemd unit (see the header).
  const service = [
    "[Unit]",
    "Description=cmux-tui session daemon supervisor",
    "After=network.target",
    "",
    "[Service]",
    "Type=simple",
    "User=root",
    // Freestyle machines are reached at their stable public IPv6, so the
    // daemon listens dual-stack ([::] accepts IPv4 too). cmux-devbox-boot
    // defaults to 0.0.0.0 for the container providers, whose runtimes may have
    // IPv6 disabled entirely.
    "Environment=CMUX_TUI_REMOTE_WS_BIND=[::]:1337",
    // Pane shells inherit this PATH; /usr/local/bin carries the base's Node
    // and every pinned agent as symlinks, so no login shell is needed.
    "Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "ExecStart=/usr/local/bin/cmux-devbox-boot",
    "Restart=always",
    "RestartSec=2",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
  ].join("\n");
  await put("cmux-devbox-boot", "/usr/local/bin/cmux-devbox-boot", 0o755);
  await vm.fs.writeFile("/etc/systemd/system/cmux-tui-daemon.service", `${service}\n`, { mode: 0o644 });
  await step(
    "cmux-tui-daemon-unit",
    "sh -n /usr/local/bin/cmux-devbox-boot && rm -f /etc/cmux/bake-instance-id && mkdir -p /etc/systemd/system/multi-user.target.wants && ln -sf /etc/systemd/system/cmux-tui-daemon.service /etc/systemd/system/multi-user.target.wants/cmux-tui-daemon.service && systemctl daemon-reload && systemctl enable cmux-tui-daemon && systemctl restart cmux-tui-daemon && systemctl is-active cmux-tui-daemon",
  );
  // Prove the daemon contract on the builder: the supervisor started the
  // daemon on its own, the session answers, and the listener is dual-stack.
  await step(
    "cmux-tui-daemon-up",
    `for i in $(seq 1 30); do env HOME=/root /root/.cmux/bin/cmux-tui server status --session ${CMUX_TUI_SESSION} >/dev/null 2>&1 && grep -qi ':0539 ' /proc/net/tcp6 && break; sleep 1; done && env HOME=/root /root/.cmux/bin/cmux-tui server status --session ${CMUX_TUI_SESSION} && grep -qi ':0539 ' /proc/net/tcp6 && test "$(cat /etc/cmux/daemon-instance-id)" = "$(${instanceIdCommand})" && echo daemon-up-bound-to-builder`,
  );
  // Park it (devboxParkDaemonCommand): the supervisor stops the daemon while
  // the machine's id equals the recorded bake id, its identity and session
  // state are wiped, and a clone (different id) starts fresh within one tick.
  await step("cmux-tui-daemon-park", devboxParkDaemonCommand());

  await step(
    "ghost-text-smoke",
    "tmux new-session -d -s ghost -x 100 -y 24 && sleep 2 && tmux send-keys -t ghost cl && sleep 2 && tmux capture-pane -pt ghost | grep -o 'claude --dangerously-skip-permissions' | head -1; rc=$?; tmux kill-session -t ghost 2>/dev/null; tmux kill-server 2>/dev/null; test $rc -eq 0",
  );

  // Home hygiene, after every layer that could have touched the work user's
  // home: ble.sh needs a writable state dir (XDG state when it already
  // exists, else <blesh>/state.d/<uid>, which must be world-writable-sticky
  // like cache.d), nothing in the home may be root-owned, and Ubuntu's
  // pam_motd prints /etc/legal on every login (twice: sshd lists pam_motd
  // twice) until ~/.cache/motd.legal-displayed exists. Then prove two real
  // interactive logins as the work user are silent and ghost text works.
  await step(
    "home-hygiene",
    `mkdir -p /usr/local/share/blesh/state.d && chmod a+rwxt /usr/local/share/blesh/state.d && for h in ${WORK_HOME} /root /etc/skel; do mkdir -p "$h/.cache" "$h/.local/state" && touch "$h/.cache/motd.legal-displayed"; done && chown -R ${WORK_USER}:${WORK_USER} ${WORK_HOME} && [ "$(find ${WORK_HOME} -not -user ${WORK_USER} | wc -l)" = 0 ] && ${interactiveShellProbe(1)} && ${interactiveShellProbe(2)} && sudo -n -u ${WORK_USER} env -i HOME=${WORK_HOME} USER=${WORK_USER} TERM=xterm-256color bash -c 'tmux -L bake new-session -d -s ghost -x 100 -y 24 && sleep 2 && tmux -L bake send-keys -t ghost cl && sleep 2 && tmux -L bake capture-pane -pt ghost | grep -o "claude --dangerously-skip-permissions" | head -1; rc=$?; tmux -L bake kill-server 2>/dev/null; exit $rc' && [ "$(find ${WORK_HOME} -not -user ${WORK_USER} | wc -l)" = 0 ] && echo home-hygiene-ok`,
  );

  // Stamp last: its presence tells the driver and the verifier every layer
  // above baked successfully, and which layers the image carries.
  await step(
    "image-stamp",
    `mkdir -p /etc/cmux && echo "cmux-devbox ${preflight.epoch}${withDesktop ? " desktop" : ""}" > /etc/cmux/image-stamp && cat /etc/cmux/image-stamp`,
  );

  await step("clean", `rm -rf /var/lib/apt/lists/* /root/.npm/_cacache ${WORK_HOME}/.npm/_cacache 2>/dev/null; sync; true`);
} catch (error) {
  console.error(`bake failed: ${String(error)}`);
  await deleteBuilder();
  process.exit(1);
}

// Snapshot slugless first (the sh-… id is the pointer), then attach the slug.
// A slug already held by another snapshot only moves with --replace-slug.
const displayName = `cmux devbox ${slug} (epoch ${preflight.epoch}, ${preflight.sha.slice(0, 10)})`;
const snap = await vm.snapshot({ displayName });
const snapshotId = snap.snapshotId;
console.log("SNAPSHOT_RESULT", JSON.stringify(snap));
if (!snapshotId) {
  await deleteBuilder();
  throw new Error("Freestyle snapshot response carried no snapshot id; do not pin this bake");
}
await deleteBuilder();
console.log(keepBuilder ? "builder kept" : "builder deleted");

let assignedSlug: string | null = null;
try {
  await fs.vms.snapshots.update(snapshotId, { slug });
  assignedSlug = slug;
} catch (error) {
  if (!replaceSlug) {
    console.warn(`slug ${slug} not assigned (${String(error).slice(0, 160)}); pass --replace-slug to move it. The id is the pointer.`);
  } else {
    const { snapshots } = await fs.vms.snapshots.list();
    const holder = snapshots.find((candidate) => candidate.slug === slug && candidate.id !== snapshotId);
    if (!holder) throw error;
    await fs.vms.snapshots.update(holder.id, { slug: "" });
    console.log(`slug ${slug} released from ${holder.id}`);
    await fs.vms.snapshots.update(snapshotId, { slug });
    assignedSlug = slug;
  }
}

const metadata = bakeMetadata(preflight, fileURLToPath(import.meta.url));
emitBakeResult({
  provider: "freestyle",
  imageId: snapshotId,
  slug: assignedSlug,
  builderSnapshot,
  desktop: withDesktop,
  manifestEntry: {
    ...manifestEntrySkeleton(
      "freestyle",
      `freestyle-${slug}`,
      snapshotId,
      "FREESTYLE_SANDBOX_SNAPSHOT",
      metadata,
      withDesktop
        ? `Devbox on the Freestyle public platform (api.freestyle.sh) from ${builderSnapshot}: the base's Node/Bun/Python/uv/Docker plus pinned agents, devtools, Chrome + cua-driver, ble.sh devshell, cmux login banner, and the desktop layer (openbox/TigerVNC 5901, noVNC 6901, Ghostty, Chrome, Thunar) run by the cmux-desktop systemd unit as ubuntu; ubuntu (uid 1000, NOPASSWD sudo) is the work user; baked cmux-tui daemon ${cmuxTuiSource.commit.slice(0, 10)}, identity bound to the instance id, no create-time bootstrap.`
        : `Devbox on the Freestyle public platform (api.freestyle.sh) from ${builderSnapshot}: the base's Node/Bun/Python/uv/Docker plus pinned agents, devtools, Chrome + cua-driver, ble.sh devshell, cmux login banner; ubuntu (uid 1000, NOPASSWD sudo) is the work user; baked cmux-tui daemon ${cmuxTuiSource.commit.slice(0, 10)}, identity bound to the instance id, no create-time bootstrap.`,
      withDesktop ? "desktop" : "base",
    ),
    cmuxTuiCommit: cmuxTuiSource.commit,
    cmuxTuiSha256: cmuxTuiSource.sha256,
  },
  next: `bun scripts/verify-devbox-image.ts freestyle ${snapshotId}`,
});
