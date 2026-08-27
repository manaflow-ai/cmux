#!/usr/bin/env bun
/**
 * Post-bake verification for the cmux Cloud devbox images, run directly
 * against the provider SDKs. Boots ONE sandbox for the named provider,
 * asserts everything the devbox promises (pinned agents, mise toolchain,
 * devtools, Chrome + cua-driver, ble.sh ghost text under a real PTY, the
 * agent-config generator byte-identical to this checkout, and the
 * cmuxd-remote attach contract for that provider), then deletes it.
 *
 * Usage:
 *   E2B_API_KEY=...       bun scripts/verify-devbox-image.ts e2b <template>
 *   DAYTONA_API_KEY=...   bun scripts/verify-devbox-image.ts daytona <snapshot-name>
 *   FREESTYLE_API_KEY=... bun scripts/verify-devbox-image.ts freestyle <snapshot-id>
 *
 * Exit 0 means every check passed; record validationStatus "passed" in the
 * manifest entry then. Creates only its own sandboxes and deletes them in a
 * finally block.
 */
import { Daytona } from "@daytonaio/sdk";
import { Sandbox } from "e2b";
// The devbox freestyle bake targets the BETA platform (see
// build-devbox-freestyle.ts), so its snapshots are verified with the beta
// SDK too. The shipped freestyle driver still speaks the legacy platform.
import { Freestyle } from "freestyle-beta";
import path from "node:path";
import { devboxAgentPins, devboxDir, sha256File } from "./devbox-image-common";

const pins = devboxAgentPins();
const shaOf = (name: string): string => sha256File(path.join(devboxDir, name));

// Every file the image bakes from this checkout must ship byte-identical.
const FILE_PIN_CHECKS = [
  ["cmux-bashrc", "/etc/cmux/bashrc"],
  ["agent-config.sh", "/etc/cmux/agent-config.sh"],
  ["seed-history", "/etc/cmux/seed-history"],
  ["cmux-cloud-shell", "/usr/local/bin/cmux-cloud-shell"],
  ["cmux-zshrc", "/etc/cmux/zshrc"],
  ["chrome-managed-policy.json", "/etc/opt/chrome/policies/managed/cmux.json"],
].map(([source, target]) => `echo '${shaOf(source)}  ${target}' | sha256sum -c -`);

