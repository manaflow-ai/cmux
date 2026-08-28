#!/usr/bin/env bun
/**
 * Build the cmux Cloud devbox Freestyle snapshot on the BETA platform
 * (freestyle@0.2.0-beta.7 via the freestyle-beta alias; beta-api.freestyle.sh)
 * by replaying web/services/vms/images/devbox/Dockerfile as exec steps on a
 * builder VM, mirroring chatmux infra/sandbox-images/build-freestyle.ts.
 * The exec API has no COPY; small repo files travel as base64 embeds.
 *
 * Usage:
 *   bun scripts/build-devbox-freestyle.ts <snapshot-slug>
 *
 * Auth: FREESTYLE_API_KEY (permanent key from beta-dashboard.freestyle.sh),
 * or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID for interactive use
 * (mint via `npx freestyle@beta login`).
 *
 * Freestyle snapshot slugs are unique per account and creation does not
 * reassign, so pass a fresh versioned slug per rebuild (cmux-devbox-<tag>);
 * on a slug collision the snapshot falls back to slugless. Either way the
 * immutable sh-… id in SNAPSHOT_RESULT is the real pointer to pin.
 *
 * Daemon contract: the session daemon is cmux-tui, same as every other
 * provider (docs/cloud-cmux-tui-daemon.md). No binary is baked: the
 * cmux-tui-daemon systemd unit runs /usr/local/bin/cmux-devbox-boot, which
 * waits for /root/.cmux/bin/cmux-tui and supervises the daemon once a driver
 * installs the pinned build at create time. FORWARD-COMPATIBLE ONLY: the
 * shipped freestyle driver still speaks the legacy (0.1.51) platform and its
 * cmuxd-remote transport; it can neither boot beta snapshots nor talk to
 * cmux-tui. This bake becomes usable when a beta-SDK freestyle driver lands;
 * until then FREESTYLE_SANDBOX_SNAPSHOT must not point at it.
 *
 * Builder VM: freestyle/ubuntu-sm, outbound-only firewall, deleted whatever
 * happens.
 */
import { Freestyle } from "freestyle-beta";
import { fileURLToPath } from "node:url";
import {
  bakeMetadata,
  bakePreflight,
  devboxAgentPins,
  fileBase64,
  manifestEntrySkeleton,
} from "./devbox-image-common";

const apiKey = process.env.FREESTYLE_API_KEY;
const stackToken = process.env.FREESTYLE_STACK_ACCESS_TOKEN;
const teamId = process.env.FREESTYLE_TEAM_ID;
const fs = (() => {
  if (apiKey) return new Freestyle({ apiKey });
  if (stackToken && teamId) return new Freestyle({ stackAccessToken: stackToken, teamId });
  throw new Error("set FREESTYLE_API_KEY, or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID");
})();

const slug = process.argv[2];
if (!slug || slug.startsWith("--")) {
  throw new Error("usage: bun scripts/build-devbox-freestyle.ts <snapshot-slug>");
}

const preflight = bakePreflight();

// The beta exec API caps timeoutMs at 300000 (5 minutes per step).
const STEP_TIMEOUT_MS = 300_000;

// Per-exec env (the beta API replays it into every step): the Dockerfile's
// ENV block, PATH literal included.
const BUILD_ENV = {
  MISE_DATA_DIR: "/opt/mise",
  MISE_CACHE_DIR: "/opt/mise/cache",
  MISE_GLOBAL_CONFIG_FILE: "/etc/mise/config.toml",
  PATH: "/opt/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
  DEBIAN_FRONTEND: "noninteractive",
  LANG: "C.UTF-8",
};

const builderSnapshot = process.env.CMUX_FREESTYLE_BUILDER_SNAPSHOT?.trim() || "freestyle/ubuntu-sm";
const { vm, vmId } = await fs.vms.create({
  snapshotId: builderSnapshot,
  displayName: "cmux-devbox-builder",
  firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] },
});
console.log(`builder VM ${vmId} (base ${builderSnapshot})`);

// Freestyle guest exec starts with an EMPTY $HOME; restore it before every
// step (npm, mise, and the installers all read it).
const HOME_PREFIX = 'export HOME="${HOME:-$(getent passwd $(id -u) | cut -d: -f6)}"';

async function step(label: string, command: string): Promise<void> {
  const t0 = Date.now();
  const r = await vm.exec({
    command: `${HOME_PREFIX} && ${command}`,
    env: BUILD_ENV,
    timeoutMs: STEP_TIMEOUT_MS,
  });
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  const exitCode = r.statusCode ?? 124;
  if (exitCode !== 0) {
    console.error(`STEP FAILED [${label}] status=${exitCode} (${secs}s)`);
    console.error("stdout:", (r.stdout ?? "").slice(-3000));
    console.error("stderr:", (r.stderr ?? "").slice(-3000));
    await vm.delete().catch(() => {});
    process.exit(1);
  }
  const tail = (r.stdout ?? "").trim().split("\n").slice(-3).join(" | ");
  console.log(`ok [${label}] ${secs}s :: ${tail}`);
}

