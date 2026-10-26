import { gcpLabsDisabledReason, type VmRuntimeEnv } from "../config";
import {
  ProviderError,
  type CreateOptions,
  type ExecOptions,
  type ExecResult,
  type ProviderCredential,
  type ProviderReadOptions,
  type SSHEndpoint,
  type SnapshotRef,
  type VMHandle,
  type VMProvider,
  type VMStatus,
  type VmPauseState,
} from "./types";

const COMPUTE_API = "https://compute.googleapis.com/compute/v1";
const DEFAULT_PROJECT = "manaflow-437420";
const DEFAULT_ZONE = "us-west1-b";
const DEFAULT_MACHINE_TYPE = "e2-standard-2";
const OPERATION_TIMEOUT_MS = 10 * 60_000;
const OPERATION_POLL_MS = 250;

type GcpMetadata = {
  readonly project?: unknown;
  readonly zone?: unknown;
  readonly machineType?: unknown;
  readonly network?: unknown;
  readonly subnetwork?: unknown;
  readonly sshUsername?: unknown;
  readonly idleStopMinutes?: unknown;
};

type GcpInstance = {
  readonly name?: string;
  readonly status?: string;
  readonly networkInterfaces?: readonly {
    readonly networkIP?: string;
    readonly accessConfigs?: readonly { readonly natIP?: string }[];
  }[];
};

type GcpOperation = {
  readonly name?: string;
  readonly status?: "PENDING" | "RUNNING" | "DONE";
  readonly zone?: string;
  readonly error?: { readonly errors?: readonly { readonly code?: string; readonly message?: string }[] };
};

export type GcpProviderDependencies = {
  readonly fetch?: typeof fetch;
  readonly now?: () => number;
  readonly sleep?: (milliseconds: number) => Promise<void>;
  readonly operationTimeoutMs?: number;
  /** Labs flags; defaults to process.env. */
  readonly env?: VmRuntimeEnv;
};

/** A redacted HTTP error that keeps status for provider not-found handling. */
export class GcpApiError extends Error {
  readonly provider = "gcp" as const;

  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(`[gcp] ${message}`);
    this.name = "GcpApiError";
  }
}

/**
 * Google Compute Engine driver for user-owned Labs machines.
 *
 * The access token is supplied per operation by the local client and is never
 * copied into the handle or provider metadata. The instance image is expected
 * to contain acpmux, cmux-tui, and the agent toolchain; this driver only owns
 * Compute Engine lifecycle and SSH metadata.
 */
export class GcpProvider implements VMProvider {
  readonly id = "gcp" as const;
  // IAP attach is layered in the network follow-up; the core provider never
  // advertises a direct public or private address.
  readonly attachTransports = [] as const;
  readonly capabilities = {
    snapshot: false,
    restore: false,
    fork: false,
    exec: false,
    stats: false,
    restart: false,
    ports: false,
    desktop: false,
    // Machine type is a Labs placement setting; CreateOptions.memoryMb is not
    // translated into a Compute Engine shape yet.
    sizing: false,
    persistentHome: false,
  } as const;

  private readonly request: typeof fetch;
  private readonly now: () => number;
  private readonly sleep: (milliseconds: number) => Promise<void>;
  private readonly operationTimeoutMs: number;
  private readonly env: VmRuntimeEnv;

  constructor(deps: GcpProviderDependencies = {}) {
    this.request = deps.fetch ?? fetch;
    this.now = deps.now ?? Date.now;
    this.sleep = deps.sleep ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
    this.operationTimeoutMs = deps.operationTimeoutMs ?? OPERATION_TIMEOUT_MS;
    this.env = deps.env ?? process.env;
  }