const CHECKS: readonly string[] = [
  // Pinned coding agents: exact installed versions, not just runnable.
  `ls=$(npm ls -g --depth=0) && ${pins
    .map((pin) => `echo "$ls" | grep -F ' ${pin.spec}'`)
    .join(" && ")} && echo agent-pins-ok`,
  ...pins.map((pin) => `${pin.binary} --version`),
  // Toolchain: mise shims first on PATH for exec shells too.
  "node --version; npm --version; python --version; python3 --version; bun --version; uv --version",
  "test \"$(command -v node)\" = /opt/mise/shims/node && mise --version && echo mise-shims-ok",
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
  "test -f /usr/local/share/blesh/ble.sh && grep -q '/etc/cmux/bashrc' /etc/bash.bashrc && grep -q '/etc/cmux/bashrc' /etc/skel/.bashrc && echo bashrc-chain-ok",
  "grep default-shell /etc/tmux.conf",
  "bash -ic 'head -2 ~/.bash_history'",
  // Ghost-text smoke under a real PTY: type "cl" and expect ble.sh to render
  // the seeded claude command as the history suggestion.
  "tmux new-session -d -s ghost -x 100 -y 24 && sleep 2 && tmux send-keys -t ghost cl && sleep 2 && tmux capture-pane -pt ghost | grep -o 'claude --dangerously-skip-permissions' | head -1; rc=$?; tmux kill-session -t ghost 2>/dev/null; exit $rc",
  // Quiet-marks smoke: the bashrc blanks ble.sh's status marks and pins USER
  // so no [ble: ...] or "insane environment" text ever renders.
  "tmux new-session -d -s marks -x 100 -y 24 && sleep 3 && tmux send-keys -t marks not-a-command Enter && sleep 2 && tmux send-keys -t marks 'printf no-newline' Enter && sleep 2 && out=$(tmux capture-pane -pt marks); tmux kill-session -t marks 2>/dev/null; printf '%s\\n' \"$out\" | grep -E '\\[ble:|ble\\.sh:' && exit 1; echo no-ble-marks",
  // Agent-config generator: a login shell under a throwaway HOME with fake
  // model-plane env materializes the codex custom provider and persists the
  // env 0600; the image ships no pre-generated config for root.
  "rm -rf /tmp/cmux-agent-config-verify && env HOME=/tmp/cmux-agent-config-verify OPENAI_BASE_URL=https://example.invalid/v1 OPENAI_API_KEY=crt_check CMUX_CODEROUTER_URL=https://example.invalid bash -lc 'true' && grep -q 'model_provider = \"cmux\"' /tmp/cmux-agent-config-verify/.codex/config.toml && grep -q 'wire_api = \"responses\"' /tmp/cmux-agent-config-verify/.codex/config.toml && grep -q \"export OPENAI_API_KEY='crt_check'\" /tmp/cmux-agent-config-verify/.config/cmux/model-plane.env && [ \"$(stat -c %a /tmp/cmux-agent-config-verify/.config/cmux/model-plane.env)\" = \"600\" ] && rm -rf /tmp/cmux-agent-config-verify && test ! -e /root/.codex/config.toml && echo agent-config-ok",
  "grep -q cleanupPeriodDays /etc/claude-code/managed-settings.json && echo claude-retention-ok",
  // Attach control plane binaries.
  "test -x /usr/local/bin/cmuxd-remote && /usr/local/bin/cmuxd-remote version",
  "test \"$(readlink /usr/local/bin/cmux)\" = /usr/local/bin/cmuxd-remote && echo cmux-symlink-ok",
  "test -x /usr/local/bin/cmux-cloud-shell && sh -n /usr/local/bin/cmux-cloud-shell && echo cloud-shell-ok",
  "id -u cmux >/dev/null && sudo -l -U cmux | grep -q NOPASSWD && echo cmux-user-ok",
  "whoami; nproc; free -m | sed -n 2p; df -h / | tail -1",
];

// The daemon must already be serving on providers whose boot path starts it
// (E2B start command, Daytona entrypoint). The driver only installs leases.
const DAEMON_LIVE_CHECKS: readonly string[] = [
  "pgrep -f 'cmuxd-remote serve' >/dev/null && echo daemon-running",
  "ps auxww | grep cmuxd-remote | grep -v grep | grep -q -- '--shell /usr/local/bin/cmux-cloud-shell' && echo daemon-shell-ok",
  "curl -sf http://127.0.0.1:7777/healthz >/dev/null && echo daemon-healthz-ok",
];

// Freestyle: the beta bake always bakes the cmuxd-ws unit (beta creates
// cannot inject systemd services), so the daemon must be live. The
// managed-shell probe assets are required too (a miss makes the legacy
// driver clobber cmux-cloud-shell on VMs it manages).
const FREESTYLE_CHECKS: readonly string[] = [
  "command -v zsh && test -r /etc/cmux/zshrc && test -r /home/cmux/.zshrc && echo freestyle-shell-probe-ok",
  "grep -q -- '--shell /usr/local/bin/cmux-cloud-shell' /etc/systemd/system/cmuxd-ws.service && echo baked-unit-ok",
  ...DAEMON_LIVE_CHECKS,
];

type Exec = (cmd: string) => Promise<{ exitCode: number; output: string }>;

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

const provider = process.argv[2] ?? "";
const image = process.argv[3] ?? "";
if (!image) {
  throw new Error("usage: bun scripts/verify-devbox-image.ts <e2b|daytona|freestyle> <image>");
}
let pass = false;