const installFile = (source: string, target: string): string =>
  `echo '${fileBase64(source)}' | base64 -d > ${target}`;

await step(
  "apt-devtools",
  "apt-get update -q && apt-get install -y --no-install-recommends git ripgrep build-essential curl ca-certificates unzip zip xz-utils zstd procps openssh-client pkg-config jq fd-find fzf sqlite3 tmux less rsync file tree nano vim sudo && rm -rf /var/lib/apt/lists/* && ln -sf $(command -v fdfind) /usr/local/bin/fd && echo 'LANG=C.UTF-8' > /etc/default/locale && fd --version && jq --version && fzf --version && sqlite3 --version && tmux -V",
);

await step(
  "gh-cli",
  "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" > /etc/apt/sources.list.d/github-cli.list && apt-get update -q && apt-get install -y --no-install-recommends gh && rm -rf /var/lib/apt/lists/* && gh --version",
);

await step(
  "mise",
  "curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh && mkdir -p /etc/mise /etc/profile.d && echo 'export MISE_DATA_DIR=/opt/mise' > /etc/profile.d/mise.sh && echo 'export MISE_CACHE_DIR=/opt/mise/cache' >> /etc/profile.d/mise.sh && echo 'export MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml' >> /etc/profile.d/mise.sh && echo 'export PATH=\"/opt/mise/shims:$PATH\"' >> /etc/profile.d/mise.sh && mise --version",
);

await step(
  "toolchain",
  "mise use -g node@lts python@3.12 bun@latest && mise reshim && node --version && npm --version && python --version && bun --version",
);

await step(
  "uv",
  "curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh && uv --version",
);

await step(
  "media-apt",
  "apt-get update -q && apt-get install -y --no-install-recommends ffmpeg xvfb xauth x11-utils xdotool fonts-dejavu-core fonts-liberation && rm -rf /var/lib/apt/lists/* && command -v Xvfb && command -v xdpyinfo && command -v xdotool",
);

await step(
  "chrome",
  "curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && apt-get update -q && apt-get install -y --no-install-recommends /tmp/chrome.deb && rm -f /tmp/chrome.deb && rm -rf /var/lib/apt/lists/* && google-chrome-stable --version",
);

await step(
  "chrome-policy",
  `mkdir -p /etc/opt/chrome/policies/managed && ${installFile("chrome-managed-policy.json", "/etc/opt/chrome/policies/managed/cmux.json")} && jq -e '.DefaultSearchProviderSearchURL | test("duckduckgo")' /etc/opt/chrome/policies/managed/cmux.json && echo 'export AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable' > /etc/profile.d/cmux-media.sh`,
);

await step(
  "cua-driver",
  "curl -fsSL https://cua.ai/driver/install.sh -o /tmp/cua-install.sh && CUA_DRIVER_RS_HOME=/opt/cua-driver CUA_DRIVER_RS_VERSION=0.19.3 CUA_DRIVER_BIN_DIR=/usr/local/bin CUA_DRIVER_NO_MODIFY_PATH=1 bash /tmp/cua-install.sh && rm -f /tmp/cua-install.sh && chmod -R a+rX /opt/cua-driver && cua-driver --version",
);

const pins = devboxAgentPins();
await step(
  "agents",
  `npm install -g --foreground-scripts ${pins.map((pin) => `'${pin.spec}'`).join(" ")} && mise reshim && ${pins.map((pin) => `${pin.binary} --version`).join(" && ")}`,
);

await step(
  "claude-managed-settings",
  `mkdir -p /etc/claude-code && echo '{ "cleanupPeriodDays": 99999 }' > /etc/claude-code/managed-settings.json && node -e 'JSON.parse(require("fs").readFileSync("/etc/claude-code/managed-settings.json","utf8"))'`,
);

await step(
  "devshell",
  `curl -fsSL https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz -o /tmp/ble.tar.xz && tar xJf /tmp/ble.tar.xz -C /tmp && rm -rf /usr/local/share/blesh && mv /tmp/ble-nightly /usr/local/share/blesh && rm -f /tmp/ble.tar.xz && test -f /usr/local/share/blesh/ble.sh && mkdir -p /etc/cmux /etc/skel && ${installFile("cmux-bashrc", "/etc/cmux/bashrc")} && bash -n /etc/cmux/bashrc && ${installFile("seed-history", "/etc/cmux/seed-history")} && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /etc/bash.bashrc && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /etc/skel/.bashrc && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /root/.bashrc && echo 'set -g default-shell /bin/bash' >> /etc/tmux.conf && bash -ic 'head -2 $HOME/.bash_history'`,
);

await step(
  "agent-config",
  `${installFile("agent-config.sh", "/etc/cmux/agent-config.sh")} && bash -n /etc/cmux/agent-config.sh && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' > /etc/profile.d/cmux-agents.sh && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /etc/bash.bashrc && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /etc/skel/.bashrc && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /root/.bashrc && mkdir -p /tmp/agent-config-check && env HOME=/tmp/agent-config-check OPENAI_BASE_URL=https://example.invalid/v1 OPENAI_API_KEY=crt_check CMUX_CODEROUTER_URL=https://example.invalid bash -lc 'true' && grep -q 'model_provider = "cmux"' /tmp/agent-config-check/.codex/config.toml && grep -q 'wire_api = "responses"' /tmp/agent-config-check/.codex/config.toml && grep -q "export OPENAI_API_KEY='crt_check'" /tmp/agent-config-check/.config/cmux/model-plane.env && [ "$(stat -c %a /tmp/agent-config-check/.config/cmux/model-plane.env)" = "600" ] && grep -qF '"x-coderouter-route-token": "$OPENAI_API_KEY"' /tmp/agent-config-check/.pi/agent/models.json && ! grep -q crt_check /tmp/agent-config-check/.pi/agent/models.json && test ! -e /tmp/agent-config-check/.config/opencode/opencode.json && rm -rf /tmp/agent-config-check && test ! -e /root/.codex/config.toml && test ! -e /root/.pi/agent/models.json && test ! -e /root/.config/opencode/opencode.json`,
);

// The cmux-tui daemon supervisor + its systemd unit. No binary is baked; the
// unit's supervisor loop waits for the driver-installed build (see the header).
const service = [
  "[Unit]",
  "Description=cmux-tui session daemon supervisor",
  "After=network.target",
  "",
  "[Service]",
  "Type=simple",
  "User=root",
  // Freestyle beta machines are reached at their stable public IPv6, so the
  // daemon listens dual-stack ([::] accepts IPv4 too). cmux-devbox-boot
  // defaults to 0.0.0.0 for the container providers, whose runtimes may have
  // IPv6 disabled entirely.
  "Environment=CMUX_TUI_REMOTE_WS_BIND=[::]:1337",
  "ExecStart=/usr/local/bin/cmux-devbox-boot",
  "Restart=always",
  "RestartSec=2",
  "",
  "[Install]",
  "WantedBy=multi-user.target",
].join("\n");
const serviceB64 = Buffer.from(service, "utf8").toString("base64");
await step(
  "cmux-tui-daemon-unit",
  `${installFile("cmux-devbox-boot", "/usr/local/bin/cmux-devbox-boot")} && chmod 0755 /usr/local/bin/cmux-devbox-boot && sh -n /usr/local/bin/cmux-devbox-boot && echo '${serviceB64}' | base64 -d > /etc/systemd/system/cmux-tui-daemon.service && mkdir -p /etc/systemd/system/multi-user.target.wants && ln -sf /etc/systemd/system/cmux-tui-daemon.service /etc/systemd/system/multi-user.target.wants/cmux-tui-daemon.service && systemctl daemon-reload && systemctl enable cmux-tui-daemon && systemctl restart cmux-tui-daemon && systemctl is-active cmux-tui-daemon`,
);

await step(
  "ghost-text-smoke",
  "tmux new-session -d -s ghost -x 100 -y 24 && sleep 2 && tmux send-keys -t ghost cl && sleep 2 && tmux capture-pane -pt ghost | grep -o 'claude --dangerously-skip-permissions' | head -1; rc=$?; tmux kill-session -t ghost 2>/dev/null; tmux kill-server 2>/dev/null; test $rc -eq 0",
);

await step("clean", "rm -rf /var/lib/apt/lists/* /root/.npm/_cacache 2>/dev/null; sync; true");

// Snapshot slugs are unique per account and creation does not reassign; on a
// collision fall back to a slugless snapshot (the sh-… id is the pointer).
const snap = await vm
  .snapshot({ slug, displayName: "cmux devbox (Dockerfile mirror)" })
  .catch(async (error: unknown) => {
    console.warn(`slug taken (${String(error).slice(0, 120)}); snapshotting without slug`);
    return vm.snapshot({ displayName: "cmux devbox (Dockerfile mirror)" });
  });
console.log("SNAPSHOT_RESULT", JSON.stringify(snap));
await vm.delete();
console.log("builder deleted");

const snapshotId = snap.snapshotId;
if (!snapshotId) {
  throw new Error("Freestyle snapshot response carried no snapshot id; do not pin this bake");
}

const metadata = bakeMetadata(preflight, fileURLToPath(import.meta.url));
console.log(
  JSON.stringify(
    {
      manifestEntry: manifestEntrySkeleton(
        "freestyle",
        `freestyle-${slug}`,
        snapshotId,
        "FREESTYLE_SANDBOX_SNAPSHOT",
        metadata,
        "Shared devbox exec-replay on the Freestyle BETA platform; cmux-tui transport; requires the beta-SDK driver (do not pin for the legacy driver).",
      ),
      next: `bun scripts/verify-devbox-image.ts freestyle ${snapshotId}`,
    },
    null,
    2,
  ),
);