  async create(options: CreateOptions): Promise<VMHandle> {
    const credential = this.requireCredential(options.providerCredential);
    if (!options.network) {
      throw new ProviderError("gcp", "create requires a resolved private network; enable the GCP network provider first");
    }
    if (!credential.sshPublicKey || !credential.sshPrivateKeyPem) {
      throw new ProviderError("gcp", "create requires a short-lived SSH public/private key pair for IAP attach");
    }
    const context = contextFromMetadata(options.providerMetadata);
    const image = requiredText(options.image, "image");
    const name = instanceName(options.displayName);
    const body = {
      name,
      machineType: `zones/${context.zone}/machineTypes/${context.machineType}`,
      labels: { cmux: "cloud", cmux_labs: "gcp" },
      disks: [{
        boot: true,
        autoDelete: true,
        initializeParams: {
          sourceImage: image,
          diskSizeGb: Math.max(10, Math.ceil((options.imageSize?.storageMb ?? 32_768) / 1024)),
        },
      }],
      networkInterfaces: [{
        network: options.network.id,
        ...(context.subnetwork ? { subnetwork: context.subnetwork } : {}),
      }],
      metadata: {
        items: [
          { key: "cmux-idle-stop-minutes", value: String(context.idleStopMinutes) },
          ...(credential.sshPublicKey ? [{ key: "ssh-keys", value: `${context.sshUsername}:${credential.sshPublicKey}` }] : []),
        ],
      },
      scheduling: { automaticRestart: true, onHostMaintenance: "MIGRATE" },
    };
    try {
      const operation = await this.api<GcpOperation>(
        "POST",
        `/projects/${context.project}/zones/${context.zone}/instances`,
        credential,
        body,
      );
      await this.waitForOperation(context, operation, credential);
      const instance = await this.instance(context, name, credential);
      return handle(context, name, image, instance, this.now());
    } catch (error) {
      // The insert may have been accepted even when its answer, its
      // operation or the final read failed: delete the named instance so no
      // handle-less machine outlives the failed create.
      if (await this.deleteQuietly(context, name, credential)) throw error;
      throw new ProviderError(
        "gcp",
        `create failed and instance ${context.project}/${context.zone}/${name} (label cmux_labs=gcp) could not be confirmed deleted`,
        error,
      );
    }
  }

  /** Deletes an instance and waits for it; true when it is gone (or never existed). */
  private async deleteQuietly(context: GcpContext, name: string, credential: ProviderCredential): Promise<boolean> {
    try {
      const operation = await this.api<GcpOperation>(
        "DELETE",
        `/projects/${context.project}/zones/${context.zone}/instances/${name}`,
        credential,
      );
      await this.waitForOperation(context, operation, credential);
      return true;
    } catch (error) {
      return error instanceof GcpApiError && error.status === 404;
    }
  }

  async destroy(vmId: string, credential?: ProviderCredential): Promise<void> {
    const context = contextFromVmId(vmId);
    const operation = await this.api<GcpOperation>(
      "DELETE",
      `/projects/${context.project}/zones/${context.zone}/instances/${context.name}`,
      this.requireCredential(credential),
    );
    await this.waitForOperation(context, operation, this.requireCredential(credential));
  }

  async getStatus(vmId: string, options?: ProviderReadOptions): Promise<VMStatus> {
    const context = contextFromVmId(vmId);
    try {
      const instance = await this.instance(context, context.name, this.requireCredential(options?.credential), options?.signal);
      return statusOf(instance.status);
    } catch (error) {
      if (error instanceof GcpApiError && error.status === 404) return "destroyed";
      throw error;
    }
  }

  async getPauseState(vmId: string, credential?: ProviderCredential): Promise<VmPauseState> {
    const status = await this.getStatus(vmId, { credential });
    if (status === "destroyed") return "destroyed";
    if (status === "paused") return "stopped";
    if (status === "creating") return "in_progress";
    return "not_paused";
  }

  async pause(vmId: string, credential?: ProviderCredential): Promise<void> {
    await this.transition(vmId, "stop", this.requireCredential(credential));
  }

  async resume(vmId: string, credential?: ProviderCredential): Promise<VMHandle> {
    const context = contextFromVmId(vmId);
    const token = this.requireCredential(credential);
    const operation = await this.api<GcpOperation>(
      "POST",
      `/projects/${context.project}/zones/${context.zone}/instances/${context.name}/start`,
      token,
    );
    await this.waitForOperation(context, operation, token);
    const instance = await this.instance(context, context.name, token);
    return handle(context, context.name, "", instance, this.now());
  }

  async restart(vmId: string): Promise<void> {
    throw new ProviderError("gcp", `restart(${vmId}) requires a per-operation credential`);
  }

