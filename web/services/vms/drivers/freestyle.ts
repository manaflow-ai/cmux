import { Freestyle } from "freestyle";
import { createHash, createPrivateKey, createPublicKey, randomBytes, sign, verify } from "node:crypto";
import {
  ProviderError,
  type AttachOptions,
  type CreateOptions,
  type ExecResult,
  type AttachEndpoint,
  type SSHEndpoint,
  type WebSocketPtyEndpoint,
  type SnapshotRef,
  type VMHandle,
  type VMProvider,
  type VMStatus,
} from "./types";
import {
  recordSpanError,
  setSpanAttributes,
  withVmSpan,
} from "../telemetry";
import { isProviderIdentityNotFoundError } from "../providerErrors";
import {
  isReusableRpcLease,
  ensurePrivateDirectoryCommand,
  leaseClientMetadata,
  makeWebSocketAttachmentId,
  makeWebSocketLease,
  shellArgValue,
  shellQuote,
  type ReusableRpcLease,
} from "./wsLease";

// Freestyle VMs reach the outside world only via their SSH gateway, which terminates on
// `vm-ssh.freestyle.sh:22`. `ssh <vmId>+<user>@vm-ssh.freestyle.sh` authenticates against
// an identity token the backend mints per attach session (short TTL, revoked on rm).
const SSH_HOST = "vm-ssh.freestyle.sh";
const SSH_PORT = 22;
const CMUX_LINUX_USER = "cmux"; // must match Resources/install.sh in scratch/vm-experiments
const CMUXD_WS_PTY_LEASE_PATH = "/tmp/cmux/attach-pty-lease.json";
const CMUXD_WS_LEGACY_PTY_LEASE_PATH = "/tmp/cmux/attach-lease.json";
const CMUXD_WS_RPC_CLIENT_PATH = "/tmp/cmux/attach-rpc-client.json";
const CMUXD_WS_RPC_LEASE_PATH = "/tmp/cmux/attach-rpc-lease.json";
const CMUXD_WS_PTY_LEASE_TTL_SECONDS = 5 * 60;
const CMUXD_WS_RPC_LEASE_TTL_SECONDS = 12 * 60 * 60;
const CMUXD_WS_RPC_RENEW_BEFORE_SECONDS = 60;
const FREESTYLE_WS_PORTS = [{ port: 443, targetPort: 7777 }];
const FREESTYLE_DAEMON_ADMIN_TOKEN_METADATA_KEY = "freestyleDaemonAdminToken";
const CMUX_CLOUD_SHELL_PATH = "/usr/local/bin/cmux-cloud-shell";

const DEFAULT_TIMEOUT_MS = 60_000;
const CREATE_TIMEOUT_MS = 15 * 60 * 1000;
const SNAPSHOT_TIMEOUT_MS = 15 * 60 * 1000;
const EXEC_OVERHEAD_TIMEOUT_MS = 15_000;
const MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000;

function client(timeoutMs = DEFAULT_TIMEOUT_MS): Freestyle {
  const longFetch: typeof fetch = (input, init) =>
    fetch(input as Request, { ...(init ?? {}), signal: AbortSignal.timeout(timeoutMs) });
  return new Freestyle({ fetch: longFetch });
}

function normalizeExecTimeout(timeoutMs: number | undefined): number {
  if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return 30_000;
  }
  return Math.min(Math.floor(timeoutMs), MAX_EXEC_TIMEOUT_MS);
}

function mapStatus(state: string | null | undefined): VMStatus {
  switch (state) {
    case "starting":
      return "creating";
    case "running":
      return "running";
    case "suspending":
    case "suspended":
      return "paused";
    case "stopped":
      return "destroyed";
    default:
      return "running";
  }
}

