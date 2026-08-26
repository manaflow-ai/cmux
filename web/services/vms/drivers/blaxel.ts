import { constants as zlibConstants, gzip } from "node:zlib";
import { promisify } from "node:util";

const gzipAsync = promisify(gzip);
import { readFile } from "node:fs/promises";
import { createHash, randomBytes } from "node:crypto";
import {
  NotImplementedError,
  ProviderError,
  type AttachEndpoint,
  type AttachOptions,
  type CreateOptions,
  type ExecResult,
  type SSHEndpoint,
  type WebSocketPtyEndpoint,
  type SnapshotRef,
  type VMHandle,
  type VMProvider,
  type VMStats,
  type VMStatus,
} from "./types";
import { withVmSpan } from "../telemetry";
import {
  isReusableRpcLease,
  ensurePrivateDirectoryCommand,
  leaseClientMetadata,
  makeWebSocketAttachmentId,
  makeWebSocketLease,
  shellQuote,
  type ReusableRpcLease,
} from "./wsLease";

// Blaxel sandboxes are name-addressed micro-VMs reached over HTTPS only: a per-sandbox
// "sandbox API" (process exec + filesystem) on the control side, and per-port preview URLs
// (`https://<id>.<region>.preview.bl.run` + `X-Blaxel-Preview-Token` header) for ingress.
// There is no raw TCP, so like E2B/Daytona the attach path is cmuxd-remote WebSocket PTY only
// and `openSSH` throws.
//
// Unlike the other drivers this one does not need a pre-baked provider image: `create`
// bootstraps a stock Blaxel image by injecting the cmuxd-remote linux binary through the
// sandbox filesystem API (gzip+base64, ~3 MB, sub-second) and starting `serve --ws` as a
// keepAlive process. keepAlive matters: Blaxel freezes a sandbox ~15 s after the last open
// connection otherwise, which would pause user workloads the moment the client disconnects.
// Standby time is free on Blaxel, so the cost lever ("smart sleep" while every PTY sits at
// an idle prompt) is a later optimization on top of the same bootstrap.
const CMUXD_WS_PORT = 7777;
// 8080 is the Blaxel sandbox-api (control channel); never expose it through a preview.
const CMUX_SANDBOX_API_PORT = 8080;
const CMUXD_WS_PTY_LEASE_PATH = "/tmp/cmux/attach-pty-lease.json";
const CMUXD_WS_RPC_LEASE_PATH = "/tmp/cmux/attach-rpc-lease.json";
const CMUXD_WS_RPC_CLIENT_PATH = "/tmp/cmux/attach-rpc-client.json";
const CMUXD_WS_PTY_LEASE_TTL_SECONDS = 5 * 60;
const CMUXD_WS_RPC_LEASE_TTL_SECONDS = 12 * 60 * 60;
const CMUXD_WS_RPC_RENEW_BEFORE_SECONDS = 60;
const CMUXD_BINARY_PATH = "/usr/local/bin/cmuxd-remote";
const CMUXD_PROCESS_NAME = "cmuxd-ws";
const SMART_SLEEP_PATH = "/usr/local/bin/cmux-smart-sleep";
const SMART_SLEEP_PROCESS_NAME = "cmux-keepalive";
// Blaxel keeps a sandbox awake while any keepAlive process runs and freezes it ~15 s after the
// last connection otherwise. The watcher is that keepAlive process: it stays alive while any
// PTY shell has a foreground/background job (cmuxd child with descendants) or any client is
// connected to :7777, and exits after a sustained idle grace so the sandbox drops to standby
// ($0, memory snapshot, ~25 ms wake). Every attach re-arms it, so "wake" is just reconnecting.
const SMART_SLEEP_SCRIPT = `#!/bin/sh
# cmux smart sleep: hold the sandbox awake while work is running or a client is attached.
PORT_HEX=1E61 # 7777
IDLE_LIMIT=\${CMUX_SMART_SLEEP_IDLE_CHECKS:-8}
INTERVAL=\${CMUX_SMART_SLEEP_INTERVAL:-15}
idle=0
while true; do
  busy=""
  cm=$(pidof cmuxd-remote 2>/dev/null | awk '{print $1}')
  if [ -n "$cm" ]; then
    for c in $(pgrep -P "$cm" 2>/dev/null); do
      if pgrep -P "$c" >/dev/null 2>&1; then busy=jobs; break; fi
    done
  fi
  if [ -z "$busy" ]; then
    if awk -v port="$PORT_HEX" '$2 ~ ":"port"$" && $4 == "01" { found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
      busy=conn
    fi
  fi
  if [ -n "$busy" ]; then
    idle=0
  else
    idle=$((idle + 1))
    if [ "$idle" -ge "$IDLE_LIMIT" ]; then
      echo "smart-sleep: idle for $((idle * INTERVAL))s, releasing keepAlive"
      exit 0
    fi
  fi
  sleep "$INTERVAL"
done
`;
// Background provisioning for every machine: coding agents plus the dev essentials a person
// expects on "their computer". The .bashrc seed only writes when absent so user edits stick.
const CMUX_PROVISION_COMMAND = [
  "{ command -v apk >/dev/null 2>&1 && apk add --no-cache curl tmux vim ripgrep jq openssh-client;",
  "command -v npm >/dev/null 2>&1 && npm install -g @anthropic-ai/claude-code @openai/codex;",
  "[ -f /root/.bashrc ] || printf '%s\\n' \"export PS1='\\\\[\\\\e[1;36m\\\\]\\\\h\\\\[\\\\e[0m\\\\]:\\\\[\\\\e[1;34m\\\\]\\\\w\\\\[\\\\e[0m\\\\]# '\" \"alias ll='ls -la'\" > /root/.bashrc;",
  "} >/tmp/cmux/provision.log 2>&1 || true",
].join(" ");

// The machine knows its own name: the prompt reads noble-wren:~#, not (none):~#. But a
// renamed host must stay *resolvable*: TigerVNC's `vncserver` wrapper calls `hostname -f`
// and aborts the whole desktop session when the name has no /etc/hosts entry. A bare
// `hostname <name>` (all we used to do) silently broke noVNC on every desktop machine —
// 5901 never bound and the browser showed "Failed to connect to server". Map the name to
// loopback so `hostname -f` resolves. Idempotent: re-runs harmlessly on resurrection.
export function hostnameSetupCommand(name: string): string {
  const q = shellQuote(name);
  return (
    `hostname ${q} 2>/dev/null; echo ${q} > /etc/hostname || true; ` +
    `grep -qF ${q} /etc/hosts || printf '127.0.0.1 %s\\n127.0.1.1 %s\\n' ${q} ${q} >> /etc/hosts`
  );
}

