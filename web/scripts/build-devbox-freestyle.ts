#!/usr/bin/env bun
/**
 * Build the cmux Cloud devbox Freestyle snapshot by replaying
 * web/services/vms/images/devbox/Dockerfile as exec steps on a builder VM
 * (Freestyle's exec API has no COPY; small repo files travel as base64
 * embeds, cmuxd-remote via a download URL).
 *
 * Usage:
 *   FREESTYLE_API_KEY=... bun scripts/build-devbox-freestyle.ts <snapshot-name>
 *
 * The daemon binary needs a URL the builder can curl: set
 * CMUX_REMOTE_DAEMON_BUILD_URL, or provide R2_* env for an upload + presign
 * (same contract as build-cloud-vm-images.ts).
 *
 * Driver contract (web/services/vms/drivers/freestyle.ts): the driver
 * installs the cmuxd-ws systemd unit at create time (admin token) unless the
 * image bakes the signed-admin unit, so the image must ship
 * /usr/local/bin/cmuxd-remote and /usr/local/bin/cmux-cloud-shell. When
 * CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY is set, the signed-admin unit is
 * baked and the manifest entry must carry features.bakedFreestyleSignedAdmin.
 * The driver's managed-shell probe additionally requires the cmux user, zsh,
 * /etc/cmux/zshrc, and /home/cmux/.zshrc, all baked below; without them the
 * driver "repairs" the VM by overwriting cmux-cloud-shell with its fallback
 * zsh shell, clobbering the devbox bash devshell.
 *
 * Freestyle snapshot names are labels; the immutable id is the printed
 * snapshotId, which is what FREESTYLE_SANDBOX_SNAPSHOT pins. Use a fresh
 * versioned name per rebuild anyway so bake logs stay unambiguous.
 */
import { Freestyle } from "freestyle";
import { fileURLToPath } from "node:url";
import {
  DEVBOX_SERVE_COMMAND,
  bakeMetadata,
  bakePreflight,
  buildRemoteDaemon,
  devboxAgentPins,
  fileBase64,
  manifestEntrySkeleton,
  remoteDaemonBuildURL,
} from "./devbox-image-common";

if (!process.env.FREESTYLE_API_KEY) {
  throw new Error("FREESTYLE_API_KEY is required to build the Freestyle devbox snapshot");
}

const name = process.argv[2];
if (!name || name.startsWith("--")) {
  throw new Error("usage: bun scripts/build-devbox-freestyle.ts <snapshot-name>");
}

const preflight = bakePreflight();
const daemon = await buildRemoteDaemon();
const daemonURL = await remoteDaemonBuildURL(name);
const signedAdminPublicKey = process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY?.trim() ?? "";
if (signedAdminPublicKey) {
  const decoded = Buffer.from(signedAdminPublicKey.replace(/-/g, "+").replace(/_/g, "/"), "base64");
  if (decoded.length !== 32) {
    throw new Error("CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY must decode to 32 bytes");
  }
}

const STEP_TIMEOUT_MS = 10 * 60 * 1000;
const fs = new Freestyle({
  fetch: (input, init) =>
    fetch(input as Request, { ...(init ?? {}), signal: AbortSignal.timeout(STEP_TIMEOUT_MS + 30_000) }),
});

const builderSnapshot = process.env.CMUX_FREESTYLE_BUILDER_SNAPSHOT?.trim() || "freestyle/ubuntu-sm";
const { vm, vmId } = await fs.vms.create({ snapshotId: builderSnapshot });
console.log(`builder VM ${vmId} (base ${builderSnapshot})`);

// Freestyle guest exec starts with an empty HOME and does not source
// profile.d, so every step carries the toolchain env inline (mirrors the
// Dockerfile's ENV block, PATH literal included).
const PREFIX = [
  'export HOME="${HOME:-$(getent passwd $(id -u) | cut -d: -f6)}"',
  "export MISE_DATA_DIR=/opt/mise",
  "export MISE_CACHE_DIR=/opt/mise/cache",
  "export MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml",
  "export PATH=/opt/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
  "export DEBIAN_FRONTEND=noninteractive",
  "export LANG=C.UTF-8",
].join(" && ");

async function step(label: string, command: string): Promise<void> {
  const t0 = Date.now();
  const r = await vm.exec({ command: `${PREFIX} && ${command}`, timeoutMs: STEP_TIMEOUT_MS });
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  const exitCode = (r as { statusCode?: number }).statusCode ?? 0;
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
  "apt-get update -q && apt-get install -y --no-install-recommends git ripgrep build-essential curl ca-certificates unzip zip xz-utils zstd procps openssh-client pkg-config jq fd-find fzf sqlite3 tmux less rsync file tree nano vim sudo zsh zsh-autosuggestions && rm -rf /var/lib/apt/lists/* && ln -sf $(command -v fdfind) /usr/local/bin/fd && echo 'LANG=C.UTF-8' > /etc/default/locale && fd --version && jq --version && fzf --version && sqlite3 --version && tmux -V",
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
  "cmux-user",
  `id -u cmux >/dev/null 2>&1 || useradd -m -s /bin/bash cmux; echo 'cmux ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-cmux-nopasswd && chmod 0440 /etc/sudoers.d/90-cmux-nopasswd && mkdir -p /etc/cmux /etc/skel && ${installFile("cmux-zshrc", "/etc/cmux/zshrc")} && zsh -n /etc/cmux/zshrc && echo '[ -r /etc/cmux/zshrc ] && source /etc/cmux/zshrc' > /home/cmux/.zshrc && echo '[ -r "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"' >> /home/cmux/.zshrc && chown cmux:cmux /home/cmux/.zshrc`,
);

