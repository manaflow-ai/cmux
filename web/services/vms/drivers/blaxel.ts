import { dirname } from "node:path";
import { randomBytes } from "node:crypto";
import {
  NotImplementedError,
  ProviderError,
  type AttachEndpoint,
  type AttachOptions,
  type AttachTransport,
  type CreateOptions,
  type ExecResult,
  type SSHEndpoint,
  type SnapshotRef,
  type VMHandle,
  type VMProvider,
  type VMStats,
  type VMStatus,
  type CmuxRemoteApprovalResult,
  type CmuxRemoteAttachOptions,
  type CmuxRemoteEndpoint,
} from "./types";
import { withVmSpan } from "../telemetry";
import { shellQuote } from "./wsLease";

// Blaxel sandboxes are name-addressed micro-VMs reached over HTTPS only: a per-sandbox
// "sandbox API" (process exec + filesystem) on the control side, and per-port preview URLs
// (`https://<id>.<region>.preview.bl.run` + `X-Blaxel-Preview-Token` header) for ingress.
// There is no raw TCP, so `openSSH` throws: Blaxel machines attach through the cmux-tui
// remote daemon (transport `cmux-remote`, docs/cloud-cmux-tui-daemon.md), the machine's
// only session daemon.
//
// Unlike the other drivers this one does not need a pre-baked provider image: `create`
// bootstraps a stock Blaxel image by having the sandbox download the pinned cmux-tui
// build onto its persistent home volume and starting `cmux-tui server start` under the
// sandbox supervisor. Blaxel freezes a sandbox ~15 s after the last open connection
// unless a keepAlive process runs; the smart-sleep watcher below is that process, so a
// busy machine stays awake and an idle one drops to (free) standby.
// 8080 is the Blaxel sandbox-api (control channel); never expose it through a preview.
const CMUX_SANDBOX_API_PORT = 8080;
const SMART_SLEEP_PATH = "/usr/local/bin/cmux-smart-sleep";
const SMART_SLEEP_PROCESS_NAME = "cmux-keepalive";
// cmux-tui remote daemon: listens on its own port behind a private preview. The binary
// lives on the persistent home volume so a resurrected sandbox reuses it; daemon identity
// and enrolled devices live under /root too (the daemon's default state dir), so they
// survive as well.
const CMUX_TUI_PORT = 1337;
// Two previews for the same port: the branded one for clients that can pass the
// custom-domain ingress, the raw one for everything else (see cmuxTuiPreviewBranded).
const CMUX_TUI_PREVIEW_NAME = "cmuxtui";
const CMUX_TUI_RAW_PREVIEW_NAME = "cmuxtui-raw";
const CMUX_TUI_SESSION = "cloud";
const CMUX_TUI_BINARY_PATH = "/root/.cmux/bin/cmux-tui";
const CMUX_TUI_PROCESS_NAME = "cmux-tui-daemon";
const CMUX_TUI_INVITATION_TTL_SECONDS = 5 * 60;
const CMUX_TUI_INSTALL_TIMEOUT_MS = 5 * 60 * 1000;
// Blaxel keeps a sandbox awake while any keepAlive process runs and freezes it ~15 s after the
// last connection otherwise. The watcher is that keepAlive process: it stays alive while any
// cmux-tui shell has a foreground/background job (a daemon child with descendants) or any
// client is connected to the daemon port, and exits after a sustained idle grace so the
// sandbox drops to standby ($0, memory snapshot, ~25 ms wake). Every attach re-arms it, so
// "wake" is just reconnecting.
export const SMART_SLEEP_SCRIPT = `#!/bin/sh
# cmux smart sleep: hold the sandbox awake while work is running or a client is attached.
TUI_PORT_HEX=0539 # 1337 (cmux-tui remote daemon)
IDLE_LIMIT=\${CMUX_SMART_SLEEP_IDLE_CHECKS:-8}
INTERVAL=\${CMUX_SMART_SLEEP_INTERVAL:-15}
idle=0
while true; do
  busy=""
  for cm in $(pidof cmux-tui 2>/dev/null); do
    for c in $(pgrep -P "$cm" 2>/dev/null); do
      if pgrep -P "$c" >/dev/null 2>&1; then busy=jobs; break 2; fi
    done
  done
  if [ -z "$busy" ]; then
    if awk -v tui="$TUI_PORT_HEX" '$2 ~ ":"tui"$" && $4 == "01" { found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
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

const PREVIEW_TOKEN_TTL_SECONDS = 12 * 60 * 60;
// Desktop/port panes are long-lived surfaces a person leaves open for days; a
// 12h token turned every long-lived pane into a silent white screen at hour
// twelve. The wrapper page shows an honest expiry screen when this lapses.
const PREVIEW_OPEN_TOKEN_TTL_SECONDS = 7 * 24 * 60 * 60;
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
const MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000;
const CONTROL_PLANE_BASE = "https://api.blaxel.ai/v0";
const DEFAULT_MEMORY_MB = 4096;
// The persistent-home volume mounts over root's home so dotfiles, repos, and agent state
// survive sandbox destruction. The sandbox is disposable compute; the volume is the machine.
const HOME_VOLUME_MOUNT_PATH = "/root";
// Disk scales with memory the way hosted dev boxes do (Codespaces-style tiers), so the
// 24 GB plan default gets a 64 GB home instead of a flat 5 GB. Volumes are created once
// and never resized, so existing machines keep whatever they were born with.
const HOME_VOLUME_MB_BY_MEMORY: ReadonlyArray<readonly [maxMemoryMb: number, volumeMb: number]> = [
  [8 * 1024, 32 * 1024],
  [16 * 1024, 32 * 1024],
  [32 * 1024, 64 * 1024],
];
const HOME_VOLUME_MB_ABOVE_TABLE = 128 * 1024;

/** Home volume size for a machine's memory: ≤8 GB → 32 GB, ≤16 GB → 32 GB, ≤32 GB → 64 GB, above → 128 GB. */
export function defaultHomeVolumeMbForMemory(memoryMb: number): number {
  if (!Number.isFinite(memoryMb) || memoryMb <= 0) {
    throw new ProviderError("blaxel", "memoryMb must be a positive number to size the home volume");
  }
  for (const [maxMemoryMb, volumeMb] of HOME_VOLUME_MB_BY_MEMORY) {
    if (memoryMb <= maxMemoryMb) return volumeMb;
  }
  return HOME_VOLUME_MB_ABOVE_TABLE;
}

/** `CMUX_VM_BLAXEL_HOME_VOLUME_MB` pins every new volume to one size; otherwise disk follows memory. */
export function resolveHomeVolumeMb(
  memoryMb: number,
  envValues: Record<string, string | undefined> = process.env,
): number {
  const raw = envValues.CMUX_VM_BLAXEL_HOME_VOLUME_MB?.trim();
  if (raw) {
    const parsed = Number.parseInt(raw, 10);
    if (Number.isFinite(parsed) && parsed > 0) return parsed;
  }
  return defaultHomeVolumeMbForMemory(memoryMb);
}

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

// The preview URL is the only ingress to the cmux-tui daemon, and it must stay token-gated:
// a preview that is (or has been flipped) public would expose the daemon's `/v1/link`
// listener to anyone holding the URL, leaving device enrollment as the sole barrier. Only a
// private preview's URL is ever usable; a public one is treated as absent so callers replace
// or reject it.
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
// one line per driver step (volume, sandbox create, daemon install, preview) — slow
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

export type CmuxTuiSource = { url: string; sha256: string; commit: string; builtAt: string | null };

export const CMUX_TUI_LINUX_TARGET = "cmux-tui-x86_64-unknown-linux-musl";
export const CMUX_TUI_DEFAULT_MANIFEST_URL = "https://files.cmux.com/cmux-tui/latest/manifest.json";
const CMUX_TUI_MANIFEST_CACHE_MS = 5 * 60 * 1000;

/**
 * cmux-tui is the machine's session daemon; there is no other. CMUX_VM_CMUX_TUI_MANIFEST_URL
 * pins a deployment to one commit's manifest (`https://files.cmux.com/cmux-tui/<commit>/manifest.json`)
 * instead of the rolling `latest`. Nothing else is configured by hand: the build and its
 * sha256 come from the manifest the artifacts workflow publishes.
 */