// Desktop images (blaxel/xfce-vnc) start TigerVNC via supervisord at boot — before this
// driver's bootstrap makes the hostname resolvable — so that first attempt fails and
// supervisord exhausts its retries and gives up (FATAL). Once hostnameSetupCommand has
// fixed /etc/hosts nothing kicks vncserver again, so we start it ourselves, as the image's
// `cua` desktop user, when 5901 is not already listening (a snapshot-resumed machine keeps
// its running Xtigervnc, so we skip). A no-op on base images, which have no start-vnc.sh.
const DESKTOP_VNC_HEAL_PROCESS_NAME = "cmux-vnc-heal";
export const DESKTOP_VNC_HEAL_COMMAND = [
  "[ -x /usr/local/bin/start-vnc.sh ] || exit 0;",
  "for i in 1 2 3 4 5; do { ss -tln 2>/dev/null || netstat -tln 2>/dev/null; } | grep -q ':5901 ' && exit 0; sleep 1; done;",
  "exec runuser -u cua -- env HOME=/home/cua USER=cua DISPLAY=:1 bash /usr/local/bin/start-vnc.sh",
].join(" ");

const CMUXD_PREVIEW_NAME = "cmuxd";
const PREVIEW_TOKEN_TTL_SECONDS = 12 * 60 * 60;
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
const MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000;
const HEALTH_RETRY_ATTEMPTS = 12;
const HEALTH_RETRY_INTERVAL_MS = 1_000;
const CONTROL_PLANE_BASE = "https://api.blaxel.ai/v0";
const DEFAULT_MEMORY_MB = 4096;
// The persistent-home volume mounts over root's home so dotfiles, repos, and agent state
// survive sandbox destruction. The sandbox is disposable compute; the volume is the machine.
const HOME_VOLUME_MOUNT_PATH = "/root";
const DEFAULT_HOME_VOLUME_MB = 5120;

type BlaxelSandbox = {
  metadata?: { name?: string; url?: string; createdAt?: string };
  spec?: { runtime?: { image?: string; memory?: number } };
  state?: string;
  status?: string;
};

type BlaxelProcess = {
  pid?: string;
  name?: string;
  status?: string;
  exitCode?: number;
  stdout?: string;
  stderr?: string;
  logs?: string;
};

type BlaxelPreview = {
  metadata?: { name?: string };
  spec?: {
    url?: string;
    public?: boolean;
    prefixUrl?: string;
    customDomain?: string;
  };
};

// The preview URL is the only ingress to cmuxd, and it must stay token-gated: a preview that
// is (or has been flipped) public would expose the daemon's WebSocket endpoints to anyone
// holding the URL, leaving the lease token as the sole barrier. Only a private preview's URL
// is ever usable; a public one is treated as absent so callers replace or reject it.
export function usablePrivatePreviewUrl(preview: BlaxelPreview | null | undefined): string | null {
  const url = preview?.spec?.url;
  if (!url) return null;
  if (preview?.spec?.public === true) return null;
  return url;
}

function env(name: string): string | undefined {
  return process.env[name]?.trim() || undefined;
}

function requireEnv(name: string): string {
  const value = env(name);
  if (!value) {
    throw new ProviderError("blaxel", `${name} is not configured`);
  }
  return value;
}

// Step-level latency attribution for the create path. The workflow recorder only
// shows provider_create as one block, so CMUX_VM_DEBUG_TIMINGS=1 additionally logs
// one line per driver step (volume, sandbox create, daemon upload, preview) — slow
// creates get measured, not guessed at.
async function timedStep<T>(step: string, run: () => Promise<T>): Promise<T> {
  if (env("CMUX_VM_DEBUG_TIMINGS") !== "1") return run();
  const start = performance.now();
  try {
    return await run();
  } finally {
    console.info(`[blaxel] timing step=${step} ms=${Math.round(performance.now() - start)}`);
  }
}

function controlHeaders(): Record<string, string> {
  return {
    "X-Blaxel-Authorization": `Bearer ${requireEnv("BL_API_KEY")}`,
    "X-Blaxel-Workspace": requireEnv("BL_WORKSPACE"),
    "Content-Type": "application/json",
  };
}