  async openSSH(_vmId: string, _credential?: ProviderCredential): Promise<SSHEndpoint> {
    throw new ProviderError("gcp", "IAP SSH attach requires the GCP private-network follow-up");
  }

  async revokeSSHIdentity(_identityHandle: string): Promise<void> {
    // GCP SSH keys are attached as instance metadata and expire with the VM;
    // no server-side identity is minted by this provider.
  }

  async exec(_vmId: string, _command: string, _options?: ExecOptions): Promise<ExecResult> {
    throw new ProviderError("gcp", "exec is not available until the cmux daemon attach contract is enabled");
  }

  async snapshot(_vmId: string, _name?: string): Promise<SnapshotRef> {
    throw new ProviderError("gcp", "snapshot is not available in the Labs provider");
  }

  async restore(_snapshotId: string): Promise<VMHandle> {
    throw new ProviderError("gcp", "restore is not available in the Labs provider");
  }

  private async transition(vmId: string, operationName: "stop" | "start", credential: ProviderCredential): Promise<void> {
    const context = contextFromVmId(vmId);
    const operation = await this.api<GcpOperation>(
      "POST",
      `/projects/${context.project}/zones/${context.zone}/instances/${context.name}/${operationName}`,
      credential,
    );
    await this.waitForOperation(context, operation, credential);
  }

  private async instance(context: GcpContext, name: string, credential: ProviderCredential, signal?: AbortSignal): Promise<GcpInstance> {
    return this.api<GcpInstance>("GET", `/projects/${context.project}/zones/${context.zone}/instances/${name}`, credential, undefined, signal);
  }

  private async waitForOperation(context: GcpContext, operation: GcpOperation, credential: ProviderCredential): Promise<void> {
    if (!operation.name || operation.status === "DONE") {
      if (operation.error) throw operationFailure(operation);
      return;
    }
    const deadline = this.now() + this.operationTimeoutMs;
    const path = operation.zone
      ? `/projects/${context.project}/zones/${context.zone}/operations/${operation.name}`
      : `/projects/${context.project}/global/operations/${operation.name}`;
    for (;;) {
      if (this.now() >= deadline) throw new ProviderError("gcp", `operation ${operation.name} timed out`);
      const current = await this.api<GcpOperation>("GET", path, credential);
      if (current.status === "DONE") {
        if (current.error) throw operationFailure(current);
        return;
      }
      await this.sleep(OPERATION_POLL_MS);
    }
  }