export function cmuxTuiManifestUrl(): string {
  const url = env("CMUX_VM_CMUX_TUI_MANIFEST_URL") || CMUX_TUI_DEFAULT_MANIFEST_URL;
  if (!/^https:\/\//.test(url)) {
    throw new ProviderError("blaxel", "CMUX_VM_CMUX_TUI_MANIFEST_URL must be an https:// URL");
  }
  return url;
}

/** Parses an artifacts manifest into the Linux source; the binary URL is a sibling of the manifest. */
export function parseCmuxTuiManifest(manifestUrl: string, manifest: unknown): CmuxTuiSource {
  const record = manifest && typeof manifest === "object" ? manifest as Record<string, unknown> : {};
  const commit = typeof record.commit === "string" ? record.commit : "";
  const binaries = record.binaries && typeof record.binaries === "object" ? record.binaries as Record<string, unknown> : {};
  const sha256 = typeof binaries[CMUX_TUI_LINUX_TARGET] === "string" ? (binaries[CMUX_TUI_LINUX_TARGET] as string).toLowerCase() : "";
  if (!/^[0-9a-f]{40}$/.test(commit)) {
    throw new ProviderError("blaxel", `cmux-tui manifest at ${manifestUrl} has no commit`);
  }
  if (!/^[0-9a-f]{64}$/.test(sha256)) {
    throw new ProviderError("blaxel", `cmux-tui manifest at ${manifestUrl} has no ${CMUX_TUI_LINUX_TARGET} sha256 — publish artifacts from a main with the musl target`);
  }
  const base = manifestUrl.replace(/\/manifest\.json$/, "");
  return {
    url: `${base}/${CMUX_TUI_LINUX_TARGET}`,
    sha256,
    commit,
    builtAt: typeof record.builtAt === "string" ? record.builtAt : null,
  };
}

