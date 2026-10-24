import {
  ProviderError,
  type CreateOptions,
  type ExecOptions,
  type ExecResult,
  type ProviderCredential,
  type EnsureProviderNetworkOptions,
  type ProviderNetwork,
  type ProviderReadOptions,
  type SSHEndpoint,
  type SnapshotRef,
  type VMHandle,
  type VMPrivateNetworking,
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
  readonly region?: string;
  readonly error?: { readonly errors?: readonly { readonly code?: string; readonly message?: string }[] };
};

export type GcpProviderDependencies = {
  readonly fetch?: typeof fetch;
  readonly now?: () => number;
  readonly sleep?: (milliseconds: number) => Promise<void>;
  readonly operationTimeoutMs?: number;
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
  readonly attachTransports = ["ssh"] as const;
  readonly privateNetworkingTunnels = false;
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
  readonly privateNetworking: VMPrivateNetworking = {
    ensureNetwork: (options) => this.ensureNetwork(options),
    getNetwork: (networkIdOrSlug) => this.getNetwork(networkIdOrSlug),
    deleteNetwork: async () => undefined,
    createTunnel: async () => { throw new ProviderError("gcp", "tailnet enrollment is not available in the GCP Labs provider"); },
    getTunnel: async () => { throw new ProviderError("gcp", "tailnet enrollment is not available in the GCP Labs provider"); },
    rotateTunnelKey: async () => { throw new ProviderError("gcp", "tailnet enrollment is not available in the GCP Labs provider"); },
    deleteTunnel: async () => undefined,
  };

  private readonly request: typeof fetch;
  private readonly now: () => number;
  private readonly sleep: (milliseconds: number) => Promise<void>;
  private readonly operationTimeoutMs: number;

  constructor(deps: GcpProviderDependencies = {}) {
    this.request = deps.fetch ?? fetch;
    this.now = deps.now ?? Date.now;
    this.sleep = deps.sleep ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
    this.operationTimeoutMs = deps.operationTimeoutMs ?? OPERATION_TIMEOUT_MS;
  }

  async create(options: CreateOptions): Promise<VMHandle> {
    const credential = this.requireCredential(options.providerCredential);
    if (!credential.sshPublicKey || !credential.sshPrivateKeyPem) {
      throw new ProviderError("gcp", "create requires a short-lived SSH public/private key pair for IAP attach");
    }
    const context = contextFromMetadata(options.providerMetadata);
    const image = requiredText(options.image, "image");
    const network = options.network?.id ?? context.network;
    const subnetRegion = context.zone.replace(/-[a-z]$/, "");
    const name = instanceName(options.displayName);
    const body = {
      name,
      machineType: `zones/${context.zone}/machineTypes/${context.machineType}`,
      labels: { cmux: "cloud", cmux_labs: "gcp" },
      tags: { items: ["cmux-vm"] },
      disks: [{
        boot: true,
        autoDelete: true,
        initializeParams: {
          sourceImage: image,
          diskSizeGb: Math.max(10, Math.ceil((options.imageSize?.storageMb ?? 32_768) / 1024)),
        },
      }],
      networkInterfaces: [{
        network,
        subnetwork: context.subnetwork ?? `regions/${subnetRegion}/subnetworks/cmux-vms`,
      }],
      metadata: {
        items: [
          { key: "cmux-idle-stop-minutes", value: String(context.idleStopMinutes) },
          ...(credential.sshPublicKey ? [{ key: "ssh-keys", value: `${context.sshUsername}:${credential.sshPublicKey}` }] : []),
        ],
      },
      scheduling: { automaticRestart: true, onHostMaintenance: "MIGRATE" },
    };
    const operation = await this.api<GcpOperation>(
      "POST",
      `/projects/${context.project}/zones/${context.zone}/instances`,
      credential,
      body,
    );
    await this.waitForOperation(context, operation, credential);
    const instance = await this.instance(context, name, credential);
    return handle(context, name, image, instance, this.now());
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

  async openSSH(vmId: string, credential?: ProviderCredential): Promise<SSHEndpoint> {
    const token = this.requireCredential(credential);
    const privateKey = credential?.sshPrivateKeyPem;
    if (!privateKey) throw new ProviderError("gcp", "openSSH requires a short-lived client SSH private key");
    const context = contextFromVmId(vmId);
    await this.instance(context, context.name, token);
    return {
      transport: "ssh",
      host: "gcp-iap",
      port: 22,
      username: credential.sshUsername ?? context.sshUsername,
      publicKeyFingerprint: null,
      credential: { kind: "authorizedKey", privateKeyPem: privateKey.utf8() },
      identityHandle: vmId,
      proxy: { kind: "gcp-iap", project: context.project, zone: context.zone, instance: context.name, port: 22 },
    };
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

  private async ensureNetwork(options: EnsureProviderNetworkOptions): Promise<ProviderNetwork> {
    const credential = this.requireCredential(options.providerCredential);
    const project = options.providerProject ?? process.env.CMUX_VM_GCP_PROJECT ?? DEFAULT_PROJECT;
    const region = options.providerRegion ?? process.env.CMUX_VM_GCP_REGION ?? DEFAULT_ZONE.replace(/-[a-z]$/, "");
    assertSegment(project, "project");
    assertSegment(region, "region");
    const name = "cmux-vms";
    const networkPath = `/projects/${project}/global/networks/${name}`;
    let network: { readonly selfLink?: string };
    try {
      network = await this.api("GET", networkPath, credential);
    } catch (error) {
      if (!(error instanceof GcpApiError && error.status === 404)) throw error;
      let operation: GcpOperation | undefined;
      try {
        operation = await this.api<GcpOperation>("POST", `/projects/${project}/global/networks`, credential, { name, autoCreateSubnetworks: false });
      } catch (createError) {
        if (!isAlreadyExists(createError)) throw createError;
      }
      if (operation) {
        await this.waitForOperation({ project, zone: `${region}-b`, machineType: DEFAULT_MACHINE_TYPE, network: networkPath, sshUsername: "cmux", idleStopMinutes: 30, name }, operation, credential);
      }
      network = await this.api("GET", networkPath, credential);
    }
    const subnetPath = `/projects/${project}/regions/${region}/subnetworks/${name}`;
    let subnet: { readonly ipCidrRange?: string };
    try {
      subnet = await this.api("GET", subnetPath, credential);
    } catch (error) {
      if (!(error instanceof GcpApiError && error.status === 404)) throw error;
      let operation: GcpOperation | undefined;
      try {
        operation = await this.api<GcpOperation>("POST", `/projects/${project}/regions/${region}/subnetworks`, credential, {
          name,
          network: network.selfLink ?? `projects/${project}/global/networks/${name}`,
          ipCidrRange: options.cidr ?? "10.240.0.0/16",
          region,
        });
      } catch (createError) {
        if (!isAlreadyExists(createError)) throw createError;
      }
      if (operation) {
        await this.waitForOperation({ project, zone: `${region}-b`, machineType: DEFAULT_MACHINE_TYPE, network: networkPath, sshUsername: "cmux", idleStopMinutes: 30, name }, operation, credential);
      }
      subnet = await this.api("GET", subnetPath, credential);
    }
    await this.ensureFirewall(project, network.selfLink ?? networkPath, credential);
    await this.ensureNat(project, region, network.selfLink ?? networkPath, credential);
    return { id: network.selfLink ?? networkPath, slug: name, cidr: subnet.ipCidrRange ?? "10.240.0.0/16", cidrV6: null };
  }

  private async getNetwork(networkIdOrSlug: string): Promise<ProviderNetwork | null> {
    if (networkIdOrSlug !== "cmux-vms" && !networkIdOrSlug.endsWith("/cmux-vms")) return null;
    return { id: networkIdOrSlug, slug: "cmux-vms", cidr: "10.240.0.0/16", cidrV6: null };
  }

  private async ensureFirewall(project: string, network: string, credential: ProviderCredential): Promise<void> {
    const rules = [
      { name: "cmux-vms-deny-ingress", priority: 1000, denied: [{ IPProtocol: "all" }] },
      { name: "cmux-vms-iap-ssh", priority: 900, allowed: [{ IPProtocol: "tcp", ports: ["22"] }], sourceRanges: ["35.235.240.0/20"] },
    ];
    for (const rule of rules) {
      try {
        await this.api("GET", `/projects/${project}/global/firewalls/${rule.name}`, credential);
      } catch (error) {
        if (!(error instanceof GcpApiError && error.status === 404)) throw error;
        let operation: GcpOperation | undefined;
        try {
          operation = await this.api<GcpOperation>("POST", `/projects/${project}/global/firewalls`, credential, {
            ...rule,
            network,
            direction: "INGRESS",
            targetTags: ["cmux-vm"],
          });
        } catch (createError) {
          if (!isAlreadyExists(createError)) throw createError;
        }
        if (operation) {
          await this.waitForOperation({ project, zone: `${DEFAULT_ZONE}`, machineType: DEFAULT_MACHINE_TYPE, network, sshUsername: "cmux", idleStopMinutes: 30, name: rule.name }, operation, credential);
        }
      }
    }
  }

  private async ensureNat(project: string, region: string, network: string, credential: ProviderCredential): Promise<void> {
    const routerPath = `/projects/${project}/regions/${region}/routers/cmux-vms`;
    try {
      await this.api("GET", routerPath, credential);
    } catch (error) {
      if (!(error instanceof GcpApiError && error.status === 404)) throw error;
      let operation: GcpOperation | undefined;
      try {
        operation = await this.api<GcpOperation>("POST", `/projects/${project}/regions/${region}/routers`, credential, { name: "cmux-vms", network, bgp: { asn: 64514 } });
      } catch (createError) {
        if (!isAlreadyExists(createError)) throw createError;
      }
      if (operation) {
        await this.waitForOperation({ project, zone: `${region}-b`, machineType: DEFAULT_MACHINE_TYPE, network, sshUsername: "cmux", idleStopMinutes: 30, name: "cmux-vms" }, operation, credential);
      }
    }
    const operation = await this.api<GcpOperation>("PATCH", routerPath, credential, {
      name: "cmux-vms",
      network,
      bgp: { asn: 64514 },
      nats: [{ name: "cmux-vms", natIpAllocateOption: "AUTO_ONLY", sourceSubnetworkIpRangesToNat: "ALL_SUBNETWORKS_ALL_IP_RANGES", minPortsPerVm: 64 }],
    });
    await this.waitForOperation({ project, zone: `${region}-b`, machineType: DEFAULT_MACHINE_TYPE, network, sshUsername: "cmux", idleStopMinutes: 30, name: "cmux-vms" }, operation, credential);
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
    const path = operation.region
      ? `/projects/${context.project}/regions/${resourceName(operation.region)}/operations/${operation.name}`
      : operation.zone
        ? `/projects/${context.project}/zones/${resourceName(operation.zone)}/operations/${operation.name}`
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
    const token = this.requireCredential(credential);
    let response: Response;
    try {
      response = await this.request(`${COMPUTE_API}${path}`, {
        method,
        headers: {
          authorization: `Bearer ${token.accessToken.utf8()}`,
          ...(body === undefined ? {} : { "content-type": "application/json" }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal,
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
    if (!credential || credential.provider !== "gcp" || credential.accessToken.byteLength === 0) {
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

function resourceName(value: string): string {
  return value.split("/").filter(Boolean).at(-1) ?? value;
}

function isAlreadyExists(error: unknown): boolean {
  return error instanceof GcpApiError && error.status === 409;
}

function assertSegment(value: string, name: string): void {
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(value)) throw new ProviderError("gcp", `invalid GCP ${name}`);
}