export class FreestyleProvider implements VMProvider {
  readonly id = "freestyle" as const;

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image.trim();
    if (!image) {
      throw new ProviderError("freestyle", "create requires a resolved image");
    }
    const signedAdmin = freestyleAdminSigningConfig();
    if (options.bakedFreestyleSignedAdmin === true && !signedAdmin) {
      throw new ProviderError(
        "freestyle",
        "create requires CMUX_FREESTYLE_ADMIN_SIGNING_PRIVATE_KEY_SEED and CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY for this Cloud VM image",
      );
    }
    const adminToken = signedAdmin
      ? null
      : freestyleDaemonAdminToken(options.providerMetadata)
        ?? `cmux-freestyle-admin-${randomBytes(32).toString("hex")}`;
    const providerMetadata = adminToken
      ? {
        ...(options.providerMetadata ?? {}),
        [FREESTYLE_DAEMON_ADMIN_TOKEN_METADATA_KEY]: adminToken,
      }
      : { ...(options.providerMetadata ?? {}) };
    return withVmSpan(
      "cmux.vm.provider.create",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "create",
        "cmux.vm.image": image,
        "cmux.timeout_ms": CREATE_TIMEOUT_MS,
      },
      async (span) => {
        const fs = client(CREATE_TIMEOUT_MS);
        try {
          // Build images can take several minutes if the snapshot cache misses.
          const createRequest: Parameters<typeof fs.vms.create>[0] = {
            snapshotId: image,
            ports: FREESTYLE_WS_PORTS,
            readySignalTimeoutSeconds: 600,
          };
          if (adminToken && options.bakedFreestyleSignedAdmin !== true) {
            createRequest.systemd = {
              services: [freestyleWebSocketService(adminToken)],
            };
          }
          const created = await fs.vms.create(createRequest);
          setSpanAttributes(span, { "cmux.vm.id": created.vmId });
          return {
            provider: "freestyle",
            providerVmId: created.vmId,
            status: "running",
            image,
            createdAt: Date.now(),
            providerMetadata,
          };
        } catch (err) {
          throw new ProviderError("freestyle", `create(${image})`, err);
        }
      },
    );
  }

  async destroy(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.destroy",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "destroy",
        "cmux.vm.id": vmId,
        "cmux.timeout_ms": DEFAULT_TIMEOUT_MS,
      },
      async () => {
        try {
          const fs = client();
          const ref = fs.vms.ref({ vmId });
          await ref.delete();
        } catch (err) {
          throw new ProviderError("freestyle", `destroy(${vmId})`, err);
        }
      },
    );
  }

  async getStatus(vmId: string): Promise<VMStatus> {
    return withVmSpan(
      "cmux.vm.provider.get_status",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "get_status",
        "cmux.vm.id": vmId,
        "cmux.timeout_ms": DEFAULT_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const info = await client().vms.ref({ vmId }).getInfo();
          const status = mapStatus(info.state);
          setSpanAttributes(span, { "cmux.vm.provider_state": info.state, "cmux.vm.status": status });
          return status;
        } catch (err) {
          throw new ProviderError("freestyle", `getStatus(${vmId})`, err);
        }
      },
    );
  }

  async pause(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.pause",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "pause",
        "cmux.vm.id": vmId,
        "cmux.timeout_ms": DEFAULT_TIMEOUT_MS,
      },
      async () => {
        try {
          const fs = client();
          const ref = fs.vms.ref({ vmId });
          await ref.suspend();
        } catch (err) {
          throw new ProviderError("freestyle", `pause(${vmId})`, err);
        }
      },
    );
  }

  async resume(vmId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.resume",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "resume",
        "cmux.vm.id": vmId,
        "cmux.timeout_ms": DEFAULT_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const fs = client();
          const ref = fs.vms.ref({ vmId });
          await ref.start();
          const info = await ref.getInfo();
          const status = mapStatus(info.state);
          setSpanAttributes(span, { "cmux.vm.provider_state": info.state, "cmux.vm.status": status });
          return {
            provider: "freestyle",
            providerVmId: info.id,
            status,
            image: "freestyle:resumed",
            createdAt: Date.now(),
          };
        } catch (err) {
          throw new ProviderError("freestyle", `resume(${vmId})`, err);
        }
      },
    );
  }

  async exec(
    vmId: string,
    command: string,
    opts?: { timeoutMs?: number },
  ): Promise<ExecResult> {
    const timeoutMs = normalizeExecTimeout(opts?.timeoutMs);
    return withVmSpan(
      "cmux.vm.provider.exec",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "exec",
        "cmux.vm.id": vmId,
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      },
      async (span) => {
        try {
          const fs = client(timeoutMs + EXEC_OVERHEAD_TIMEOUT_MS);
          const ref = fs.vms.ref({ vmId });
          const r = await ref.exec({ command, timeoutMs });
          const exitCode = (r as { statusCode?: number }).statusCode ?? 0;
          setSpanAttributes(span, { "cmux.exec.exit_code": exitCode });
          // ResponsePostV1VmsVmIdExecAwait200 shape: { stdout, stderr, statusCode }
          return {
            exitCode,
            stdout: (r as { stdout?: string | null }).stdout ?? "",
            stderr: (r as { stderr?: string | null }).stderr ?? "",
          };
        } catch (err) {
          throw new ProviderError("freestyle", `exec(${vmId})`, err);
        }
      },
    );
  }

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    return withVmSpan(
      "cmux.vm.provider.snapshot",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "snapshot",
        "cmux.vm.id": vmId,
        "cmux.snapshot.named": !!name,
        "cmux.timeout_ms": SNAPSHOT_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const fs = client(SNAPSHOT_TIMEOUT_MS);
          const ref = fs.vms.ref({ vmId });
          const out = await ref.snapshot(name ? { name } : undefined);
          const id =
            (out as { snapshotId?: string }).snapshotId ??
            (out as { id?: string }).id ??
            "";
          if (!id) throw new Error("snapshot response missing snapshotId");
          setSpanAttributes(span, { "cmux.snapshot.id": id });
          return { id, createdAt: Date.now(), name };
        } catch (err) {
          throw new ProviderError("freestyle", `snapshot(${vmId})`, err);
        }
      },
    );
  }

  async restore(snapshotId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.restore",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "restore",
        "cmux.snapshot.id": snapshotId,
        "cmux.timeout_ms": CREATE_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const fs = client(CREATE_TIMEOUT_MS);
          const signedAdmin = freestyleAdminSigningConfig();
          const adminToken = signedAdmin ? null : `cmux-freestyle-admin-${randomBytes(32).toString("hex")}`;
          const createRequest: Parameters<typeof fs.vms.create>[0] = {
            snapshotId,
            ports: FREESTYLE_WS_PORTS,
            readySignalTimeoutSeconds: 600,
          };
          if (adminToken) {
            createRequest.systemd = {
              services: [freestyleWebSocketService(adminToken)],
            };
          }
          const created = await fs.vms.create(createRequest);
          setSpanAttributes(span, { "cmux.vm.id": created.vmId });
          return {
            provider: "freestyle",
            providerVmId: created.vmId,
            status: "running",
            image: snapshotId,
            createdAt: Date.now(),
            providerMetadata: adminToken ? {
              [FREESTYLE_DAEMON_ADMIN_TOKEN_METADATA_KEY]: adminToken,
            } : {},
          };
        } catch (err) {
          throw new ProviderError("freestyle", `restore(${snapshotId})`, err);
        }
      },
    );
  }

  async fork(vmId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.fork",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "fork",
        "cmux.vm.id": vmId,
        "cmux.timeout_ms": SNAPSHOT_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const fs = client(SNAPSHOT_TIMEOUT_MS);
          const ref = fs.vms.ref({ vmId });
          const out = await ref.fork({ count: 1 });
          const fork = out.forks[0];
          if (!fork) throw new Error("fork response contained no child VM");
          const info = await fork.vm.getInfo();
          const status = mapStatus(info.state);
          setSpanAttributes(span, {
            "cmux.vm.fork_id": fork.vmId,
            "cmux.vm.provider_state": info.state,
            "cmux.vm.status": status,
          });
          return {
            provider: "freestyle",
            providerVmId: fork.vmId,
            status,
            image: "freestyle:fork",
            createdAt: Date.now(),
          };
        } catch (err) {
          throw new ProviderError("freestyle", `fork(${vmId})`, err);
        }
      },
    );
  }

  /**
   * Prefer the baked cmuxd WebSocket daemon. Older VMs without an exposed 443 -> 7777 port
   * still fall back to Freestyle SSH, but the mac client must treat that as shell-only.
   */
  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    try {
      const endpoint = await this.openWebSocketPty(vmId, options);
      if (options?.requireDaemon && !endpoint.daemon) {
        throw new ProviderError(
          "freestyle",
          `openAttach(${vmId}) requires a cmuxd RPC endpoint, but this VM snapshot only exposes the PTY WebSocket. Rebuild it with the current cmuxd-remote snapshot.`,
        );
      }
      return endpoint;
    } catch (err) {
      if (options?.requireDaemon) {
        throw err;
      }
      if (!shouldFallbackAttachToSSH(err)) {
        throw err;
      }
      return await withVmSpan(
        "cmux.vm.provider.open_attach_ssh_fallback",
        {
          "cmux.vm.provider": "freestyle",
          "cmux.vm.operation": "open_attach_ssh_fallback",
          "cmux.vm.id": vmId,
          "cmux.vm.attach.require_daemon": options?.requireDaemon === true,
        },
        async (span) => {
          recordSpanError(span, err);
          setSpanAttributes(span, { "cmux.vm.attach.fallback": "ssh" });
          return await this.openSSH(vmId);
        },
      );
    }
  }

  async openWebSocketPty(vmId: string, options?: AttachOptions): Promise<WebSocketPtyEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_websocket_pty",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "open_websocket_pty",
        "cmux.vm.id": vmId,
      },
      async (span) => {
        try {
          const fs = client();
          const vm = fs.vms.ref({ vmId });
          const domain = `${vmId}.vm.freestyle.sh`;
          const pty = makeWebSocketLease("freestyle", "pty", true, CMUXD_WS_PTY_LEASE_TTL_SECONDS, options?.sessionId);
          const attachmentId = options?.attachmentId?.trim() || makeWebSocketAttachmentId("freestyle");
          let daemon: ReusableRpcLease | null = null;
          let daemonReused = false;
          const adminToken = freestyleDaemonAdminToken(options?.providerMetadata);
          const signedAdmin = freestyleAdminSigningConfig();
          await ensureFreestyleWebSocketHealthyOrRepair(domain, vm, adminToken, signedAdmin);
          if (adminToken || signedAdmin) {
            const daemonLease = makeWebSocketLease("freestyle", "rpc", false, CMUXD_WS_RPC_LEASE_TTL_SECONDS);
            daemon = daemonLease;
            await installFreestyleLeasesViaDaemon(domain, adminToken ? { kind: "bearer", token: adminToken } : {
              kind: "ed25519",
              privateKeySeed: signedAdmin!.privateKeySeed,
              publicKey: signedAdmin!.publicKey,
            }, {
              ptyLease: pty.lease,
              rpcLease: daemonLease.lease,
              rpcClient: leaseClientMetadata(daemonLease),
            });
          } else {
            const service = await readFreestyleWebSocketService(vm);
            const encodedPTY = Buffer.from(JSON.stringify(pty.lease)).toString("base64");
            const commands = [
              ensurePrivateDirectoryCommand(service.ptyLeasePath),
              `printf '%s' '${encodedPTY}' | base64 -d > ${shellQuote(service.ptyLeasePath)}`,
              `chmod 600 ${shellQuote(service.ptyLeasePath)}`,
            ];
            if (service.rpcLeasePath) {
              const existingDaemon = await readReusableRpcLease(vm, service.rpcLeasePath);
              const newDaemon = existingDaemon
                ? null
                : makeWebSocketLease("freestyle", "rpc", false, CMUXD_WS_RPC_LEASE_TTL_SECONDS);
              daemon = existingDaemon ?? newDaemon!;
              daemonReused = !!existingDaemon;
              if (newDaemon) {
                const encodedDaemon = Buffer.from(JSON.stringify(newDaemon.lease)).toString("base64");
                const encodedDaemonClient = Buffer.from(JSON.stringify(leaseClientMetadata(newDaemon))).toString("base64");
                commands.push(
                  ensurePrivateDirectoryCommand(service.rpcLeasePath),
                  `printf '%s' '${encodedDaemon}' | base64 -d > ${shellQuote(service.rpcLeasePath)}`,
                  `chmod 600 ${shellQuote(service.rpcLeasePath)}`,
                  `printf '%s' '${encodedDaemonClient}' | base64 -d > ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
                  `chmod 600 ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
                );
              }
            }
            await execFreestyleOrThrow(vm, commands.join(" && "));
          }
          span.setAttribute("cmux.vm.attach.transport", "websocket");
          span.setAttribute("cmux.vm.attach.expires_at_unix", pty.expiresAtUnix);
          span.setAttribute("cmux.vm.attach.daemon_available", !!daemon);
          if (daemon) {
            span.setAttribute("cmux.vm.attach.daemon_expires_at_unix", daemon.expiresAtUnix);
            span.setAttribute("cmux.vm.attach.daemon_reused", daemonReused);
          }
          return {
            transport: "websocket",
            url: `wss://${domain}/terminal`,
            headers: {},
            token: pty.token,
            sessionId: pty.sessionId,
            attachmentId,
            expiresAtUnix: pty.expiresAtUnix,
            daemon: daemon ? {
              url: `wss://${domain}/rpc`,
              headers: {},
              token: daemon.token,
              sessionId: daemon.sessionId,
              expiresAtUnix: daemon.expiresAtUnix,
            } : undefined,
          };
        } catch (err) {
          throw new ProviderError("freestyle", `openWebSocketPty(${vmId})`, err);
        }
      },
    );
  }

  private async openReusableRpcDaemon(vmId: string): Promise<WebSocketPtyEndpoint["daemon"] | undefined> {
    const fs = client();
    const vm = fs.vms.ref({ vmId });
    const service = await readFreestyleWebSocketService(vm);
    if (!service.rpcLeasePath) {
      return undefined;
    }
    const existingDaemon = await readReusableRpcLease(vm, service.rpcLeasePath);
    const newDaemon = existingDaemon
      ? null
      : makeWebSocketLease("freestyle", "rpc", false, CMUXD_WS_RPC_LEASE_TTL_SECONDS);
    const daemon = existingDaemon ?? newDaemon!;
    if (newDaemon) {
      const encodedDaemon = Buffer.from(JSON.stringify(newDaemon.lease)).toString("base64");
      const encodedDaemonClient = Buffer.from(JSON.stringify(leaseClientMetadata(newDaemon))).toString("base64");
      await execFreestyleOrThrow(
        vm,
        [
          ensurePrivateDirectoryCommand(service.rpcLeasePath),
          `printf '%s' '${encodedDaemon}' | base64 -d > ${shellQuote(service.rpcLeasePath)}`,
          `chmod 600 ${shellQuote(service.rpcLeasePath)}`,
          `printf '%s' '${encodedDaemonClient}' | base64 -d > ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
          `chmod 600 ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
        ].join(" && "),
      );
    }
    return {
      url: `wss://${vmId}.vm.freestyle.sh/rpc`,
      headers: {},
      token: daemon.token,
      sessionId: daemon.sessionId,
      expiresAtUnix: daemon.expiresAtUnix,
    };
  }

  /**
   * Mint a short-lived SSH token + permission scoped to this VM, return the endpoint the mac
   * client will dial. Freestyle's gateway terminates at `vm-ssh.freestyle.sh:22`, username is
   * `<vmId>+<linuxUser>`, password is the access token we just minted.
   */
  async openSSH(vmId: string): Promise<SSHEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_ssh",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "open_ssh",
        "cmux.vm.id": vmId,
        "cmux.timeout_ms": DEFAULT_TIMEOUT_MS,
      },
      async (span) => {
        const fs = client();
        // A fresh identity per attach session. The VM workflow persists the identityId so it can
        // call `revokeSSHIdentity` on VM destroy / before minting a replacement, otherwise
        // every `cmux vm shell` invocation would leak a live credential under the Freestyle
        // account indefinitely.
        let identity: Awaited<ReturnType<typeof fs.identities.create>>["identity"] | undefined;
        let identityId = "";
        try {
          const created = await fs.identities.create({});
          identity = created.identity;
          identityId = created.identityId;
          setSpanAttributes(span, { "cmux.ssh.identity_created": true });
          await identity.permissions.vms.grant({
            vmId,
            allowedUsers: [CMUX_LINUX_USER],
          });
          const { token } = await identity.tokens.create();
          let daemon: WebSocketPtyEndpoint["daemon"] | undefined;
          try {
            daemon = await this.openReusableRpcDaemon(vmId);
          } catch (daemonErr) {
            recordSpanError(span, daemonErr);
          }
          return {
            transport: "ssh",
            host: SSH_HOST,
            port: SSH_PORT,
            username: `${vmId}+${CMUX_LINUX_USER}`,
            publicKeyFingerprint: null,
            credential: { kind: "password", value: token },
            daemon,
            identityHandle: identityId,
          };
        } catch (err) {
          // Without this, an identity created above but failed-on afterwards (grant or token
          // mint threw) leaks. Best-effort delete before rethrowing.
          if (identityId) {
            try {
              await fs.identities.delete({ identityId });
            } catch (cleanupError) {
              recordSpanError(span, cleanupError);
            }
          }
          throw new ProviderError("freestyle", `openSSH(${vmId})`, err);
        }
      },
    );
  }

  async revokeSSHIdentity(identityHandle: string): Promise<void> {
    if (!identityHandle) return;
    await withVmSpan(
      "cmux.vm.provider.revoke_ssh_identity",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "revoke_ssh_identity",
        "cmux.timeout_ms": DEFAULT_TIMEOUT_MS,
      },
      async (span) => {
        try {
          await client().identities.delete({ identityId: identityHandle });
        } catch (err) {
          if (isProviderIdentityNotFoundError(err)) return;
          recordSpanError(span, err);
          throw new ProviderError("freestyle", `revokeSSHIdentity(${identityHandle})`, err);
        }
      },
    );
  }
}