let cmuxTuiSourceCache: { url: string; fetchedAt: number; source: CmuxTuiSource } | null = null;

/** The Linux daemon build to install, from the manifest (cached 5 min per manifest URL). */
export async function resolveCmuxTuiSource(): Promise<CmuxTuiSource> {
  const manifestUrl = cmuxTuiManifestUrl();
  if (cmuxTuiSourceCache && cmuxTuiSourceCache.url === manifestUrl && Date.now() - cmuxTuiSourceCache.fetchedAt < CMUX_TUI_MANIFEST_CACHE_MS) {
    return cmuxTuiSourceCache.source;
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
  let manifest: unknown;
  try {
    const response = await fetch(manifestUrl, { signal: controller.signal, cache: "no-store" });
    if (!response.ok) {
      throw new ProviderError("blaxel", `cmux-tui manifest fetch ${manifestUrl} -> ${response.status}`);
    }
    manifest = await response.json();
  } catch (err) {
    if (cmuxTuiSourceCache?.url === manifestUrl) {
      // A transient manifest outage must not break creates: reuse the last good build.
      return cmuxTuiSourceCache.source;
    }
    throw err instanceof ProviderError ? err : new ProviderError("blaxel", `cmux-tui manifest fetch ${manifestUrl} failed`, err);
  } finally {
    clearTimeout(timer);
  }
  const source = parseCmuxTuiManifest(manifestUrl, manifest);
  cmuxTuiSourceCache = { url: manifestUrl, fetchedAt: Date.now(), source };
  return source;
}

/** Test hook. */
export function resetCmuxTuiSourceCache(): void {
  cmuxTuiSourceCache = null;
}

/**
 * Installs the pinned cmux-tui binary onto the persistent home volume, skipping the
 * download when the installed copy already matches the pin. The VM fetches the ~50 MB
 * static musl binary itself (in-region, seconds) instead of the driver pushing a
 * ~30 MB base64 payload through the sandbox API on every cold create.
 */
export function cmuxTuiInstallCommand(source: CmuxTuiSource): string {
  const bin = shellQuote(CMUX_TUI_BINARY_PATH);
  const tmp = shellQuote(`${CMUX_TUI_BINARY_PATH}.tmp`);
  const pinned = (path: string) => `printf '%s  %s\n' ${shellQuote(source.sha256)} ${path} | sha256sum -c >/dev/null 2>&1`;
  // A stock blaxel/base-image has no curl until background provisioning adds it, so
  // the fetch installs curl itself (apk, Alpine) and falls back to busybox wget.
  const fetch =
    `(command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null 2>&1 || true); ` +
    `if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 --retry-delay 2 -o ${tmp} ${shellQuote(source.url)}; ` +
    `else wget -q -O ${tmp} ${shellQuote(source.url)}; fi`;
  return [
    `mkdir -p ${shellQuote(dirname(CMUX_TUI_BINARY_PATH))}`,
    `if [ -x ${bin} ] && ${pinned(bin)}; then :; else ` +
      `${fetch} && ${pinned(tmp)} && chmod 755 ${tmp} && mv -f ${tmp} ${bin}; fi`,
    `ln -sfn ${bin} /usr/local/bin/cmux-tui`,
    `${bin} --version`,
  ].join(" && ");
}

/** The daemon command the sandbox supervisor runs. Launch cwd = /root so new terminals open in the persistent home. */
export function cmuxTuiDaemonCommand(): string {
  return `cd /root && env HOME=/root TERM=xterm-256color ${CMUX_TUI_BINARY_PATH} server start --session ${CMUX_TUI_SESSION} --remote-ws 0.0.0.0:${CMUX_TUI_PORT} --remote-ws-insecure-bind`;
}

/** Enrollment invitations are `cmux://enroll/<base64url JSON>`; the id and expiry inside are what the approve flow needs. */
export function parseEnrollmentInvitationUri(uri: string): { id: string; expiresAtUnix: number; daemonFingerprint: string | null } {
  const prefix = "cmux://enroll/";
  if (!uri.startsWith(prefix)) {
    throw new ProviderError("blaxel", "cmux-tui returned an invitation with an unexpected scheme");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(uri.slice(prefix.length), "base64url").toString("utf8"));
  } catch (err) {
    throw new ProviderError("blaxel", "cmux-tui returned an undecodable invitation", err);
  }
  const record = parsed && typeof parsed === "object" ? parsed as Record<string, unknown> : {};
  const id = typeof record.id === "string" ? record.id : "";
  const expiresAtUnix = typeof record.expires_at_unix === "number" ? record.expires_at_unix : 0;
  if (!id || !expiresAtUnix) {
    throw new ProviderError("blaxel", "cmux-tui returned an invitation without an id or expiry");
  }
  return {
    id,
    expiresAtUnix,
    daemonFingerprint: typeof record.daemon_fingerprint === "string" ? record.daemon_fingerprint : null,
  };
}