  private async api<T>(method: string, path: string, credential: ProviderCredential, body?: unknown, signal?: AbortSignal): Promise<T> {
    // Every Compute Engine call, not only create, is behind the Labs gate.
    const disabled = gcpLabsDisabledReason(this.env);
    if (disabled) throw new ProviderError("gcp", disabled);
    const token = this.requireCredential(credential);
    // Wiping the credential (the workflow ended or was interrupted) aborts
    // every request still carrying its bearer token.
    const lifetime = token.lifetime?.signal;
    const requestSignal = signal && lifetime ? AbortSignal.any([signal, lifetime]) : signal ?? lifetime;
    let response: Response;
    try {
      response = await this.request(`${COMPUTE_API}${path}`, {
        method,
        headers: {
          authorization: `Bearer ${token.accessToken.utf8()}`,
          ...(body === undefined ? {} : { "content-type": "application/json" }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: requestSignal,
      });
    } catch (error) {
      throw new ProviderError("gcp", `${method} ${path} did not answer`, error);
    }
    if (!response.ok) {
      throw new GcpApiError(response.status, response.status === 404 ? "NOT_FOUND" : "GCP_API_ERROR", `${method} ${path} returned ${response.status}`);
    }
    if (response.status === 204) return undefined as T;
    try {
      return await response.json() as T;
    } catch (error) {
      throw new ProviderError("gcp", `${method} ${path} returned invalid JSON`, error);
    }
  }

  private requireCredential(credential: ProviderCredential | undefined): ProviderCredential {
    if (!credential || credential.provider !== "gcp" || credential.accessToken.byteLength === 0 || credential.accessToken.wiped) {
      throw new ProviderError("gcp", "a short-lived local GCP access token is required");
    }
    if (!Number.isFinite(credential.expiresAtUnix) || credential.expiresAtUnix <= Math.floor(this.now() / 1000)) {
      throw new ProviderError("gcp", "the local GCP access token has expired");
    }
    return credential;
  }
}

type GcpContext = {
  readonly project: string;
  readonly zone: string;
  readonly machineType: string;
  readonly network: string;
  readonly subnetwork?: string;
  readonly sshUsername: string;
  readonly idleStopMinutes: number;
  readonly name: string;
};

function contextFromMetadata(metadata: Record<string, unknown> | undefined): GcpContext {
  const raw = metadata as GcpMetadata | undefined;
  const project = text(raw?.project) ?? process.env.CMUX_VM_GCP_PROJECT ?? DEFAULT_PROJECT;
  const zone = text(raw?.zone) ?? process.env.CMUX_VM_GCP_ZONE ?? DEFAULT_ZONE;
  const machineType = text(raw?.machineType) ?? process.env.CMUX_VM_GCP_MACHINE_TYPE ?? DEFAULT_MACHINE_TYPE;
  const network = text(raw?.network) ?? "global/networks/default";
  const subnetwork = text(raw?.subnetwork);
  const sshUsername = text(raw?.sshUsername) ?? "cmux";
  const idleStopMinutes = positiveInt(raw?.idleStopMinutes) ?? 30;
  assertSegment(project, "project");
  assertSegment(zone, "zone");
  assertSegment(machineType, "machineType");
  assertSegment(sshUsername, "sshUsername");
  return { project, zone, machineType, network, subnetwork, sshUsername, idleStopMinutes, name: "" };
}

function contextFromVmId(vmId: string): GcpContext {
  const parts = vmId.split("/");
  if (parts.length !== 3 || parts.some((part) => part.length === 0)) throw new ProviderError("gcp", "invalid GCP VM id");
  const [project, zone, name] = parts;
  assertSegment(project, "project");
  assertSegment(zone, "zone");
  assertSegment(name, "name");
  return { project, zone, machineType: DEFAULT_MACHINE_TYPE, network: "global/networks/default", sshUsername: "cmux", idleStopMinutes: 30, name };
}

function handle(context: GcpContext, name: string, image: string, instance: GcpInstance, createdAt: number): VMHandle {
  const internal = instance.networkInterfaces?.[0]?.networkIP;
  const external = instance.networkInterfaces?.[0]?.accessConfigs?.[0]?.natIP;
  return {
    provider: "gcp",
    providerVmId: `${context.project}/${context.zone}/${name}`,
    status: statusOf(instance.status),
    image,
    createdAt,
    providerMetadata: {
      gcpProject: context.project,
      gcpZone: context.zone,
      gcpInstanceName: name,
      gcpSshUsername: context.sshUsername,
      ...(internal ? { networkIpv4: internal } : {}),
      ...(external ? { gcpExternalIpv4: external } : {}),
      gcpIdleStopMinutes: context.idleStopMinutes,
      cmuxTuiContract: "gcp-v1",
    },
  };
}

function statusOf(status: string | undefined): VMStatus {
  if (status === "RUNNING") return "running";
  if (status === "TERMINATED" || status === "SUSPENDED") return "paused";
  if (status === "DELETING") return "destroyed";
  return "creating";
}

function operationFailure(operation: GcpOperation): ProviderError {
  const detail = operation.error?.errors?.[0];
  return new ProviderError("gcp", `operation failed${detail?.code ? ` (${detail.code})` : ""}`);
}

function instanceName(displayName: string | undefined): string {
  const base = (displayName ?? "cmux").toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48) || "cmux";
  return `${base}-${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`;
}

function requiredText(value: string, name: string): string {
  const result = value.trim();
  if (!result) throw new ProviderError("gcp", `create requires a resolved ${name}`);
  return result;
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function positiveInt(value: unknown): number | undefined {
  return Number.isSafeInteger(value) && (value as number) > 0 ? value as number : undefined;
}

function assertSegment(value: string, name: string): void {
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(value)) throw new ProviderError("gcp", `invalid GCP ${name}`);
}