function shouldFallbackAttachToSSH(err: unknown): boolean {
  const messages = [errorMessage(err)];
  if (err instanceof ProviderError && err.cause) {
    messages.push(errorMessage(err.cause));
  }
  return messages.some((message) =>
    message.includes("requires a cmuxd RPC endpoint")
    || message.includes("Freestyle cmuxd websocket health check returned")
    || message.includes("Freestyle cmuxd websocket health check failed")
  );
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function freestyleDaemonAdminToken(metadata: Record<string, unknown> | undefined): string | null {
  const value = metadata?.[FREESTYLE_DAEMON_ADMIN_TOKEN_METADATA_KEY];
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function sha256Hex(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

type FreestyleAdminAuth =
  | { kind: "bearer"; token: string }
  | { kind: "ed25519"; privateKeySeed: Buffer; publicKey: Buffer };

type FreestyleAdminSigningConfig = { privateKeySeed: Buffer; publicKey: Buffer };

function freestyleAdminSigningConfig(): FreestyleAdminSigningConfig | null {
  const seedRaw = process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PRIVATE_KEY_SEED?.trim();
  const publicRaw = process.env.CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY?.trim();
  if (!seedRaw && !publicRaw) return null;
  if (!seedRaw || !publicRaw) {
    throw new Error(
      "CMUX_FREESTYLE_ADMIN_SIGNING_PRIVATE_KEY_SEED and CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY must be set together",
    );
  }
  const privateKeySeed = decodeBase64Bytes(seedRaw);
  const publicKey = decodeBase64Bytes(publicRaw);
  if (privateKeySeed.length !== 32) {
    throw new Error("CMUX_FREESTYLE_ADMIN_SIGNING_PRIVATE_KEY_SEED must decode to 32 bytes");
  }
  if (publicKey.length !== 32) {
    throw new Error("CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY must decode to 32 bytes");
  }
  const auth = { kind: "ed25519" as const, privateKeySeed, publicKey };
  const probe = Buffer.from("cmux-freestyle-admin-signing-config");
  const signature = Buffer.from(signAdminLeaseBody(auth, probe.toString("utf8")), "base64");
  if (!verify(null, probe, ed25519PublicKeyFromRaw(publicKey), signature)) {
    throw new Error(
      "CMUX_FREESTYLE_ADMIN_SIGNING_PRIVATE_KEY_SEED does not match CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY",
    );
  }
  return { privateKeySeed, publicKey };
}

function decodeBase64Bytes(value: string): Buffer {
  return Buffer.from(value.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

function base64url(bytes: Buffer): string {
  return bytes.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/u, "");
}

function signAdminLeaseBody(auth: Extract<FreestyleAdminAuth, { kind: "ed25519" }>, body: string): string {
  const privateKey = createPrivateKey({
    format: "jwk",
    key: {
      kty: "OKP",
      crv: "Ed25519",
      d: base64url(auth.privateKeySeed),
      x: base64url(auth.publicKey),
    },
  });
  return sign(null, Buffer.from(body), privateKey).toString("base64");
}

function ed25519PublicKeyFromRaw(publicKey: Buffer) {
  return createPublicKey({
    format: "jwk" as const,
    key: {
      kty: "OKP",
      crv: "Ed25519",
      x: base64url(publicKey),
    },
  });
}

function freestyleWebSocketService(adminToken: string) {
  return {
    name: "cmuxd-ws",
    mode: "service" as const,
    user: "root",
    after: ["network.target"],
    env: {
      CMUXD_WS_ADMIN_TOKEN_SHA256: sha256Hex(adminToken),
    },
    exec: [
      [
        "/usr/local/bin/cmuxd-remote",
        "serve",
        "--ws",
        "--listen",
        "0.0.0.0:7777",
        "--auth-lease-file",
        CMUXD_WS_PTY_LEASE_PATH,
        "--rpc-auth-lease-file",
        CMUXD_WS_RPC_LEASE_PATH,
        "--shell",
        CMUX_CLOUD_SHELL_PATH,
      ].map(shellQuote).join(" "),
    ],
  };
}

function repairedFreestyleWebSocketService(
  auth: { readonly adminToken?: string | null; readonly publicKey?: string | null },
): string {
  const env = auth.publicKey
    ? `Environment=CMUXD_WS_ADMIN_ED25519_PUBLIC_KEY=${auth.publicKey}`
    : `Environment=CMUXD_WS_ADMIN_TOKEN_SHA256=${sha256Hex(auth.adminToken ?? "")}`;
  return `[Unit]
Description=cmux remote WebSocket daemon
After=network.target

[Service]
Type=simple
User=root
${env}
ExecStart=/usr/local/bin/cmuxd-remote serve --ws --listen 0.0.0.0:7777 --auth-lease-file ${CMUXD_WS_PTY_LEASE_PATH} --rpc-auth-lease-file ${CMUXD_WS_RPC_LEASE_PATH} --shell /usr/local/bin/cmux-cloud-shell
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
`;
}

async function ensureFreestyleWebSocketHealthyOrRepair(
  domain: string,
  vm: FreestyleVmRef,
  adminToken: string | null,
  signedAdmin: FreestyleAdminSigningConfig | null,
): Promise<void> {
  const canRepair = !!adminToken || !!signedAdmin;
  let healthError: unknown = null;
  try {
    await ensureFreestyleWebSocketHealthy(domain);
  } catch (err) {
    healthError = err;
  }

  if (!healthError && canRepair) {
    const state = await readFreestyleCloudShellState(vm).catch(() => null);
    if (!state) {
      // The daemon/admin websocket is the attach control plane. Freestyle exec
      // can be temporarily unavailable on otherwise attachable VMs, so do not
      // block lease installation on this shell-integration probe.
      return;
    }
    if (!state.ok) {
      await repairFreestyleWebSocketService(vm, adminToken, signedAdmin).catch((repairErr: unknown) => {
        throw new Error(
          `Cloud VM terminal service shell repair failed (${state.reason}): ${errorMessage(repairErr)}`,
        );
      });
      await waitForFreestyleWebSocketHealthy(domain);
    }
    return;
  }

  if (healthError) {
    if (!canRepair) {
      throw healthError;
    }
    await repairFreestyleWebSocketService(vm, adminToken, signedAdmin).catch((repairErr: unknown) => {
      throw new Error(
        `Cloud VM terminal service repair failed after health check failed (${errorMessage(healthError)}): ${errorMessage(repairErr)}`,
      );
    });
    await waitForFreestyleWebSocketHealthy(domain).catch((healthErr: unknown) => {
      throw new Error(
        `Cloud VM terminal service stayed unavailable after repair (${errorMessage(healthError)}): ${errorMessage(healthErr)}`,
      );
    });
  }
}

async function repairFreestyleWebSocketService(
  vm: FreestyleVmRef,
  adminToken: string | null,
  signedAdmin: FreestyleAdminSigningConfig | null,
): Promise<void> {
  const service = repairedFreestyleWebSocketService({
    adminToken,
    publicKey: signedAdmin?.publicKey.toString("base64") ?? null,
  });
  const encodedService = Buffer.from(service).toString("base64");
  const commands = [
    ...freestyleCloudShellSetupCommands(),
    "mkdir -p /tmp/cmux /usr/local/bin /etc/systemd/system /etc/systemd/system/multi-user.target.wants",
    "chmod 700 /tmp/cmux",
    `printf '%s' '${encodedService}' | base64 -d > /etc/systemd/system/cmuxd-ws.service`,
    "ln -sf /etc/systemd/system/cmuxd-ws.service /etc/systemd/system/multi-user.target.wants/cmuxd-ws.service",
    "(systemctl daemon-reload >/dev/null 2>&1 || true)",
    "(systemctl enable cmuxd-ws >/dev/null 2>&1 || true)",
    "(systemctl restart cmuxd-ws >/dev/null 2>&1 || systemctl start cmuxd-ws >/dev/null 2>&1 || true)",
  ];
  await execFreestyleCommandsOrThrow(vm, commands, 180_000);
}

function freestyleCloudShellSetupCommands(): string[] {
  return [
    "export PATH=\"/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}\"",
    "if command -v apt-get >/dev/null 2>&1 && { ! command -v zsh >/dev/null 2>&1 || ! command -v gh >/dev/null 2>&1 || ! command -v htop >/dev/null 2>&1 || ! command -v btop >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; }; then apt-get update >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y zsh zsh-autosuggestions gh htop btop tmux >/dev/null 2>&1 || true; fi",
    "id -u cmux >/dev/null 2>&1 || useradd -m -s \"$(command -v zsh 2>/dev/null || printf /bin/bash)\" cmux",
    "printf 'cmux ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/90-cmux-nopasswd 2>/dev/null || true",
    "chmod 0440 /etc/sudoers.d/90-cmux-nopasswd 2>/dev/null || true",
    "mkdir -p /etc/cmux /home/cmux/.config/cmux /home/cmux/.cmux /tmp/cmux /usr/local/bin",
    "chmod 700 /tmp/cmux",
    "chown cmux:cmux /tmp/cmux /home/cmux/.config /home/cmux/.config/cmux /home/cmux/.cmux 2>/dev/null || true",
    "if [ ! -x /usr/local/bin/cmux ] && [ -x /usr/local/bin/cmuxd-remote ]; then ln -sf /usr/local/bin/cmuxd-remote /usr/local/bin/cmux >/dev/null 2>&1 || true; fi",
    "cat > /etc/cmux/zshrc <<'CMUX_ZSHRC'\n# cmux default zsh profile. Put personal overrides in ~/.zshrc.local.\nexport PATH=\"/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}\"\nexport SHELL=\"$(command -v zsh 2>/dev/null || printf /bin/bash)\"\nmkdir -p \"$HOME/.cmux\" 2>/dev/null || true\nprintf '%s' '/tmp/cmux-cloud-cli.sock' > \"$HOME/.cmux/socket_addr\" 2>/dev/null || true\nexport CMUX_SOCKET_PATH=\"${CMUX_SOCKET_PATH:-/tmp/cmux-cloud-cli.sock}\"\nautoload -Uz colors 2>/dev/null && colors\nsetopt prompt_subst interactivecomments no_beep hist_ignore_dups share_history 2>/dev/null || true\nPROMPT_EOL_MARK=''\nunsetopt prompt_sp 2>/dev/null || true\nHISTFILE=\"${HISTFILE:-$HOME/.zsh_history}\"\nHISTSIZE=\"${HISTSIZE:-50000}\"\nSAVEHIST=\"${SAVEHIST:-50000}\"\nbindkey -e 2>/dev/null || true\nif [ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then\n  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh\n  ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE=\"${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE:-fg=8}\"\nfi\n: ${CMUX_PROMPT_USER:=cmux-cloud}\n: ${CMUX_PROMPT_CHAR:=$'\\u03bb'}\nPROMPT='%F{magenta}${CMUX_PROMPT_USER}%f in %F{green}%~%f ${CMUX_PROMPT_CHAR} '\nCMUX_ZSHRC",
    "if [ ! -e /home/cmux/.zshrc ] || grep -q \"cmux-managed zsh defaults\" /home/cmux/.zshrc 2>/dev/null; then cat > /home/cmux/.zshrc <<'CMUX_USER_ZSHRC'\n# cmux-managed zsh defaults. Edit ~/.zshrc.local for personal overrides.\nmkdir -p \"$HOME/.cmux\" 2>/dev/null || true\nprintf '%s' '/tmp/cmux-cloud-cli.sock' > \"$HOME/.cmux/socket_addr\" 2>/dev/null || true\nexport CMUX_SOCKET_PATH=\"${CMUX_SOCKET_PATH:-/tmp/cmux-cloud-cli.sock}\"\n[ -r /etc/cmux/zshrc ] && source /etc/cmux/zshrc\n[ -r \"$HOME/.zshrc.local\" ] && source \"$HOME/.zshrc.local\"\nif [ \"${CMUX_CLOUD_WELCOME:-1}\" != \"0\" ] && [ -z \"${CMUX_CLOUD_WELCOME_SHOWN:-}\" ] && [ -t 1 ]; then\n  export CMUX_CLOUD_WELCOME_SHOWN=1\n  printf '\\033[38;2;0;212;255m  ::\\033[0m\\n'\n  printf '\\033[38;2;24;181;250m    ::::              \\033[38;2;0;212;255mc\\033[38;2;24;181;250mm\\033[38;2;48;150;245mu\\033[38;2;124;58;237mx cloud\\033[0m\\n'\n  printf '\\033[38;2;48;150;245m      ::::::\\033[0m\\n'\n  printf '\\033[38;2;72;119;241m        ::::::\\033[0m        \\033[38;2;130;130;140mpersistent cloud VM\\033[0m\\n'\n  printf '\\033[38;2;96;88;239m      ::::::\\033[0m          \\033[38;2;130;130;140mready for coding agents\\033[0m\\n'\n  printf '\\033[38;2;110;73;238m    ::::\\033[0m\\n'\n  printf '\\033[38;2;124;58;237m  ::\\033[0m\\n'\n  printf '\\n'\nfi\nCMUX_USER_ZSHRC\nfi",
    "if [ ! -e /home/cmux/.zshrc.local ]; then cat > /home/cmux/.zshrc.local <<'CMUX_LOCAL_ZSHRC'\n# Personal zsh overrides for this cloud VM.\n# Examples:\n#   CMUX_CLOUD_WELCOME=0\n#   CMUX_PROMPT_USER='cmux-cloud'\n#   CMUX_PROMPT_CHAR='>'\n#   PROMPT='%F{cyan}%n%f:%F{green}%~%f %# '\nCMUX_LOCAL_ZSHRC\nfi",
    "cat > /usr/local/bin/cmux-cloud-shell <<'CMUX_CLOUD_SHELL'\n#!/bin/sh\ncd /home/cmux 2>/dev/null || true\nexport HOME=/home/cmux\nexport USER=cmux\nexport LOGNAME=cmux\nif command -v zsh >/dev/null 2>&1; then\n  export SHELL=\"$(command -v zsh)\"\n  exec runuser -u cmux -- \"$SHELL\" -l\nfi\nexport SHELL=/bin/bash\nexec runuser -u cmux -- /bin/bash -l\nCMUX_CLOUD_SHELL",
    "chmod 0755 /usr/local/bin/cmux-cloud-shell",
    "touch /home/cmux/.hushlogin /etc/cmux/zsh-bootstrap-v6 2>/dev/null || true",
    "chown cmux:cmux /home/cmux/.zshrc /home/cmux/.zshrc.local /home/cmux/.hushlogin 2>/dev/null || true",
    "chsh -s \"$(command -v zsh 2>/dev/null || printf /bin/bash)\" cmux >/dev/null 2>&1 || true",
  ];
}

async function readFreestyleCloudShellState(vm: FreestyleVmRef): Promise<{ ok: true } | { ok: false; reason: string }> {
  const command = [
    "set -u",
    "service_shell=\"\"",
    "service_text=\"$(cat /etc/systemd/system/cmuxd-ws.service 2>/dev/null; cat /lib/systemd/system/cmuxd-ws.service 2>/dev/null; ps auxww | grep cmuxd-remote | grep -v grep || true)\"",
    "case \"$service_text\" in *'--shell /usr/local/bin/cmux-cloud-shell'*|*'--shell=/usr/local/bin/cmux-cloud-shell'*) service_shell=ok ;; esac",
    "test \"$service_shell\" = ok || { printf '%s\\n' service-shell-not-managed; exit 10; }",
    "test -x /usr/local/bin/cmux-cloud-shell || { printf '%s\\n' cloud-shell-missing; exit 11; }",
    "id -u cmux >/dev/null 2>&1 || { printf '%s\\n' cmux-user-missing; exit 12; }",
    "test -r /etc/cmux/zshrc || { printf '%s\\n' etc-zshrc-missing; exit 13; }",
    "test -r /home/cmux/.zshrc || { printf '%s\\n' home-zshrc-missing; exit 14; }",
    "command -v zsh >/dev/null 2>&1 || { printf '%s\\n' zsh-missing; exit 15; }",
    "printf '%s\\n' ok",
  ].join(" && ");
  const result = await vm.exec({ command, timeoutMs: 30_000 });
  const exitCode = (result as { statusCode?: number }).statusCode ?? 0;
  if (exitCode === 0) {
    return { ok: true };
  }
  return {
    ok: false,
    reason: ((result.stdout ?? result.stderr ?? "").trim() || `cloud shell state check exited ${exitCode}`),
  };
}

async function waitForFreestyleWebSocketHealthy(domain: string): Promise<void> {
  let lastError: unknown = null;
  for (let attempt = 0; attempt < 12; attempt += 1) {
    try {
      await ensureFreestyleWebSocketHealthy(domain);
      return;
    } catch (err) {
      lastError = err;
      await new Promise((resolve) => setTimeout(resolve, 1_000));
    }
  }
  throw lastError ?? new Error("Cloud VM terminal service did not become healthy");
}

async function installFreestyleLeasesViaDaemon(
  domain: string,
  auth: FreestyleAdminAuth,
  leases: {
    ptyLease: unknown;
    rpcLease?: unknown;
    rpcClient?: ReusableRpcLease;
  },
): Promise<void> {
  const body = JSON.stringify({
    pty_lease: leases.ptyLease,
    rpc_lease: leases.rpcLease,
    rpc_client: leases.rpcClient,
  });
  const headers: Record<string, string> = {
    "content-type": "application/json",
  };
  if (auth.kind === "bearer") {
    headers.authorization = `Bearer ${auth.token}`;
  } else {
    headers["x-cmux-admin-signature-ed25519"] = signAdminLeaseBody(auth, body);
  }
  const response = await fetch(`https://${domain}/admin/leases`, {
    method: "POST",
    headers,
    body,
    signal: AbortSignal.timeout(10_000),
  }).catch((err: unknown) => {
    throw new Error(`Freestyle cmuxd lease install failed: ${errorMessage(err)}`);
  });
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(
      `Freestyle cmuxd lease install returned ${response.status}${text ? `: ${text.trim()}` : ""}`,
    );
  }
}

async function ensureFreestyleWebSocketHealthy(domain: string): Promise<void> {
  const response = await fetch(`https://${domain}/healthz`, {
    signal: AbortSignal.timeout(10_000),
  }).catch((err: unknown) => {
    throw new Error(`Freestyle cmuxd websocket health check failed: ${errorMessage(err)}`);
  });
  if (response.status !== 200) {
    throw new Error(`Freestyle cmuxd websocket health check returned ${response.status}`);
  }
}

async function readFreestyleWebSocketService(vm: FreestyleVmRef): Promise<{
  ptyLeasePath: string;
  rpcLeasePath: string | null;
}> {
  const result = await execFreestyleOrThrow(
    vm,
    [
      "cat /etc/systemd/system/cmuxd-ws.service 2>/dev/null || true",
      "cat /lib/systemd/system/cmuxd-ws.service 2>/dev/null || true",
      "ps auxww | grep cmuxd-remote | grep -v grep || true",
    ].join("; "),
  );
  const stdout = result.stdout ?? "";
  const ptyLeasePath =
    shellArgValue(stdout, "--auth-lease-file")
    ?? (stdout.includes(CMUXD_WS_LEGACY_PTY_LEASE_PATH)
      ? CMUXD_WS_LEGACY_PTY_LEASE_PATH
      : CMUXD_WS_PTY_LEASE_PATH);
  const rpcLeasePath = shellArgValue(stdout, "--rpc-auth-lease-file");
  return { ptyLeasePath, rpcLeasePath };
}

async function readReusableRpcLease(
  vm: FreestyleVmRef,
  rpcLeasePath: string,
): Promise<ReusableRpcLease | null> {
  const result = await vm.exec({
    command: [
      `test -s ${shellQuote(rpcLeasePath)}`,
      `test -s ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
      `cat ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
    ].join(" && "),
    timeoutMs: 30_000,
  }).catch(() => null);
  const raw = result?.stdout?.trim();
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

type FreestyleVmRef = ReturnType<ReturnType<typeof client>["vms"]["ref"]>;

async function execFreestyleCommandsOrThrow(
  vm: FreestyleVmRef,
  commands: readonly string[],
  timeoutMs = 30_000,
): Promise<void> {
  for (const command of commands) {
    await execFreestyleOrThrow(
      vm,
      `export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"; ${command}`,
      timeoutMs,
    );
  }
}

async function execFreestyleOrThrow(vm: FreestyleVmRef, command: string, timeoutMs = 30_000) {
  const result = await vm.exec({ command, timeoutMs });
  const exitCode = (result as { statusCode?: number }).statusCode ?? 0;
  if (exitCode !== 0) {
    throw new Error(`Freestyle exec failed with status ${exitCode}: ${(result.stderr ?? "").trim()}`);
  }
  return result;
}