const ENROLLMENT_ID_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;

export const CMUX_TUI_CLIENT_CAPABILITY_USER_AGENT = "direct-ws-user-agent";

/**
 * The branded machine host (`<machine>.vm.cmux.sh`) sits behind a CloudFront
 * distribution that refuses WebSocket upgrades without a User-Agent (measured
 * 2026-08-26: 403 without, 101 with). cmux-tui clients that send one advertise
 * `direct-ws-user-agent`; every other client gets the raw `<hash>.preview.bl.run`
 * host, which does not enforce it.
 */
export function cmuxTuiPreviewBranded(clientCapabilities: readonly string[] | undefined): boolean {
  return (clientCapabilities ?? []).includes(CMUX_TUI_CLIENT_CAPABILITY_USER_AGENT);
}


function parseJsonObject(text: string): Record<string, unknown> {
  try {
    const value = JSON.parse(text.trim());
    return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

function parseJsonArray(text: string): Array<Record<string, unknown>> {
  try {
    const value = JSON.parse(text.trim());
    return Array.isArray(value)
      ? value.filter((entry): entry is Record<string, unknown> => !!entry && typeof entry === "object")
      : [];
  } catch {
    return [];
  }
}

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
          // Memory is settled before any volume exists: the home's size follows it.
          const homeVolumeMb = resolveHomeVolumeMb(memoryMb);
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
              await timedStep("ensure_home_volume", () => this.ensureHomeVolume(volume, homeVolumeMb));
            }
            try {
              created = await timedStep("create_sandbox", () => blaxelFetch<BlaxelSandbox>("POST", `${CONTROL_PLANE_BASE}/sandboxes`, {
                metadata: { name },
                spec: {
                  runtime: {
                    image,
                    memory: memoryMb,
                    envs: [{ name: "LANG", value: "C.UTF-8" }],
                    ports: sandboxPorts(),
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
          // The daemon previews are minted through the same paths attach uses, so a
          // machine is born at https://<name>.vm.cmux.sh (or <name>-cmux.preview.bl.run)
          // rather than an opaque hash it would then keep for life; the raw preview is
          // the route for clients that cannot pass the branded ingress. Previews live on
          // the control plane and only need the sandbox to exist, so they are created in
          // parallel with the in-sandbox daemon bootstrap.
          // All branches settle before any rollback (allSettled, not all): a
          // fast-failing bootstrap must not start deleting the sandbox while a
          // preview POST is still in flight, or the late preview recreates the
          // orphaned branded route the rollback exists to remove.
          const [bootstrapResult, previewResult, rawPreviewResult] = await Promise.allSettled([
            timedStep("bootstrap_daemon", () => this.bootstrapMachine(name, sandboxUrl)),
            timedStep("ensure_preview", () => this.ensurePreview(name, CMUX_TUI_PREVIEW_NAME, CMUX_TUI_PORT, { branded: true })),
            timedStep("ensure_raw_preview", () => this.ensurePreview(name, CMUX_TUI_RAW_PREVIEW_NAME, CMUX_TUI_PORT, { branded: false })),
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
          if (rawPreviewResult.status === "rejected") {
            await rollback();
            throw rawPreviewResult.reason;
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
              ? { sandboxUrl, previewUrl, homeVolume, homeVolumeMb, image, memoryMb }
              : { sandboxUrl, previewUrl, image, memoryMb },
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("blaxel", `create(${image}) failed`, err);
        }
      },
    );
  }

  // MARK: cmux-tui remote daemon

  /** Create-time bootstrap: the smart-sleep watcher, the cmux-tui daemon, the hostname/VNC chain and background provisioning. */
  private async bootstrapMachine(name: string, sandboxUrl: string): Promise<void> {
    // A just-created sandbox answers 404 ("VM not found") on its API for a few
    // seconds; the first write is the readiness probe and retries instead.
    await this.awaitSandboxApi(name, sandboxUrl, () =>
      blaxelFetch("PUT", `${sandboxUrl}/filesystem/${SMART_SLEEP_PATH}`, { content: SMART_SLEEP_SCRIPT, permissions: "0755" }));
    const prep = await this.sandboxExec(sandboxUrl, `chmod 755 ${SMART_SLEEP_PATH} && mkdir -p /tmp/cmux && chmod 700 /tmp/cmux`);
    if (prep.exitCode !== 0) {
      throw new ProviderError("blaxel", `machine prep in ${name} failed: ${prep.stderr || prep.stdout}`);
    }
    // Everything after the prep is mutually independent: the daemon install/start, the
    // watcher process, the hostname→VNC-heal chain (ordered within itself — the heal only
    // succeeds once the hostname resolves; runtime state, so it re-applies on
    // resurrection too), and the background provision process (agents and dev
    // essentials come with the machine without delaying attach; the .bashrc seed is
    // write-once — /root persists, and a user's edits win).
    await Promise.all([
      timedStep("cmux_tui_bootstrap", () => this.bootstrapCmuxTui(name, sandboxUrl)),
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

  private async awaitSandboxApi<T>(name: string, sandboxUrl: string, call: () => Promise<T>): Promise<T> {
    const deadline = Date.now() + 60_000;
    let lastError: unknown;
    while (Date.now() < deadline) {
      try {
        return await call();
      } catch (err) {
        const notReady = err instanceof ProviderError && /-> 404|VM not found|-> 503/i.test(err.message);
        if (!notReady) throw err;
        lastError = err;
        await new Promise((resolve) => setTimeout(resolve, 1500));
      }
    }
    throw new ProviderError("blaxel", `sandbox API for ${name} did not become reachable`, lastError);
  }

  /** Installs (or re-verifies) the pinned binary and starts the daemon. */
  private async bootstrapCmuxTui(name: string, sandboxUrl: string): Promise<void> {
    const source = await resolveCmuxTuiSource();
    const install = await this.sandboxExec(sandboxUrl, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS);
    if (install.exitCode !== 0) {
      throw new ProviderError("blaxel", `cmux-tui install in ${name} failed: ${install.stderr || install.stdout}`);
    }
    await this.startCmuxTuiProcess(sandboxUrl);
    await this.waitForCmuxTuiReady(name, sandboxUrl);
  }

  private async startCmuxTuiProcess(sandboxUrl: string): Promise<void> {
    await blaxelFetch<BlaxelProcess>("POST", `${sandboxUrl}/process`, {
      name: CMUX_TUI_PROCESS_NAME,
      command: cmuxTuiDaemonCommand(),
      waitForCompletion: false,
      // Not keepAlive: the smart-sleep watcher counts connections on the daemon's port,
      // so an idle machine still drops to standby.
      keepAlive: false,
      restartOnFailure: true,
      maxRestarts: 10,
    });
  }

  private async waitForCmuxTuiReady(name: string, sandboxUrl: string): Promise<void> {
    let last = "";
    for (let attempt = 0; attempt < 15; attempt += 1) {
      const status = await this.cmuxTuiExec(sandboxUrl, `server status --session ${CMUX_TUI_SESSION}`).catch(() => null);
      if (status?.exitCode === 0) return;
      last = status ? (status.stderr || status.stdout) : "status probe failed";
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    throw new ProviderError("blaxel", `cmux-tui daemon in ${name} did not become ready: ${last}`);
  }

  private cmuxTuiExec(sandboxUrl: string, args: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS): Promise<ExecResult> {
    return this.sandboxExec(sandboxUrl, `env HOME=/root ${CMUX_TUI_BINARY_PATH} ${args}`, timeoutMs);
  }

  /** The installed daemon's build identity and remote protocol, so clients can name a mismatch instead of hanging. */
  private async cmuxTuiDaemonBuild(sandboxUrl: string): Promise<CmuxRemoteEndpoint["daemonBuild"] | null> {
    const probe = await this.cmuxTuiExec(sandboxUrl, "remote-probe --json").catch(() => null);
    if (!probe || probe.exitCode !== 0) return null;
    const record = parseJsonObject(probe.stdout);
    const commit = typeof record.build_identity === "string" ? record.build_identity : null;
    const remoteProtocol = typeof record.remote_protocol === "number" ? record.remote_protocol : null;
    const version = typeof record.version === "string" ? record.version : null;
    if (!commit && remoteProtocol === null) return null;
    return { commit, remoteProtocol, version };
  }

  private async ensureCmuxTuiRunning(vmId: string, sandboxUrl: string): Promise<void> {
    const source = await resolveCmuxTuiSource();
    const proc = await blaxelFetch<BlaxelProcess>("GET", `${sandboxUrl}/process/${CMUX_TUI_PROCESS_NAME}`).catch(() => null);
    if (proc?.status !== "running") {
      // The binary lives on the persistent volume, so a resurrected sandbox usually only
      // needs the process started; a pin change or a fresh volume re-runs the install.
      const installed = await this.sandboxExec(
        sandboxUrl,
        `test -x ${shellQuote(CMUX_TUI_BINARY_PATH)} && printf '%s  %s\n' ${shellQuote(source.sha256)} ${shellQuote(CMUX_TUI_BINARY_PATH)} | sha256sum -c >/dev/null 2>&1`,
      ).catch(() => null);
      if (installed?.exitCode !== 0) {
        // Missing, or a different build than the manifest now pins: (re)install.
        await this.bootstrapCmuxTui(vmId, sandboxUrl);
      } else {
        await this.startCmuxTuiProcess(sandboxUrl);
        await this.waitForCmuxTuiReady(vmId, sandboxUrl);
      }
    }
    // Attach = user activity: re-arm the smart-sleep watcher so the sandbox stays awake
    // while this session works, and can freeze again once it goes idle.
    const watcher = await blaxelFetch<BlaxelProcess>("GET", `${sandboxUrl}/process/${SMART_SLEEP_PROCESS_NAME}`).catch(() => null);
    if (watcher?.status !== "running") {
      await this.startWatcherProcess(sandboxUrl);
    }
  }

  /**
   * A status read doubles as the wake request for a sandbox in standby. A persistent-home
   * machine whose sandbox is gone gets resurrected around its volume. "Gone" is either a
   * 404 or a still-listed TERMINATED/DELETING record — Blaxel deletion is asynchronous, so
   * both shapes mean the compute is dead.
   */
  private async liveSandboxForAttach(vmId: string, providerMetadata?: Record<string, unknown>): Promise<BlaxelSandbox> {
    let sandbox: BlaxelSandbox | null = null;
    try {
      const fetched = await this.getSandbox(vmId);
      sandbox = mapStatus(fetched) === "destroyed" ? null : fetched;
    } catch (err) {
      const gone = err instanceof ProviderError && /-> 404/.test(err.message);
      if (!gone) throw err;
    }
    if (!sandbox) {
      sandbox = providerMetadata ? await this.resurrectSandbox(vmId, providerMetadata) : null;
      if (!sandbox) {
        throw new ProviderError("blaxel", `sandbox ${vmId} is gone and has no persistent home to resurrect from`);
      }
    }
    return sandbox;
  }

  async openCmuxRemote(vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_cmux_remote",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "open_cmux_remote", "cmux.vm.id": vmId },
      async (span) => {
        try {
          const sandbox = await this.liveSandboxForAttach(vmId, options?.providerMetadata);
          const sandboxUrl = sandbox.metadata?.url;
          if (!sandboxUrl) {
            throw new Error("sandbox is missing metadata.url");
          }
          await this.ensureCmuxTuiRunning(vmId, sandboxUrl);
          const branded = cmuxTuiPreviewBranded(options?.clientCapabilities);
          const previewUrl = await this.ensurePreview(
            vmId,
            branded ? CMUX_TUI_PREVIEW_NAME : CMUX_TUI_RAW_PREVIEW_NAME,
            CMUX_TUI_PORT,
            { branded },
          );
          span.setAttribute("cmux.vm.cmux_remote.branded", branded);
          const token = await this.mintPreviewToken(vmId, branded ? CMUX_TUI_PREVIEW_NAME : CMUX_TUI_RAW_PREVIEW_NAME);
          const expiresAtUnix = Math.floor(Date.now() / 1000) + PREVIEW_TOKEN_TTL_SECONDS;
          const host = previewUrl.replace(/^https?:\/\//, "").replace(/\/+$/, "");
          // The gateway accepts the preview token as a query parameter and the Rust dialer
          // passes the URL through verbatim, so the tokenized route is the whole story
          // (proven by scripts/spike-cmux-tui-blaxel.sh). It travels only in this response,
          // never inside an invitation.
          const route = `wss://${host}/v1/link?bl_preview_token=${encodeURIComponent(token)}`;

          let invitation: CmuxRemoteEndpoint["invitation"];
          const enrolled = options?.deviceFingerprint
            ? await this.isDeviceEnrolled(sandboxUrl, options.deviceFingerprint)
            : false;
          if (!enrolled) {
            const created = await this.cmuxTuiExec(
              sandboxUrl,
              `remote enroll create --session ${CMUX_TUI_SESSION} --ttl ${CMUX_TUI_INVITATION_TTL_SECONDS} --json`,
            );
            if (created.exitCode !== 0) {
              throw new ProviderError("blaxel", `cmux-tui enrollment invitation in ${vmId} failed: ${created.stderr || created.stdout}`);
            }
            const uri = parseJsonObject(created.stdout).uri;
            if (typeof uri !== "string" || !uri) {
              throw new ProviderError("blaxel", `cmux-tui enrollment invitation in ${vmId} returned no uri`);
            }
            const parsed = parseEnrollmentInvitationUri(uri);
            invitation = { uri, invitationId: parsed.id, expiresAtUnix: parsed.expiresAtUnix };
          }
          span.setAttribute("cmux.vm.cmux_remote.invited", !enrolled);
          const daemonBuild = await this.cmuxTuiDaemonBuild(sandboxUrl);
          return {
            transport: "cmux-remote",
            route,
            token,
            expiresAtUnix,
            session: CMUX_TUI_SESSION,
            ...(daemonBuild ? { daemonBuild } : {}),
            ...(invitation ? { invitation } : {}),
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("blaxel", `openCmuxRemote(${vmId}) failed`, err);
        }
      },
    );
  }

  async approveCmuxRemoteEnrollment(vmId: string, invitationId: string): Promise<CmuxRemoteApprovalResult> {
    return withVmSpan(
      "cmux.vm.provider.approve_cmux_remote_enrollment",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "approve_cmux_remote_enrollment", "cmux.vm.id": vmId },
      async () => {
        if (!ENROLLMENT_ID_PATTERN.test(invitationId)) {
          throw new ProviderError("blaxel", "invitation id has an unexpected shape");
        }
        try {
          const sandboxUrl = await this.sandboxApiUrl(vmId);
          const pending = await this.cmuxTuiExec(sandboxUrl, `remote enroll pending --session ${CMUX_TUI_SESSION} --json`);
          if (pending.exitCode !== 0) {
            throw new ProviderError("blaxel", `cmux-tui pending enrollments in ${vmId} failed: ${pending.stderr || pending.stdout}`);
          }
          const entries = parseJsonArray(pending.stdout);
          const match = entries.find((entry) => entry.invitation_id === invitationId);
          if (!match) {
            // The client has not claimed the invitation yet (or it expired); the caller polls.
            return { approved: false, state: "pending" };
          }
          const approved = await this.cmuxTuiExec(
            sandboxUrl,
            `remote enroll approve ${shellQuote(invitationId)} --session ${CMUX_TUI_SESSION} --json`,
          );
          if (approved.exitCode !== 0) {
            throw new ProviderError("blaxel", `cmux-tui enrollment approval in ${vmId} failed: ${approved.stderr || approved.stdout}`);
          }
          const device = parseJsonObject(approved.stdout);
          const fingerprint = typeof device.fingerprint === "string"
            ? device.fingerprint
            : typeof match.device_fingerprint === "string" ? match.device_fingerprint : undefined;
          return { approved: true, state: "approved", ...(fingerprint ? { deviceFingerprint: fingerprint } : {}) };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("blaxel", `approveCmuxRemoteEnrollment(${vmId}) failed`, err);
        }
      },
    );
  }

  private async isDeviceEnrolled(sandboxUrl: string, fingerprint: string): Promise<boolean> {
    const devices = await this.cmuxTuiExec(sandboxUrl, `remote enroll devices --session ${CMUX_TUI_SESSION} --json`).catch(() => null);
    if (!devices || devices.exitCode !== 0) return false;
    return parseJsonArray(devices.stdout).some((device) =>
      device.fingerprint === fingerprint && (device.revoked_at_unix === null || device.revoked_at_unix === undefined)
    );
  }

  // The daemon itself is NOT keepAlive: while every shell is idle and no client is attached,
  // nothing pins the sandbox and Blaxel freezes it (processes preserved in the memory
  // snapshot). The smart-sleep watcher is the only keepAlive process, and it exits when idle.
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
          "Blaxel sandboxes have no raw TCP ingress, so there is no SSH. " +
            "Blaxel machines attach through the cmux-tui remote daemon (transport cmux-remote).",
        );
      },
    );
  }

  /** The only session transport: the cmux-tui remote daemon (`openCmuxRemote`). */
  readonly attachTransports: readonly AttachTransport[] = ["cmux-remote"];

  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    void options;
    throw new ProviderError(
      "blaxel",
      `openAttach(${vmId}) is not supported: Blaxel machines attach through the cmux-tui remote daemon (transport cmux-remote).`,
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
   * Remove the private previews and stop the cmux-tui daemon before returning;
   * the next authenticated attach recreates both idempotently.
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
          `pkill -TERM -x ${shellQuote(SMART_SLEEP_PROCESS_NAME)} 2>/dev/null || true`,
          `pkill -TERM -f ${shellQuote(`${CMUX_TUI_BINARY_PATH} server start`)} 2>/dev/null || true`,
        ].join("; "),
        15_000,
      );
      if (result.exitCode !== 0) {
        throw new ProviderError(
          "blaxel",
          `revokeEndpointLeases(${vmId}) failed to stop the cmux-tui daemon: ${result.stderr || result.stdout}`,
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

  // A size the volume API rejects surfaces as the provider's own message (non-409
  // responses propagate); there is no silent fallback to a smaller disk.
  private async ensureHomeVolume(name: string, sizeMb: number): Promise<void> {
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
    const memoryMb = resolveMemoryMb(
      typeof metadata.memoryMb === "number" ? metadata.memoryMb : undefined,
    );
    // The volume already exists (409 → steady state); the size only matters if it was lost.
    const homeVolumeMb = typeof metadata.homeVolumeMb === "number" && metadata.homeVolumeMb > 0
      ? metadata.homeVolumeMb
      : resolveHomeVolumeMb(memoryMb);
    await this.ensureHomeVolume(homeVolume, homeVolumeMb);
    const created = await blaxelFetch<BlaxelSandbox>("POST", `${CONTROL_PLANE_BASE}/sandboxes`, {
      metadata: { name: vmId },
      spec: {
        runtime: {
          image,
          memory: memoryMb,
          envs: [{ name: "LANG", value: "C.UTF-8" }],
          ports: sandboxPorts(),
        },
        volumes: [{ name: homeVolume, mountPath: HOME_VOLUME_MOUNT_PATH }],
      },
    });
    const sandboxUrl = created.metadata?.url;
    if (!sandboxUrl) {
      throw new ProviderError("blaxel", `resurrect(${vmId}) returned no sandbox url`);
    }
    await this.bootstrapMachine(vmId, sandboxUrl);
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

  // One in-flight ensure per (machine, preview): a create that races the attach it triggers
  // must not mint the same preview twice. Cross-process races are handled below by re-reading
  // the preview after a failed branded create instead of clobbering it.
  private readonly inflightPreviews = new Map<string, Promise<string>>();

  private ensurePreview(
    vmId: string,
    previewName: string,
    port: number,
    options: { branded?: boolean } = {},
  ): Promise<string> {
    const key = `${vmId}/${previewName}`;
    const inflight = this.inflightPreviews.get(key);
    if (inflight) return inflight;
    const task = this.ensurePreviewUncoalesced(vmId, previewName, port, options.branded !== false).finally(() => {
      this.inflightPreviews.delete(key);
    });
    this.inflightPreviews.set(key, task);
    return task;
  }

  // `branded: false` keeps the preview on Blaxel's own opaque `<hash>.preview.bl.run` host.
  // The cmux-tui daemon has one of each: the branded machine host sits behind an ingress
  // that refuses WebSocket upgrades without a User-Agent, so only clients advertising
  // `direct-ws-user-agent` are routed there (see cmuxTuiPreviewBranded); everything else
  // dials the raw host. Browser-facing port previews keep the branded, cookie-friendly host.
  private async ensurePreviewUncoalesced(vmId: string, previewName: string, port: number, branded = true): Promise<string> {
    const base = `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}/previews`;
    const readExisting = () =>
      blaxelFetch<BlaxelPreview>("GET", `${base}/${previewName}`).catch(() => null);
    const prefixUrl = branded ? brandedPreviewPrefix(vmId, previewName, port) : null;
    const customDomain = prefixUrl ? await verifiedCustomDomain() : null;
    const existing = await readExisting();
    const existingUrl = usablePrivatePreviewUrl(existing);
    if (existingUrl && !branded) {
      // An unbranded preview must not carry a prefix or custom domain; rotate one that does.
      const spec = existing?.spec ?? {};
      const isBranded = !!(spec.prefixUrl?.trim() || spec.customDomain?.trim());
      if (!isBranded) return existingUrl;
      await blaxelFetch("DELETE", `${base}/${previewName}`).catch(() => undefined);
    } else if (existingUrl) {
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

  private async mintPreviewToken(
    vmId: string,
    previewName: string,
    ttlSeconds = PREVIEW_TOKEN_TTL_SECONDS,
  ): Promise<string> {
    const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();
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
        const expiresAtMs = Date.now() + PREVIEW_OPEN_TOKEN_TTL_SECONDS * 1000;
        const token = await this.mintPreviewToken(vmId, previewName, PREVIEW_OPEN_TOKEN_TTL_SECONDS);
        const openUrl = `${url.replace(/\/+$/, "")}/?bl_preview_token=${encodeURIComponent(token)}`;
        return { url, token, openUrl, expiresAtMs };
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

// The machine's bare name is its daemon address (`<machine>.vm.cmux.sh`); port previews
// hang off it as `<machine>-<port>`.
export function brandedPreviewPrefix(vmId: string, previewName: string, port: number): string | null {
  const machine = vmId.toLowerCase();
  if (!/^[a-z0-9][a-z0-9-]{0,40}$/.test(machine)) return null;
  const prefix = previewName === CMUX_TUI_PREVIEW_NAME ? machine : `${machine}-${port}`;
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

export function sandboxPorts(): Array<{ name: string; protocol: "HTTP"; target: number }> {
  return [{ name: CMUX_TUI_PREVIEW_NAME, protocol: "HTTP", target: CMUX_TUI_PORT }];
}

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