async function blaxelFetch<T>(
  method: string,
  url: string,
  body?: unknown,
  opts?: { timeoutMs?: number },
): Promise<T> {
  const response = await fetch(url, {
    method,
    headers: controlHeaders(),
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(opts?.timeoutMs ?? 60_000),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new ProviderError("blaxel", `${method} ${url} -> ${response.status}: ${text.slice(0, 500)}`);
  }
  return (text ? JSON.parse(text) : undefined) as T;
}

// The cmuxd-remote linux/amd64 binary this driver injects at create time. Local dev points
// CMUX_VM_BLAXEL_DAEMON_PATH at a `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build` output;
// deployed runtimes point CMUX_VM_BLAXEL_DAEMON_URL at the R2 build artifact. Cached as the
// in-flight promise of the gzipped base64 payload the filesystem API write wants, so
// concurrent creates share one read+encode and repeated creates don't refetch. A failed
// load clears the cache so the next create retries instead of replaying the rejection.
let cachedDaemonB64: Promise<string> | null = null;

export type BlaxelDaemonSource =
  | { kind: "path"; path: string; sha256?: string }
  | { kind: "url"; url: string; sha256: string };

// The injected daemon runs with root-equivalent access in every sandbox users pipe their
// credentials and agent sessions through, so a remote fetch must be integrity-pinned: a URL
// source without CMUX_VM_BLAXEL_DAEMON_SHA256 fails closed before any bytes are fetched.
// A local path is a developer's own build and may run unpinned; the pin is honored there too
// when set.
export function resolveDaemonSource(): BlaxelDaemonSource {
  const sha256 = env("CMUX_VM_BLAXEL_DAEMON_SHA256")?.toLowerCase();
  if (sha256 && !/^[0-9a-f]{64}$/.test(sha256)) {
    throw new ProviderError(
      "blaxel",
      "CMUX_VM_BLAXEL_DAEMON_SHA256 must be 64 hex characters (sha256 of the raw cmuxd-remote binary)",
    );
  }
  const localPath = env("CMUX_VM_BLAXEL_DAEMON_PATH");
  if (localPath) {
    return { kind: "path", path: localPath, sha256 };
  }
  const url = env("CMUX_VM_BLAXEL_DAEMON_URL");
  if (!url) {
    throw new ProviderError(
      "blaxel",
      "set CMUX_VM_BLAXEL_DAEMON_PATH (local cmuxd-remote linux/amd64 build) or CMUX_VM_BLAXEL_DAEMON_URL",
    );
  }
  if (!sha256) {
    throw new ProviderError(
      "blaxel",
      "CMUX_VM_BLAXEL_DAEMON_URL requires CMUX_VM_BLAXEL_DAEMON_SHA256; the downloaded daemon runs in every sandbox, so the fetch must be integrity-pinned",
    );
  }
  return { kind: "url", url, sha256 };
}

export function verifyDaemonDigest(binary: Buffer, expectedSha256: string): void {
  const actual = createHash("sha256").update(binary).digest("hex");
  if (actual !== expectedSha256) {
    throw new ProviderError(
      "blaxel",
      `cmuxd-remote binary sha256 mismatch: expected ${expectedSha256}, got ${actual}; refusing to inject it into sandboxes`,
    );
  }
}

function daemonBinaryBase64Gzip(): Promise<string> {
  if (cachedDaemonB64) return cachedDaemonB64;
  const load = (async () => {
    const source = resolveDaemonSource();
    let binary: Buffer;
    if (source.kind === "path") {
      binary = await readFile(source.path);
    } else {
      const response = await fetch(source.url, { signal: AbortSignal.timeout(120_000) });
      if (!response.ok) {
        throw new ProviderError("blaxel", `daemon download ${source.url} -> ${response.status}`);
      }
      binary = Buffer.from(await response.arrayBuffer());
    }
    if (source.sha256) {
      verifyDaemonDigest(binary, source.sha256);
    }
    // Compression level is create latency, not egress savings: on a ~10.7MB Go
    // binary, level 9 measured 32s for 5.86MB vs level 1's 2.6s for 6.20MB — 29s
    // of every cold create to save 0.3MB (<1s of upload). Best-speed, and async
    // so the encode does not stall every other request on the event loop.
    return (await gzipAsync(binary, { level: zlibConstants.Z_BEST_SPEED })).toString("base64");
  })();
  cachedDaemonB64 = load.catch((err) => {
    cachedDaemonB64 = null;
    throw err;
  });
  return cachedDaemonB64;
}

// Warm the payload cache at module init so the first create after a boot does not
// pay the read+encode on its critical path. A missing daemon config just leaves the
// cache empty here; create() surfaces the real configuration error to the caller.
void daemonBinaryBase64Gzip().catch(() => undefined);

export class BlaxelProvider implements VMProvider {
  readonly id = "blaxel" as const;

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image.trim();
    if (!image) {
      throw new ProviderError("blaxel", "create requires a resolved image");
    }
    return withVmSpan(
      "cmux.vm.provider.create",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "create", "cmux.vm.image": image },
      async (span) => {
        try {
          const memoryMb = resolveMemoryMb(options.memoryMb);
          // A `{machine}` token in homeVolume is resolved against the generated
          // machine name, giving every fresh machine its own durable home. The
          // resolved name (never the template) is what lands in providerMetadata,
          // so resurrection finds the right volume.
          const homeVolumeSpec = options.homeVolume?.trim() || undefined;
          const resolveHomeVolume = (machineName: string): string | undefined =>
            homeVolumeSpec?.replace("{machine}", machineName);
          let name = friendlyVmName();
          let homeVolume = resolveHomeVolume(name);
          let created: BlaxelSandbox | null = null;
          for (let attempt = 0; attempt < 4 && !created; attempt += 1) {
            if (homeVolume) {
              const volume = homeVolume;
              await timedStep("ensure_home_volume", () => this.ensureHomeVolume(volume));
            }
            try {
              created = await timedStep("create_sandbox", () => blaxelFetch<BlaxelSandbox>("POST", `${CONTROL_PLANE_BASE}/sandboxes`, {
                metadata: { name },
                spec: {
                  runtime: {
                    image,
                    memory: memoryMb,
                    envs: [{ name: "LANG", value: "C.UTF-8" }],
                    ports: [{ name: CMUXD_PREVIEW_NAME, protocol: "HTTP", target: CMUXD_WS_PORT }],
                  },
                  ...(homeVolume ? { volumes: [{ name: homeVolume, mountPath: HOME_VOLUME_MOUNT_PATH }] } : {}),
                },
              }));
            } catch (err) {
              const conflict = err instanceof ProviderError && /-> 409/.test(err.message);
              if (!conflict || attempt === 3) throw err;
              name = friendlyVmName(attempt >= 1);
              homeVolume = resolveHomeVolume(name);
            }
          }
          const sandboxUrl = created?.metadata?.url;
          if (!sandboxUrl) {
            throw new Error("create response is missing metadata.url for the sandbox API");
          }
          // The daemon preview is minted through the same branded path attach uses, so a
          // machine is born at https://<name>.vm.cmux.sh (or <name>-cmux.preview.bl.run)
          // rather than an opaque hash it would then keep for life. The preview lives on
          // the control plane and only needs the sandbox to exist, so it is created in
          // parallel with the in-sandbox daemon bootstrap.
          // Both branches settle before any rollback (allSettled, not all): a
          // fast-failing bootstrap must not start deleting the sandbox while the
          // preview POST is still in flight, or the late preview recreates the
          // orphaned branded route the rollback exists to remove.
          const [bootstrapResult, previewResult] = await Promise.allSettled([
            timedStep("bootstrap_daemon", () => this.bootstrapDaemon(name, sandboxUrl)),
            timedStep("ensure_preview", () => this.ensurePreview(name)),
          ]);
          // A machine that failed to bootstrap must not survive as an orphaned
          // sandbox (its previews die with it); the durable home volume is kept —
          // a retried create with the same volume reattaches it.
          // A rollback failure means the sandbox is now leaked on the provider:
          // log it loudly (the original create error still propagates) so the
          // orphan is findable instead of silently accumulating.
          const rollback = () =>
            this.destroy(name).catch((cleanupErr) => {
              console.error(`[blaxel] create rollback failed; sandbox ${name} may be orphaned`, cleanupErr);
            });
          if (bootstrapResult.status === "rejected") {
            await rollback();
            throw bootstrapResult.reason;
          }
          if (previewResult.status === "rejected") {
            await rollback();
            throw previewResult.reason;
          }
          const previewUrl = previewResult.value;
          span.setAttribute("cmux.vm.id", name);
          return {
            provider: "blaxel",
            providerVmId: name,
            status: "running",
            image,
            createdAt: Date.now(),
            providerMetadata: homeVolume
              ? { sandboxUrl, previewUrl, homeVolume, image, memoryMb }
              : { sandboxUrl, previewUrl, image, memoryMb },
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("blaxel", `create(${image}) failed`, err);
        }
      },
    );
  }

  private async bootstrapDaemon(name: string, sandboxUrl: string): Promise<void> {
    const b64 = await timedStep("daemon_binary_encode", () => daemonBinaryBase64Gzip());
    // Both filesystem writes are independent; the install exec below is the barrier
    // that needs them on disk.
    await Promise.all([
      timedStep("daemon_upload", () => blaxelFetch(
        "PUT",
        // Leading slash after /filesystem: relative paths root at /blaxel, absolute paths need
        // the extra separator (`/filesystem//tmp/...`).
        `${sandboxUrl}/filesystem//tmp/cmuxd.b64`,
        { content: b64, permissions: "0600" },
        { timeoutMs: 180_000 },
      )),
      blaxelFetch(
        "PUT",
        `${sandboxUrl}/filesystem/${SMART_SLEEP_PATH}`,
        { content: SMART_SLEEP_SCRIPT, permissions: "0755" },
      ),
    ]);
    const install = await timedStep("daemon_install", () => this.sandboxExec(
      sandboxUrl,
      `base64 -d /tmp/cmuxd.b64 | gunzip > ${CMUXD_BINARY_PATH} && chmod 755 ${CMUXD_BINARY_PATH} && rm /tmp/cmuxd.b64 && chmod 755 ${SMART_SLEEP_PATH} && mkdir -p /tmp/cmux && chmod 700 /tmp/cmux && ${CMUXD_BINARY_PATH} version`,
    ));
    if (install.exitCode !== 0) {
      throw new ProviderError("blaxel", `daemon install in ${name} failed: ${install.stderr || install.stdout}`);
    }
    // Everything after the install is mutually independent: the daemon and watcher
    // processes, the hostname→VNC-heal chain (ordered within itself — the heal only
    // succeeds once the hostname resolves; runtime state, so it re-applies on
    // resurrection too), and the background provision process (agents and dev
    // essentials come with the machine without delaying attach; the .bashrc seed is
    // write-once — /root persists, and a user's edits win).
    await Promise.all([
      timedStep("daemon_start", () => this.startDaemonProcess(sandboxUrl)),
      timedStep("watcher_start", () => this.startWatcherProcess(sandboxUrl)),
      (async () => {
        await timedStep("hostname_setup", () => this.sandboxExec(sandboxUrl, hostnameSetupCommand(name)).catch(() => undefined));
        await timedStep("vnc_heal_start", () => this.startDesktopVncHeal(sandboxUrl));
      })(),
      blaxelFetch<BlaxelProcess>("POST", `${sandboxUrl}/process`, {
        name: "cmux-provision",
        command: CMUX_PROVISION_COMMAND,
        waitForCompletion: false,
      }).catch(() => undefined),
    ]);
  }

  // The daemon itself is NOT keepAlive: while every shell is idle and no client is attached,
  // nothing pins the sandbox and Blaxel freezes it (processes preserved in the memory
  // snapshot). The smart-sleep watcher is the only keepAlive process, and it exits when idle.
  private async startDaemonProcess(sandboxUrl: string): Promise<void> {
    await blaxelFetch<BlaxelProcess>("POST", `${sandboxUrl}/process`, {
      name: CMUXD_PROCESS_NAME,
      command:
        `${CMUXD_BINARY_PATH} serve --ws --listen 0.0.0.0:${CMUXD_WS_PORT} ` +
        `--auth-lease-file ${CMUXD_WS_PTY_LEASE_PATH} --rpc-auth-lease-file ${CMUXD_WS_RPC_LEASE_PATH} ` +
        `--shell /bin/bash`,
      waitForCompletion: false,
      keepAlive: false,
      restartOnFailure: true,
      maxRestarts: 10,
    });
  }

  private async startWatcherProcess(sandboxUrl: string): Promise<void> {
    await blaxelFetch<BlaxelProcess>("POST", `${sandboxUrl}/process`, {
      name: SMART_SLEEP_PROCESS_NAME,
      command: SMART_SLEEP_PATH,
      waitForCompletion: false,
      keepAlive: true,
    });
  }

  // Best-effort: a desktop machine should come up with its screen, but a base machine has no
  // start-vnc.sh and the command self-exits, so this is safe to run on every bootstrap. Not
  // keepAlive — a live desktop is pinned by the attached client, not by this starter.
  private async startDesktopVncHeal(sandboxUrl: string): Promise<void> {
    await blaxelFetch<BlaxelProcess>("POST", `${sandboxUrl}/process`, {
      name: DESKTOP_VNC_HEAL_PROCESS_NAME,
      command: DESKTOP_VNC_HEAL_COMMAND,
      waitForCompletion: false,
      keepAlive: false,
    }).catch(() => undefined);
  }

  async destroy(vmId: string): Promise<void> {
    await withVmSpan(
      "cmux.vm.provider.destroy",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "destroy", "cmux.vm.id": vmId },
      async () => {
        try {
          await blaxelFetch("DELETE", `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}`);
        } catch (err) {
          // Cleanup paths retry destroy after partial create failures; a sandbox
          // that is already gone is this operation's success state, not an error.
          const gone = err instanceof ProviderError && /-> 404/.test(err.message);
          if (!gone) throw err;
        }
      },
    );
  }

  async getStatus(vmId: string): Promise<VMStatus> {
    const sandbox = await this.getSandbox(vmId);
    return mapStatus(sandbox);
  }

  // Blaxel hibernates automatically (~15 s after the last connection when no keepAlive process
  // is running) and wakes transparently on the next request, so pause is a no-op and resume is
  // just a status read that also serves as the wake request.
  async pause(vmId: string): Promise<void> {
    void vmId;
  }

  async resume(vmId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.resume",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "resume", "cmux.vm.id": vmId },
      async () => {
        const sandbox = await this.getSandbox(vmId);
        return this.handleFromSandbox(vmId, sandbox);
      },
    );
  }

  async exec(vmId: string, command: string, opts?: { timeoutMs?: number }): Promise<ExecResult> {
    const timeoutMs = Math.min(opts?.timeoutMs ?? EXEC_DEFAULT_TIMEOUT_MS, MAX_EXEC_TIMEOUT_MS);
    return withVmSpan(
      "cmux.vm.provider.exec",
      {
        "cmux.vm.provider": "blaxel",
        "cmux.vm.operation": "exec",
        "cmux.vm.id": vmId,
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      },
      async (span) => {
        const sandboxUrl = await this.sandboxApiUrl(vmId);
        const result = await this.sandboxExec(sandboxUrl, command, timeoutMs);
        span.setAttribute("cmux.exec.exit_code", result.exitCode);
        return result;
      },
    );
  }

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    void vmId;
    void name;
    // Blaxel exposes GET/POST /sandboxes/{name}/snapshots, but the API returns
    // 403 "Sandbox snapshot/fork feature is not enabled for this workspace" on the current
    // workspace tier (verified 2026-08-20). Wire this up once the feature is enabled; until
    // then durability comes from standby memory snapshots (automatic) and the sandbox TTL.
    throw new NotImplementedError("blaxel", "snapshot");
  }

  async restore(snapshotId: string): Promise<VMHandle> {
    void snapshotId;
    throw new NotImplementedError("blaxel", "restore");
  }

  async openSSH(vmId: string): Promise<SSHEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_ssh",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "open_ssh", "cmux.vm.id": vmId },
      async () => {
        throw new ProviderError(
          "blaxel",
          "Blaxel sandboxes are WebSocket-only (HTTPS preview ingress, no raw TCP). " +
            "Use the WebSocket attach path, or another provider for SSH.",
        );
      },
    );
  }

  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    const endpoint = await this.openWebSocketPty(vmId, options);
    if (options?.requireDaemon && !endpoint.daemon) {
      throw new ProviderError(
        "blaxel",
        `openAttach(${vmId}) requires a cmuxd RPC endpoint, but the sandbox daemon has no RPC lease path.`,
      );
    }
    return endpoint;
  }

  async openWebSocketPty(vmId: string, options?: AttachOptions): Promise<WebSocketPtyEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_websocket_pty",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "open_websocket_pty", "cmux.vm.id": vmId },
      async (span) => {
        try {
          // The status read doubles as the wake request for a sandbox in standby. A
          // persistent-home machine whose sandbox is gone gets resurrected around its volume.
          // "Gone" is either a 404 or a still-listed TERMINATED/DELETING record — Blaxel
          // deletion is asynchronous, so both shapes mean the compute is dead.
          let sandbox: BlaxelSandbox | null = null;
          try {
            const fetched = await this.getSandbox(vmId);
            sandbox = mapStatus(fetched) === "destroyed" ? null : fetched;
          } catch (err) {
            const gone = err instanceof ProviderError && /-> 404/.test(err.message);
            if (!gone) throw err;
          }
          if (!sandbox) {
            sandbox = options?.providerMetadata
              ? await this.resurrectSandbox(vmId, options.providerMetadata)
              : null;
            if (!sandbox) {
              throw new ProviderError("blaxel", `sandbox ${vmId} is gone and has no persistent home to resurrect from`);
            }
          }
          const sandboxUrl = sandbox.metadata?.url;
          if (!sandboxUrl) {
            throw new Error("sandbox is missing metadata.url");
          }
          await this.ensureDaemonRunning(vmId, sandboxUrl);

          const pty = makeWebSocketLease("blaxel", "pty", true, CMUXD_WS_PTY_LEASE_TTL_SECONDS, options?.sessionId);
          const attachmentId = options?.attachmentId?.trim() || makeWebSocketAttachmentId("blaxel");
          const encodedPTY = Buffer.from(JSON.stringify(pty.lease)).toString("base64");
          const commands = [
            ensurePrivateDirectoryCommand(CMUXD_WS_PTY_LEASE_PATH),
            `printf '%s' '${encodedPTY}' | base64 -d > ${shellQuote(CMUXD_WS_PTY_LEASE_PATH)}`,
            `chmod 600 ${shellQuote(CMUXD_WS_PTY_LEASE_PATH)}`,
          ];

          let daemon: ReusableRpcLease | null = null;
          const existingDaemon = await this.readReusableRpcLease(sandboxUrl);
          const newDaemon = existingDaemon
            ? null
            : makeWebSocketLease("blaxel", "rpc", false, CMUXD_WS_RPC_LEASE_TTL_SECONDS);
          daemon = existingDaemon ?? newDaemon!;
          if (newDaemon) {
            const encodedDaemon = Buffer.from(JSON.stringify(newDaemon.lease)).toString("base64");
            const encodedDaemonClient = Buffer.from(JSON.stringify(leaseClientMetadata(newDaemon))).toString("base64");
            commands.push(
              ensurePrivateDirectoryCommand(CMUXD_WS_RPC_LEASE_PATH),
              `printf '%s' '${encodedDaemon}' | base64 -d > ${shellQuote(CMUXD_WS_RPC_LEASE_PATH)}`,
              `chmod 600 ${shellQuote(CMUXD_WS_RPC_LEASE_PATH)}`,
              `printf '%s' '${encodedDaemonClient}' | base64 -d > ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
              `chmod 600 ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
            );
          }
          const leaseWrite = await this.sandboxExec(sandboxUrl, commands.join(" && "));
          if (leaseWrite.exitCode !== 0) {
            throw new Error(`lease write failed: ${leaseWrite.stderr || leaseWrite.stdout}`);
          }

          const preview = await this.ensurePreview(vmId);
          const previewToken = await this.mintPreviewToken(vmId);
          const headers = { "X-Blaxel-Preview-Token": previewToken };
          await ensureWebSocketHealthy(preview, headers);

          const wsBase = preview.replace(/^https:/, "wss:").replace(/\/+$/, "");
          span.setAttribute("cmux.vm.attach.transport", "websocket");
          span.setAttribute("cmux.vm.attach.expires_at_unix", pty.expiresAtUnix);
          span.setAttribute("cmux.vm.attach.daemon_available", true);
          return {
            transport: "websocket",
            url: `${wsBase}/terminal`,
            headers,
            token: pty.token,
            sessionId: pty.sessionId,
            attachmentId,
            expiresAtUnix: pty.expiresAtUnix,
            daemon: {
              url: `${wsBase}/rpc`,
              headers,
              token: daemon.token,
              sessionId: daemon.sessionId,
              expiresAtUnix: daemon.expiresAtUnix,
            },
          };
        } catch (err) {
          throw err instanceof ProviderError
            ? err
            : new ProviderError("blaxel", `openWebSocketPty(${vmId}) failed`, err);
        }
      },
    );
  }

  async revokeSSHIdentity(identityHandle: string): Promise<void> {
    void identityHandle;
    // openSSH always throws, so there is never an identity to revoke.
  }

  /**
   * Close every cmux ingress for a machine during account sign-out.
   *
   * Blaxel preview tokens are independent of Stack Auth, so deleting only the
   * Postgres lease row would leave a copied preview URL usable until its TTL.
   * Remove the private previews and stop cmuxd before returning; the next
   * authenticated attach recreates both idempotently.
   */
  async revokeEndpointLeases(vmId: string): Promise<void> {
    const previewsBase = `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}/previews`;
    let sandbox: BlaxelSandbox | null = null;
    try {
      sandbox = await this.getSandbox(vmId);
    } catch (err) {
      if (!(err instanceof ProviderError && /-> 404/.test(err.message))) throw err;
    }

    const sandboxUrl = sandbox?.metadata?.url;
    if (sandboxUrl) {
      const result = await this.sandboxExec(
        sandboxUrl,
        [
          `rm -f ${shellQuote(CMUXD_WS_PTY_LEASE_PATH)} ${shellQuote(CMUXD_WS_RPC_LEASE_PATH)} ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
          `pkill -TERM -x ${shellQuote(CMUXD_PROCESS_NAME)} 2>/dev/null || true`,
          `pkill -TERM -x ${shellQuote(SMART_SLEEP_PROCESS_NAME)} 2>/dev/null || true`,
          `pkill -KILL -x ${shellQuote(CMUXD_PROCESS_NAME)} 2>/dev/null || true`,
        ].join("; "),
        15_000,
      );
      if (result.exitCode !== 0) {
        throw new ProviderError(
          "blaxel",
          `revokeEndpointLeases(${vmId}) failed to stop cmuxd: ${result.stderr || result.stdout}`,
        );
      }
    }

    // Preview deletion is control-plane-only, so it also works when the
    // sandbox is asleep and has no live sandbox API URL.
    let listed: unknown;
    try {
      listed = await blaxelFetch<unknown>("GET", previewsBase);
    } catch (err) {
      if (err instanceof ProviderError && /-> 404/.test(err.message)) return;
      throw err;
    }
    const rawItems = Array.isArray(listed)
      ? listed
      : listed && typeof listed === "object" && Array.isArray((listed as { items?: unknown }).items)
      ? (listed as { items: unknown[] }).items
      : [];
    const names = rawItems
      .map((item) => {
        if (!item || typeof item !== "object") return null;
        const candidate = item as BlaxelPreview;
        return candidate.metadata?.name?.trim() || null;
      })
      .filter((name): name is string => !!name);
    await Promise.all(names.map(async (name) => {
      try {
        await blaxelFetch("DELETE", `${previewsBase}/${encodeURIComponent(name)}`);
      } catch (err) {
        if (!(err instanceof ProviderError && /-> 404/.test(err.message))) throw err;
      }
    }));
  }

  private async getSandbox(vmId: string): Promise<BlaxelSandbox> {
    return blaxelFetch<BlaxelSandbox>("GET", `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}`);
  }

  private async ensureHomeVolume(name: string): Promise<void> {
    const sizeMb = positiveIntEnv("CMUX_VM_BLAXEL_HOME_VOLUME_MB", DEFAULT_HOME_VOLUME_MB);
    try {
      await blaxelFetch("POST", `${CONTROL_PLANE_BASE}/volumes`, {
        metadata: { name },
        spec: { size: sizeMb },
      });
    } catch (err) {
      // An existing volume is the expected steady state; anything else is fatal.
      const conflict = err instanceof ProviderError && /-> 409/.test(err.message);
      if (!conflict) throw err;
    }
  }

  /**
   * Resurrection: a persistent-home machine whose sandbox is gone (TTL expiry, provider loss)
   * is recreated around the same volume and re-bootstrapped, so from the user's side the
   * machine never died — its compute was just asleep somewhere deeper. Only possible when the
   * VM row's providerMetadata carries homeVolume + image from the original create.
   */
  private async resurrectSandbox(
    vmId: string,
    metadata: Record<string, unknown>,
  ): Promise<BlaxelSandbox | null> {
    const homeVolume = typeof metadata.homeVolume === "string" ? metadata.homeVolume : null;
    const image = typeof metadata.image === "string" ? metadata.image : null;
    if (!homeVolume || !image) return null;
    await this.ensureHomeVolume(homeVolume);
    const memoryMb = resolveMemoryMb(
      typeof metadata.memoryMb === "number" ? metadata.memoryMb : undefined,
    );
    const created = await blaxelFetch<BlaxelSandbox>("POST", `${CONTROL_PLANE_BASE}/sandboxes`, {
      metadata: { name: vmId },
      spec: {
        runtime: {
          image,
          memory: memoryMb,
          envs: [{ name: "LANG", value: "C.UTF-8" }],
          ports: [{ name: CMUXD_PREVIEW_NAME, protocol: "HTTP", target: CMUXD_WS_PORT }],
        },
        volumes: [{ name: homeVolume, mountPath: HOME_VOLUME_MOUNT_PATH }],
      },
    });
    const sandboxUrl = created.metadata?.url;
    if (!sandboxUrl) {
      throw new ProviderError("blaxel", `resurrect(${vmId}) returned no sandbox url`);
    }
    await this.bootstrapDaemon(vmId, sandboxUrl);
    return created;
  }

  private async sandboxApiUrl(vmId: string): Promise<string> {
    const sandbox = await this.getSandbox(vmId);
    const url = sandbox.metadata?.url;
    if (!url) {
      throw new ProviderError("blaxel", `sandbox ${vmId} has no API url (status ${sandbox.status ?? "unknown"})`);
    }
    return url;
  }

  private handleFromSandbox(vmId: string, sandbox: BlaxelSandbox): VMHandle {
    return {
      provider: "blaxel",
      providerVmId: vmId,
      status: mapStatus(sandbox),
      image: sandbox.spec?.runtime?.image ?? "unknown",
      createdAt: sandbox.metadata?.createdAt ? Date.parse(sandbox.metadata.createdAt) : Date.now(),
      providerMetadata: sandbox.metadata?.url ? { sandboxUrl: sandbox.metadata.url } : undefined,
    };
  }

  private async sandboxExec(sandboxUrl: string, command: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS): Promise<ExecResult> {
    const result = await blaxelFetch<BlaxelProcess>(
      "POST",
      `${sandboxUrl}/process`,
      { command, waitForCompletion: true, timeout: Math.ceil(timeoutMs / 1000) },
      { timeoutMs: timeoutMs + 30_000 },
    );
    return {
      exitCode: result.exitCode ?? (result.status === "completed" ? 0 : 1),
      stdout: result.stdout ?? "",
      stderr: result.stderr ?? "",
    };
  }

  private async ensureDaemonRunning(vmId: string, sandboxUrl: string): Promise<void> {
    const proc = await blaxelFetch<BlaxelProcess>(
      "GET",
      `${sandboxUrl}/process/${CMUXD_PROCESS_NAME}`,
    ).catch(() => null);
    if (proc?.status !== "running") {
      // A sandbox can exist without the daemon binary (a create/resurrect that died between
      // the sandbox POST and the install, or an image rollout that wiped /usr/local/bin).
      // Starting the process would just crash-loop with exit 127, so re-run the full
      // bootstrap — install is idempotent and bootstrap also starts daemon and watcher.
      const installed = await this.sandboxExec(sandboxUrl, `test -x ${CMUXD_BINARY_PATH}`).catch(() => null);
      if (installed?.exitCode !== 0) {
        await this.bootstrapDaemon(vmId, sandboxUrl);
        return;
      }
      await this.startDaemonProcess(sandboxUrl);
    }
    // Attach = user activity: re-arm the smart-sleep watcher so the sandbox stays awake while
    // this session works, and can freeze again once it goes idle.
    const watcher = await blaxelFetch<BlaxelProcess>(
      "GET",
      `${sandboxUrl}/process/${SMART_SLEEP_PROCESS_NAME}`,
    ).catch(() => null);
    if (watcher?.status !== "running") {
      await this.startWatcherProcess(sandboxUrl);
    }
  }

  private async readReusableRpcLease(sandboxUrl: string): Promise<ReusableRpcLease | null> {
    const result = await this.sandboxExec(
      sandboxUrl,
      [
        `test -s ${shellQuote(CMUXD_WS_RPC_LEASE_PATH)}`,
        `test -s ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
        `cat ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
      ].join(" && "),
    ).catch(() => null);
    const raw = result?.exitCode === 0 ? result.stdout.trim() : "";
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw) as unknown;
      if (!isReusableRpcLease(parsed)) return null;
      const nowUnix = Math.floor(Date.now() / 1000);
      if (parsed.expiresAtUnix <= nowUnix + CMUXD_WS_RPC_RENEW_BEFORE_SECONDS) return null;
      return parsed;
    } catch {
      return null;
    }
  }

  // One in-flight ensure per (machine, preview): a create that races the attach it triggers
  // must not mint the same preview twice. Cross-process races are handled below by re-reading
  // the preview after a failed branded create instead of clobbering it.
  private readonly inflightPreviews = new Map<string, Promise<string>>();

  private ensurePreview(vmId: string, previewName = CMUXD_PREVIEW_NAME, port = CMUXD_WS_PORT): Promise<string> {
    const key = `${vmId}/${previewName}`;
    const inflight = this.inflightPreviews.get(key);
    if (inflight) return inflight;
    const task = this.ensurePreviewUncoalesced(vmId, previewName, port).finally(() => {
      this.inflightPreviews.delete(key);
    });
    this.inflightPreviews.set(key, task);
    return task;
  }

  private async ensurePreviewUncoalesced(vmId: string, previewName: string, port: number): Promise<string> {
    const base = `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}/previews`;
    const readExisting = () =>
      blaxelFetch<BlaxelPreview>("GET", `${base}/${previewName}`).catch(() => null);
    const prefixUrl = brandedPreviewPrefix(vmId, previewName, port);
    const customDomain = prefixUrl ? await verifiedCustomDomain() : null;
    const existing = await readExisting();
    const existingUrl = usablePrivatePreviewUrl(existing);
    if (existingUrl) {
      const existingCustomDomain = existing?.spec?.customDomain?.trim().toLowerCase();
      const existingHost = (() => {
        try {
          return new URL(existingUrl).hostname.toLowerCase();
        } catch {
          return "";
        }
      })();
      const alreadyOnCustomDomain =
        !!customDomain &&
        (existingCustomDomain === customDomain.toLowerCase() ||
          existingHost.endsWith(`.${customDomain.toLowerCase()}`));
      if (!customDomain || alreadyOnCustomDomain) return existingUrl;
      // The custom domain became verified after this preview was created. Rotate only the
      // ingress record (never the sandbox or its files) so existing machines converge to
      // the cmux-owned hostname on their next attach/open-port request.
      await blaxelFetch("DELETE", `${base}/${previewName}`).catch(() => undefined);
    }
    if (existing?.spec?.url && !existingUrl) {
      // The preview exists but is public; drop it and recreate private below.
      await blaxelFetch("DELETE", `${base}/${previewName}`);
    }
    // Branded subdomains: Blaxel renders prefixUrl as https://<prefix>-<workspace>.preview.bl.run,
    // so with the cmux workspace the daemon preview reads noble-wren-cmux.preview.bl.run and a
    // port preview noble-wren-3000-cmux.preview.bl.run — the machine's name is its address. A
    // rejected prefix (collision, length, validation) falls back to the opaque hash URL rather
    // than failing the attach.
    const brandedSpecs: Array<{ label: string; spec: Record<string, unknown> }> = [];
    if (prefixUrl && customDomain) {
      // Blaxel's API takes the bare verified domain in customDomain and composes the
      // host from prefixUrl: {prefixUrl: "noble-wren", customDomain: "vm.cmux.sh"} →
      // https://noble-wren.vm.cmux.sh. Passing the full host 404s ("Custom domain not found").
      brandedSpecs.push({ label: "custom-domain", spec: { port, public: false, prefixUrl, customDomain } });
    }
    if (prefixUrl) {
      brandedSpecs.push({ label: "branded", spec: { port, public: false, prefixUrl } });
    }
    for (const attempt of brandedSpecs) {
      try {
        const created = await blaxelFetch<BlaxelPreview>("POST", base, {
          metadata: { name: previewName },
          spec: attempt.spec,
        });
        const url = usablePrivatePreviewUrl(created);
        if (url) return url;
      } catch (error) {
        // The usual reason a branded create fails is that another caller (a second server
        // instance, or the attach racing the create that spawned it) minted this preview a
        // moment ago under the same prefix. Adopt that one; an unbranded create here would
        // upsert the name and replace the machine-name URL with an opaque hash.
        const raced = usablePrivatePreviewUrl(await readExisting());
        if (raced) return raced;
        console.warn(
          `[blaxel] ${attempt.label} preview create failed for ${vmId}/${previewName}; falling back:`,
          error instanceof Error ? error.message : String(error),
        );
      }
    }
    const created = await blaxelFetch<BlaxelPreview>("POST", base, {
      metadata: { name: previewName },
      spec: { port, public: false },
    });
    const url = usablePrivatePreviewUrl(created);
    if (!url) {
      throw new ProviderError("blaxel", `preview create for ${vmId} returned no url or came back public`);
    }
    return url;
  }

  private async mintPreviewToken(vmId: string, previewName = CMUXD_PREVIEW_NAME): Promise<string> {
    const expiresAt = new Date(Date.now() + PREVIEW_TOKEN_TTL_SECONDS * 1000).toISOString();
    const created = await blaxelFetch<{ spec?: { token?: string } }>(
      "POST",
      `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}/previews/${previewName}/tokens`,
      { spec: { expiresAt } },
    );
    const token = created.spec?.token;
    if (!token) {
      throw new ProviderError("blaxel", `preview token mint for ${vmId} returned no token`);
    }
    return token;
  }

  // The Cloud panel's activity view. A control-plane read tells us whether the machine is
  // awake; only then do we exec on it (an exec would wake a sleeping machine, and a
  // sleeping machine costs nothing — the panel should show that, not defeat it).
  async getStats(vmId: string): Promise<VMStats> {
    return withVmSpan("vm.stats", { "cmux.vm.provider": "blaxel", "cmux.vm.id": vmId }, async () => {
      const sandbox = await this.getSandbox(vmId);
      const memoryTotalMb = sandbox.spec?.runtime?.memory;
      const rawState = (sandbox.state ?? "").toUpperCase();
      const state: VMStats["state"] = rawState === "RUNNING" ? "awake" : rawState ? "asleep" : "unknown";
      const sampledAt = Date.now();
      const sandboxUrl = sandbox.metadata?.url;
      if (state !== "awake" || !sandboxUrl) {
        return { state, sampledAt, memoryTotalMb };
      }
      const result = await this.sandboxExec(sandboxUrl, MACHINE_STATS_COMMAND, 15_000);
      return { state, sampledAt, ...parseMachineStats(result.stdout, memoryTotalMb) };
    });
  }

  // The exe.dev "https://vmname.exe.xyz:3456" equivalent: a private, token-gated preview URL
  // for any HTTP port on the machine. The token rides as ?bl_preview_token=... (the gateway
  // sets a cookie on first load, so pages and their websockets keep working in a browser).
  async openPort(vmId: string, port: number): Promise<{ url: string; token: string; openUrl: string }> {
    return withVmSpan(
      "cmux.vm.provider.open_port",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "open_port", "cmux.vm.id": vmId, "cmux.vm.port": port },
      async () => {
        if (!Number.isInteger(port) || port < 1 || port > 65535 || port === CMUX_SANDBOX_API_PORT) {
          throw new ProviderError("blaxel", `openPort(${vmId}) requires a valid port other than ${CMUX_SANDBOX_API_PORT}`);
        }
        // Wake the sandbox (status read) so the preview answers immediately.
        await this.getSandbox(vmId);
        const previewName = `port-${port}`;
        const url = await this.ensurePreview(vmId, previewName, port);
        const token = await this.mintPreviewToken(vmId, previewName);
        const openUrl = `${url.replace(/\/+$/, "")}/?bl_preview_token=${encodeURIComponent(token)}`;
        return { url, token, openUrl };
      },
    );
  }
}

// Preview subdomain prefix: the machine name for the daemon preview, machine-port for port
// previews. Only lowercase alphanumerics and hyphens survive; anything else (or an
// over-long result) disables branding for that preview rather than risking a failed create.
// Fully-owned machine URLs: when CMUX_VM_BLAXEL_CUSTOM_DOMAIN names a domain that is
// registered AND verified on the workspace (e.g. vm.cmux.sh with its wildcard CNAME live),
// previews are created on <prefix>.<domain> — noble-wren.vm.cmux.sh — instead of bl.run.
// Blaxel rejects customDomain while verification is pending, so the driver checks status
// (cached briefly) and silently keeps the prefix/hash URL until DNS is live.
let cachedCustomDomain: { value: string | null; checkedAt: number } | null = null;
const CUSTOM_DOMAIN_CACHE_MS = 5 * 60 * 1000;

async function verifiedCustomDomain(): Promise<string | null> {
  const domain = env("CMUX_VM_BLAXEL_CUSTOM_DOMAIN");
  if (!domain) return null;
  if (cachedCustomDomain && Date.now() - cachedCustomDomain.checkedAt < CUSTOM_DOMAIN_CACHE_MS) {
    return cachedCustomDomain.value;
  }
  let value: string | null = null;
  try {
    const record = await blaxelFetch<{ spec?: { status?: string } }>(
      "GET",
      `${CONTROL_PLANE_BASE}/customdomains/${encodeURIComponent(domain)}`,
    );
    value = record.spec?.status === "verified" ? domain : null;
  } catch {
    value = null;
  }
  cachedCustomDomain = { value, checkedAt: Date.now() };
  return value;
}

// One shell round-trip that samples everything the Cloud panel's activity view shows.
// Two /proc/stat reads half a second apart give a real CPU% (loadavg alone lags minutes).
export const MACHINE_STATS_COMMAND =
  "head -1 /proc/stat; sleep 0.5; head -1 /proc/stat; cat /proc/loadavg; nproc; " +
  "grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; df -kP /root | tail -1";

export function parseMachineStats(
  stdout: string,
  memoryTotalMbFallback?: number,
): Omit<VMStats, "state" | "sampledAt"> {
  const lines = stdout.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const cpuLines = lines.filter((l) => /^cpu\s/.test(l));
  let cpuPercent: number | undefined;
  if (cpuLines.length >= 2) {
    const sample = (line: string) => {
      const n = line.split(/\s+/).slice(1).map(Number);
      const idle = (n[3] ?? 0) + (n[4] ?? 0);
      const total = n.reduce((a, b) => a + (Number.isFinite(b) ? b : 0), 0);
      return { idle, total };
    };
    const a = sample(cpuLines[0]!);
    const b = sample(cpuLines[cpuLines.length - 1]!);
    const total = b.total - a.total;
    const idle = b.idle - a.idle;
    if (total > 0) cpuPercent = Math.max(0, Math.min(100, ((total - idle) / total) * 100));
  }
  const loadLine = lines.find((l) => /^\d+(\.\d+)?\s+\d+(\.\d+)?\s+\d+(\.\d+)?\s+\d+\/\d+/.test(l));
  const loadAverage1m = loadLine ? Number(loadLine.split(/\s+/)[0]) : undefined;
  const cpusLine = lines.find((l) => /^\d+$/.test(l));
  const cpus = cpusLine ? Number(cpusLine) : undefined;
  const memKb = (key: string) => {
    const line = lines.find((l) => l.startsWith(`${key}:`));
    const value = line ? Number(line.split(/\s+/)[1]) : NaN;
    return Number.isFinite(value) ? value : undefined;
  };
  const memTotalKb = memKb("MemTotal");
  const memAvailableKb = memKb("MemAvailable");
  const memoryTotalMb = memTotalKb !== undefined ? Math.round(memTotalKb / 1024) : memoryTotalMbFallback;
  const memoryUsedMb =
    memTotalKb !== undefined && memAvailableKb !== undefined
      ? Math.max(0, Math.round((memTotalKb - memAvailableKb) / 1024))
      : undefined;
  // df -kP: Filesystem 1024-blocks Used Available Capacity Mounted
  const dfLine = lines.find((l) => /^\S+\s+\d+\s+\d+\s+\d+\s+\d+%/.test(l));
  let diskTotalMb: number | undefined;
  let diskUsedMb: number | undefined;
  if (dfLine) {
    const cols = dfLine.split(/\s+/);
    diskTotalMb = Math.round(Number(cols[1]) / 1024);
    diskUsedMb = Math.round(Number(cols[2]) / 1024);
  }
  return { cpus, cpuPercent, loadAverage1m, memoryTotalMb, memoryUsedMb, diskTotalMb, diskUsedMb };
}

function brandedPreviewPrefix(vmId: string, previewName: string, port: number): string | null {
  const machine = vmId.toLowerCase();
  if (!/^[a-z0-9][a-z0-9-]{0,40}$/.test(machine)) return null;
  const prefix = previewName === CMUXD_PREVIEW_NAME ? machine : `${machine}-${port}`;
  return prefix.length <= 48 ? prefix : null;
}

function mapStatus(sandbox: BlaxelSandbox): VMStatus {
  switch (sandbox.status) {
    case "TERMINATED":
    case "DELETING":
      return "destroyed";
    case "UPLOADING":
    case "BUILDING":
    case "DEPLOYING":
      return "creating";
    default:
      // DEPLOYED covers both RUNNING and STANDBY states; standby wakes transparently on the
      // next request, so callers can treat it as running.
      return "running";
  }
}

async function ensureWebSocketHealthy(previewUrl: string, headers: Record<string, string>): Promise<void> {
  const url = `${previewUrl.replace(/\/+$/, "")}/healthz`;
  let lastError: unknown;
  for (let attempt = 0; attempt < HEALTH_RETRY_ATTEMPTS; attempt += 1) {
    try {
      const response = await fetch(url, { headers, signal: AbortSignal.timeout(10_000) });
      if (response.ok) return;
      lastError = new Error(`healthz returned ${response.status}`);
    } catch (err) {
      lastError = err;
    }
    await new Promise((resolve) => setTimeout(resolve, HEALTH_RETRY_INTERVAL_MS));
  }
  throw new ProviderError("blaxel", "cmuxd websocket health check failed", lastError);
}

// Machines are addressed by name everywhere (`cmux vm ssh brave-otter`), so names are
// generated memorable instead of opaque. Blaxel sandbox names ARE the provider VM id, so
// this is the whole naming story — no display-name mapping to keep in sync. Collisions
// retry with fresh picks, then fall back to a random suffix.
const NAME_ADJECTIVES = [
  "amber", "bold", "brave", "brisk", "calm", "clever", "coral", "crisp",
  "eager", "fleet", "gold", "happy", "keen", "kind", "lively", "lucid",
  "mellow", "noble", "quick", "quiet", "rapid", "sharp", "silver", "smooth",
  "solid", "spry", "steady", "sunny", "swift", "tidy", "vivid", "warm",
];
const NAME_ANIMALS = [
  "badger", "bison", "crane", "dolphin", "falcon", "finch", "fox", "gecko",
  "heron", "ibex", "jay", "koala", "lemur", "lynx", "marmot", "marten",
  "newt", "orca", "osprey", "otter", "owl", "panda", "petrel", "puffin",
  "raven", "seal", "sparrow", "stoat", "swan", "tern", "wombat", "wren",
];

export function friendlyVmName(withSuffix = false): string {
  const pick = (list: readonly string[]) => list[randomBytes(1)[0] % list.length];
  const base = `${pick(NAME_ADJECTIVES)}-${pick(NAME_ANIMALS)}`;
  if (!withSuffix) return base;
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  const suffix = Array.from(randomBytes(4), (byte) => alphabet[byte % alphabet.length]).join("");
  return `${base}-${suffix}`;
}

export function resolveBlaxelMemoryMb(
  requested: number | undefined,
  envValues: Record<string, string | undefined> = process.env,
): number {
  if (requested !== undefined) {
    if (!Number.isSafeInteger(requested) || requested <= 0) {
      throw new ProviderError("blaxel", "memoryMb must be a positive integer");
    }
    return requested;
  }
  const raw = envValues.CMUX_VM_BLAXEL_MEMORY_MB?.trim();
  if (!raw) return DEFAULT_MEMORY_MB;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_MEMORY_MB;
}

function resolveMemoryMb(requested: number | undefined): number {
  return resolveBlaxelMemoryMb(requested);
}

function positiveIntEnv(name: string, fallback: number): number {
  const raw = env(name);
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}