if (provider === "e2b") {
  console.log(`===== e2b (template ${image}) =====`);
  const t0 = Date.now();
  const sbx = await Sandbox.create(image, { timeoutMs: 300_000 });
  console.log(`provisioned ${sbx.sandboxId} in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  try {
    pass = await runChecks("e2b", [...CHECKS, ...DAEMON_LIVE_CHECKS], async (cmd) => {
      const r = await sbx.commands.run(cmd, { timeoutMs: 120_000 }).catch((e: unknown) => {
        // e2b throws CommandExitError on nonzero exit; unwrap it.
        if (e && typeof e === "object" && "exitCode" in e) return e as never;
        throw e;
      });
      return { exitCode: r.exitCode, output: `${r.stdout}${r.stderr}` };
    });
  } finally {
    await sbx.kill();
    console.log(`killed ${sbx.sandboxId}`);
  }
} else if (provider === "daytona") {
  console.log(`===== daytona (snapshot ${image}) =====`);
  const daytona = new Daytona({
    apiKey: process.env.DAYTONA_API_KEY,
    apiUrl: process.env.DAYTONA_API_URL,
  });
  const t0 = Date.now();
  const sandbox = await daytona.create({ snapshot: image });
  console.log(`provisioned ${sandbox.id} in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  try {
    pass = await runChecks("daytona", [...CHECKS, ...DAEMON_LIVE_CHECKS], async (cmd) => {
      try {
        const r = await sandbox.process.executeCommand(cmd, undefined, undefined, 120);
        // The Daytona toolbox merges stderr into `result`.
        return { exitCode: r.exitCode, output: r.result ?? "" };
      } catch (error) {
        return { exitCode: 124, output: String(error).slice(0, 500) };
      }
    });
  } finally {
    await daytona.delete(sandbox);
    console.log(`deleted ${sandbox.id}`);
  }
} else if (provider === "freestyle") {
  console.log(`===== freestyle (snapshot ${image}, beta platform) =====`);
  const apiKey = process.env.FREESTYLE_API_KEY;
  const stackToken = process.env.FREESTYLE_STACK_ACCESS_TOKEN;
  const teamId = process.env.FREESTYLE_TEAM_ID;
  const fs = apiKey
    ? new Freestyle({ apiKey })
    : stackToken && teamId
      ? new Freestyle({ stackAccessToken: stackToken, teamId })
      : (() => {
          throw new Error("set FREESTYLE_API_KEY, or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID");
        })();
  const t0 = Date.now();
  const { vm, vmId } = await fs.vms.create({
    snapshotId: image,
    displayName: "cmux-devbox-verify",
    // Beta creates require an explicit firewall; the checks are local-only,
    // but outbound stays open so a debugging session inside the VM works.
    firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] },
  });
  console.log(`provisioned ${vmId} in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  try {
    pass = await runChecks("freestyle", [...CHECKS, ...FREESTYLE_CHECKS], async (cmd) => {
      // Login bash for the mise shims; Freestyle guest exec has an empty HOME.
      const wrapped = `bash -lc 'export HOME="$\{HOME:-$(getent passwd $(id -u) | cut -d: -f6)\}"; export PATH="/opt/mise/shims:$\{PATH\}"; ${cmd.replace(/'/g, `'\\''`)}'`;
      const r = await vm.exec({ command: wrapped, timeoutMs: 120_000 });
      return {
        exitCode: (r as { statusCode?: number }).statusCode ?? 124,
        output: `${r.stdout ?? ""}${r.stderr ?? ""}`,
      };
    });
  } finally {
    await vm.delete();
    console.log(`deleted ${vmId}`);
  }
} else {
  throw new Error("usage: bun scripts/verify-devbox-image.ts <e2b|daytona|freestyle> <image>");
}

if (!pass) process.exit(1);