await step(
  "devshell",
  `curl -fsSL https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz -o /tmp/ble.tar.xz && tar xJf /tmp/ble.tar.xz -C /tmp && rm -rf /usr/local/share/blesh && mv /tmp/ble-nightly /usr/local/share/blesh && rm -f /tmp/ble.tar.xz && test -f /usr/local/share/blesh/ble.sh && ${installFile("cmux-bashrc", "/etc/cmux/bashrc")} && bash -n /etc/cmux/bashrc && ${installFile("seed-history", "/etc/cmux/seed-history")} && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /etc/bash.bashrc && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /etc/skel/.bashrc && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /root/.bashrc && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /home/cmux/.bashrc && chown cmux:cmux /home/cmux/.bashrc && echo 'set -g default-shell /bin/bash' >> /etc/tmux.conf && bash -ic 'head -2 $HOME/.bash_history'`,
);

await step(
  "agent-config",
  `${installFile("agent-config.sh", "/etc/cmux/agent-config.sh")} && bash -n /etc/cmux/agent-config.sh && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' > /etc/profile.d/cmux-agents.sh && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /etc/bash.bashrc && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /etc/skel/.bashrc && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /root/.bashrc && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /home/cmux/.bashrc && mkdir -p /tmp/agent-config-check && env HOME=/tmp/agent-config-check OPENAI_BASE_URL=https://example.invalid/v1 OPENAI_API_KEY=crt_check CMUX_CODEROUTER_URL=https://example.invalid bash -lc 'true' && grep -q 'model_provider = "cmux"' /tmp/agent-config-check/.codex/config.toml && grep -q 'wire_api = "responses"' /tmp/agent-config-check/.codex/config.toml && grep -q "export OPENAI_API_KEY='crt_check'" /tmp/agent-config-check/.config/cmux/model-plane.env && [ "$(stat -c %a /tmp/agent-config-check/.config/cmux/model-plane.env)" = "600" ] && rm -rf /tmp/agent-config-check && test ! -e /root/.codex/config.toml`,
);

await step(
  "cmuxd-remote",
  `curl -fsSL '${daemonURL.replace(/'/g, `'\\''`)}' -o /usr/local/bin/cmuxd-remote && chmod 0755 /usr/local/bin/cmuxd-remote && /usr/local/bin/cmuxd-remote version && ${installFile("cmux-cloud-shell", "/usr/local/bin/cmux-cloud-shell")} && chmod 0755 /usr/local/bin/cmux-cloud-shell && sh -n /usr/local/bin/cmux-cloud-shell && ln -sf /usr/local/bin/cmuxd-remote /usr/local/bin/cmux && mkdir -p /tmp/cmux && chmod 700 /tmp/cmux`,
);

if (signedAdminPublicKey) {
  const service = [
    "[Unit]",
    "Description=cmux remote WebSocket daemon",
    "After=network.target",
    "",
    "[Service]",
    "Type=simple",
    "User=root",
    `Environment=CMUXD_WS_ADMIN_ED25519_PUBLIC_KEY=${signedAdminPublicKey}`,
    `ExecStart=${DEVBOX_SERVE_COMMAND}`,
    "Restart=always",
    "RestartSec=2",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
  ].join("\n");
  const serviceB64 = Buffer.from(service, "utf8").toString("base64");
  await step(
    "signed-admin-service",
    `echo '${serviceB64}' | base64 -d > /etc/systemd/system/cmuxd-ws.service && mkdir -p /etc/systemd/system/multi-user.target.wants && ln -sf /etc/systemd/system/cmuxd-ws.service /etc/systemd/system/multi-user.target.wants/cmuxd-ws.service && systemctl daemon-reload && systemctl enable cmuxd-ws && systemctl restart cmuxd-ws && sleep 2 && curl -sf http://127.0.0.1:7777/healthz`,
  );
}

await step(
  "ghost-text-smoke",
  "tmux new-session -d -s ghost -x 100 -y 24 && sleep 2 && tmux send-keys -t ghost cl && sleep 2 && tmux capture-pane -pt ghost | grep -o 'claude --dangerously-skip-permissions' | head -1; rc=$?; tmux kill-session -t ghost 2>/dev/null; tmux kill-server 2>/dev/null; test $rc -eq 0",
);

await step("clean", "rm -rf /var/lib/apt/lists/* /root/.npm/_cacache 2>/dev/null; sync; true");

const snap = await vm.snapshot({ name });
const snapshotId =
  (snap as { snapshotId?: string }).snapshotId ?? (snap as { id?: string }).id ?? "";
console.log("SNAPSHOT_RESULT", JSON.stringify(snap));
await vm.delete();
console.log("builder deleted");

if (!snapshotId) {
  throw new Error("Freestyle snapshot response carried no snapshot id; do not pin this bake");
}

const metadata = bakeMetadata(preflight, daemon, fileURLToPath(import.meta.url));
const manifestEntry = {
  ...manifestEntrySkeleton(
    "freestyle",
    `freestyle-${name}`,
    snapshotId,
    "FREESTYLE_SANDBOX_SNAPSHOT",
    metadata,
    "Shared devbox exec-replay of services/vms/images/devbox/Dockerfile.",
  ),
  ...(signedAdminPublicKey ? { features: { bakedFreestyleSignedAdmin: true } } : {}),
};
console.log(
  JSON.stringify(
    {
      manifestEntry,
      next: `bun scripts/verify-devbox-image.ts freestyle ${snapshotId}`,
    },
    null,
    2,
  ),
);
