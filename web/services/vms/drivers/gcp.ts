import { gcpLabsDisabledReason, type VmRuntimeEnv } from "../config";
import { ProviderCreateCleanupError } from "./providerCreateCleanup";
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
/** Insert answers that prove Compute Engine rejected the request before allocating. */
const INSERT_REFUSED_STATUSES = new Set([400, 401, 403, 404]);
const DEFAULT_PROJECT = "manaflow-437420";
const DEFAULT_ZONE = "us-west1-b";
const DEFAULT_MACHINE_TYPE = "e2-standard-2";
const OPERATION_TIMEOUT_MS = 10 * 60_000;
const OPERATION_POLL_MS = 250;
const ENSURE_ATTEMPTS = 4;
const FIREWALL_RULES = [
  // Explicit sources: Compute Engine reads an omitted ingress source back as 0.0.0.0/0.
  { name: "cmux-vms-deny-ingress", priority: 1000, denied: [{ IPProtocol: "all" }], sourceRanges: ["0.0.0.0/0"] },
  // IAP TCP forwarding's documented source range.
  { name: "cmux-vms-iap-ssh", priority: 900, allowed: [{ IPProtocol: "tcp", ports: ["22"] }], sourceRanges: ["35.235.240.0/20"] },
] as const;
/**
 * One /20 per region inside 10.208.0.0/12, so subnets of the project-wide VPC
 * never overlap. Append only: a region's index is its range for good.
 */
const GCP_REGIONS = [
  "us-central1", "us-east1", "us-east4", "us-east5", "us-south1", "us-west1", "us-west2", "us-west3", "us-west4",
  "northamerica-northeast1", "northamerica-northeast2", "northamerica-south1", "southamerica-east1", "southamerica-west1",
  "europe-central2", "europe-north1", "europe-north2", "europe-southwest1", "europe-west1", "europe-west2", "europe-west3",
  "europe-west4", "europe-west6", "europe-west8", "europe-west9", "europe-west10", "europe-west12",
  "me-central1", "me-central2", "me-west1", "africa-south1",
  "asia-east1", "asia-east2", "asia-northeast1", "asia-northeast2", "asia-northeast3", "asia-south1", "asia-south2",
  "asia-southeast1", "asia-southeast2", "australia-southeast1", "australia-southeast2",
] as const;

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

type GcpFirewall = {
  readonly network?: string;
  readonly direction?: string;
  readonly priority?: number;
  readonly targetTags?: readonly string[];
  readonly sourceRanges?: readonly string[];
  readonly denied?: readonly { readonly IPProtocol?: string }[];
  readonly allowed?: readonly { readonly IPProtocol?: string; readonly ports?: readonly string[] }[];
  readonly disabled?: boolean;
  readonly sourceTags?: readonly string[];
  readonly sourceServiceAccounts?: readonly string[];
  readonly targetServiceAccounts?: readonly string[];
  readonly destinationRanges?: readonly string[];
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
    deleteNetwork: async () => { throw new ProviderError("gcp", "project-scoped cmux-vms cleanup requires explicit operator action"); },
    createTunnel: async () => { throw new ProviderError("gcp", "tailnet enrollment is not available in the GCP Labs provider"); },
    getTunnel: async () => { throw new ProviderError("gcp", "tailnet enrollment is not available in the GCP Labs provider"); },
    rotateTunnelKey: async () => { throw new ProviderError("gcp", "tailnet enrollment is not available in the GCP Labs provider"); },
    deleteTunnel: async () => undefined,
  };

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
    const cleanupIntent = options.createCleanupIntent;
    if (!cleanupIntent) {
      throw new ProviderError("gcp", "create requires a durable cleanup intent before Compute Engine allocates an instance");
    }
    // A create the Labs gate refuses records nothing: no row may name an
    // instance that was never requested and that no drain will run for.
    const disabled = gcpLabsDisabledReason(this.env);
    if (disabled) throw new ProviderError("gcp", disabled);
    const context = contextFromMetadata(options.providerMetadata);
    const image = requiredText(options.image, "image");
    const network = options.network.id;
    const subnetRegion = zoneRegion(context.zone);
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
        subnetwork: `regions/${subnetRegion}/subnetworks/cmux-vms`,
      }],
      metadata: {
        items: [
          { key: "cmux-idle-stop-minutes", value: String(context.idleStopMinutes) },
          ...(credential.sshPublicKey ? [{ key: "ssh-keys", value: `${context.sshUsername}:${credential.sshPublicKey}` }] : []),
        ],
      },
      scheduling: { automaticRestart: true, onHostMaintenance: "MIGRATE" },
    };
    const providerVmId = `${context.project}/${context.zone}/${name}`;
    // The row names this instance before Compute Engine can allocate it, so a
    // create interrupted after the insert (its credential wiped, its process
    // gone) still leaves a durable delete for the next credentialed request.
    // Without that record there is no create: cleanup needs a user token the
    // server cannot keep.
    try {
      await cleanupIntent.record(providerVmId);
    } catch (error) {
      throw new ProviderError("gcp", "create could not record its cleanup intent; no instance was requested", error);
    }
    // The same checks api() makes before it sends; with no await between here
    // and the POST, a refusal past this point means the request went out.
    try {
      const refused = gcpLabsDisabledReason(this.env);
      if (refused) throw new ProviderError("gcp", refused);
      this.requireCredential(credential);
    } catch (error) {
      cleanupIntent.released();
      throw error;
    }
    let insertAnswered = false;
    // Only a finished insert operation proves a later not-found: while it
    // runs, the instance may not be visible yet and can still appear.
    let insertSettled = false;
    try {
      const operation = await this.api<GcpOperation>(
        "POST",
        `/projects/${context.project}/zones/${context.zone}/instances`,
        credential,
        body,
      );
      insertAnswered = true;
      await this.waitForOperation(context, operation, credential, () => { insertSettled = true; });
      const instance = await this.instance(context, name, credential);
      return handle(context, name, image, instance, this.now());
    } catch (error) {
      // The insert may have been accepted even when its answer, its
      // operation or the final read failed: delete the named instance so no
      // handle-less machine outlives the failed create.
      // Only a conclusive refusal of the request itself allocated nothing. A
      // 408, 409 or 429 may follow an allocation, so it keeps the intent.
      if (!insertAnswered && error instanceof GcpApiError && INSERT_REFUSED_STATUSES.has(error.status)) {
        cleanupIntent.released();
        throw error;
      }
      // An insert whose operation never finished may still materialize, so a
      // 404 then does not prove the instance is gone.
      const cleanup = await this.deleteQuietly(context, name, credential, insertSettled);
      if (cleanup === null) {
        cleanupIntent.released();
        throw error;
      }
      // Unconfirmed: the workflow keeps the row as a retained cleanup that the
      // next request carrying a credential for this user deletes.
      throw new ProviderCreateCleanupError(providerVmId, error, cleanup, "gcp");
    }
  }

  /** Deletes an instance and waits for it; null when it is gone, else the cleanup failure. */
  private async deleteQuietly(context: GcpContext, name: string, credential: ProviderCredential, notFoundConfirms: boolean): Promise<unknown> {
    try {
      await this.deleteInstance(context, name, credential);
      return null;
    } catch (error) {
      return notFoundConfirms && error instanceof GcpApiError && error.status === 404 ? null : error;
    }
  }

  async destroy(vmId: string, credential?: ProviderCredential): Promise<void> {
    const context = contextFromVmId(vmId);
    await this.deleteInstance(context, context.name, this.requireCredential(credential));
  }

  /**
   * Deletes a named instance and waits for it. A 404 GcpApiError here always
   * means the instance is absent and no unfinished operation (an insert that
   * is still running) targets it: an operation record that cannot be read
   * proves nothing, so the instance is read back instead.
   */
  private async deleteInstance(context: GcpContext, name: string, credential: ProviderCredential): Promise<void> {
    let operation: GcpOperation;
    try {
      operation = await this.api<GcpOperation>(
        "DELETE",
        `/projects/${context.project}/zones/${context.zone}/instances/${name}`,
        credential,
      );
    } catch (error) {
      if (error instanceof GcpApiError && error.status === 404 && !(await this.noUnfinishedOperation(context, name, credential))) {
        throw new GcpApiError(503, "DELETE_UNCONFIRMED", `${context.zone}/${name} is not found yet an operation on it may still finish`);
      }
      throw error;
    }
    try {
      await this.waitForOperation(context, operation, credential);
    } catch (error) {
      // The DELETE was accepted, so the instance existed; reading it back as
      // not-found now means it is gone.
      const gone = await this.instance(context, name, credential).then(
        () => false,
        (readError: unknown) => readError instanceof GcpApiError && readError.status === 404,
      );
      if (gone) return;
      // A concrete non-404 status, and no cause: not-found checks walk causes
      // and messages, and the operation's 404 is not the instance's.
      throw new GcpApiError(
        503,
        "DELETE_UNCONFIRMED",
        `delete of ${context.zone}/${name} is unconfirmed; the instance was not read back as gone`,
      );
    }
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
    // The subnet must be in the region of the zone instances are placed in.
    const region = options.providerRegion ?? zoneRegion(process.env.CMUX_VM_GCP_ZONE ?? DEFAULT_ZONE);
    assertSegment(project, "project");
    assertSegment(region, "region");
    const subnetRange = regionCidr(region);
    const name = "cmux-vms";
    const networkPath = `/projects/${project}/global/networks/${name}`;
    const network = await this.ensureResource<{ readonly selfLink?: string; readonly autoCreateSubnetworks?: boolean }>(project, networkPath, credential, {
      create: () => this.api<GcpOperation>("POST", `/projects/${project}/global/networks`, credential, { name, autoCreateSubnetworks: false }),
      // Only a custom-mode VPC has no subnets but ours for the NAT to cover.
      conflict: (existing) => existing.autoCreateSubnetworks === false ? null : "is not a custom-mode VPC",
    });
    const networkLink = network.selfLink ?? networkPath;
    const offNetwork = (existing: { readonly network?: string }) =>
      sameNetwork(existing.network, project, networkLink) ? null : "exists on another network";
    const subnet = await this.ensureResource<{ readonly ipCidrRange?: string; readonly network?: string }>(project, `/projects/${project}/regions/${region}/subnetworks/${name}`, credential, {
      // The request path names the region; the body never repeats it.
      create: () => this.api<GcpOperation>("POST", `/projects/${project}/regions/${region}/subnetworks`, credential, {
        name,
        network: networkLink,
        ipCidrRange: subnetRange,
      }),
      // Its range is this region's for good; a subnet with another range is not ours.
      conflict: (existing) => offNetwork(existing) ??
        (existing.ipCidrRange === subnetRange ? null : `has range ${existing.ipCidrRange ?? "unknown"}, not ${subnetRange}`),
    });
    for (const rule of FIREWALL_RULES) {
      const body = { ...rule, network: networkLink, direction: "INGRESS", targetTags: ["cmux-vm"], disabled: false };
      const path = `/projects/${project}/global/firewalls/${rule.name}`;
      await this.ensureResource<GcpFirewall>(project, path, credential, {
        create: () => this.api<GcpOperation>("POST", `/projects/${project}/global/firewalls`, credential, body),
        matches: (existing) => firewallMatches(existing, project, networkLink, rule),
        repair: () => this.api<GcpOperation>("PUT", path, credential, body),
      });
    }
    const routerPath = `/projects/${project}/regions/${region}/routers/${name}`;
    const nat = { name, natIpAllocateOption: "AUTO_ONLY", sourceSubnetworkIpRangesToNat: "ALL_SUBNETWORKS_ALL_IP_RANGES", minPortsPerVm: 64 };
    const router = { name, network: networkLink, bgp: { asn: 64514 }, nats: [nat] };
    await this.ensureResource<{ readonly network?: string; readonly nats?: readonly Record<string, unknown>[] }>(project, routerPath, credential, {
      create: () => this.api<GcpOperation>("POST", `/projects/${project}/regions/${region}/routers`, credential, router),
      conflict: offNetwork,
      matches: (existing) => (existing.nats ?? []).some((entry) =>
        Object.entries(nat).every(([key, value]) => entry[key] === value)),
      repair: () => this.api<GcpOperation>("PATCH", routerPath, credential, router),
    });
    return { id: networkLink, slug: name, cidr: subnetRange, cidrV6: null };
  }

  /**
   * Reads a resource, creating or repairing it until a read shows it as
   * wanted. A concurrent creator's 409, or an operation still settling, is
   * retried a bounded number of times; success is always a verified read.
   */
  private async ensureResource<T>(
    project: string,
    path: string,
    credential: ProviderCredential,
    steps: {
      readonly create: () => Promise<GcpOperation>;
      readonly matches?: (existing: T) => boolean;
      readonly repair?: () => Promise<GcpOperation>;
      /** Why an existing resource's immutable fields cannot be repaired in place, if they cannot. */
      readonly conflict?: (existing: T) => string | null;
    },
  ): Promise<T> {
    const context = { project, zone: DEFAULT_ZONE, machineType: DEFAULT_MACHINE_TYPE, network: path, sshUsername: "cmux", idleStopMinutes: 30, name: "cmux-vms" };
    for (let attempt = 0; attempt < ENSURE_ATTEMPTS; attempt += 1) {
      if (attempt > 0) await this.sleep(OPERATION_POLL_MS * 4 * attempt);
      let existing: T | null;
      try {
        existing = await this.api<T>("GET", path, credential);
      } catch (error) {
        if (!(error instanceof GcpApiError && error.status === 404)) throw error;
        existing = null;
      }
      const conflict = existing ? steps.conflict?.(existing) : null;
      if (conflict) throw new ProviderError("gcp", `${path.split("/").slice(-2).join("/")} ${conflict}; remove or rename it`);
      if (existing && (!steps.matches || steps.matches(existing))) return existing;
      const change = existing ? steps.repair : steps.create;
      if (!change) break;
      try {
        await this.waitForOperation(context, await change(), credential);
      } catch (error) {
        // Another request created or changed it first: read it again.
        if (!isAlreadyExists(error)) throw error;
      }
    }
    throw new ProviderError("gcp", `could not confirm ${path.split("/").slice(-2).join("/")} is provisioned`);
  }

  private async getNetwork(networkIdOrSlug: string): Promise<ProviderNetwork | null> {
    // Existing rows are revalidated by the credentialed ensureNetwork path. This
    // read has no credential and must never claim a synthetic VPC or CIDR.
    void networkIdOrSlug;
    return null;
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

  /**
   * True only when Compute Engine lists every operation on the instance as
   * finished: an accepted insert can outlive any local deadline, and its
   * instance may not be visible until it finishes. Any read failure is false.
   */
  private async noUnfinishedOperation(context: GcpContext, name: string, credential: ProviderCredential): Promise<boolean> {
    const filter = encodeURIComponent(`targetLink eq '.*/projects/${context.project}/zones/${context.zone}/instances/${name}'`);
    let pageToken: string | undefined;
    try {
      for (let page = 0; page < 5; page += 1) {
        const list = await this.api<{ readonly items?: readonly GcpOperation[]; readonly nextPageToken?: string }>(
          "GET",
          `/projects/${context.project}/zones/${context.zone}/operations?filter=${filter}&maxResults=500${pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : ""}`,
          credential,
        );
        if ((list.items ?? []).some((operation) => operation.status !== "DONE")) return false;
        pageToken = list.nextPageToken;
        if (!pageToken) return true;
      }
      return false;
    } catch {
      return false;
    }
  }

  private async instance(context: GcpContext, name: string, credential: ProviderCredential, signal?: AbortSignal): Promise<GcpInstance> {
    return this.api<GcpInstance>("GET", `/projects/${context.project}/zones/${context.zone}/instances/${name}`, credential, undefined, signal);
  }

  private async waitForOperation(
    context: GcpContext,
    operation: GcpOperation,
    credential: ProviderCredential,
    onDone?: () => void,
  ): Promise<void> {
    if (operation.status === "DONE") {
      onDone?.();
      if (operation.error) throw operationFailure(operation);
      return;
    }
    // An unfinished operation without a name cannot be followed: its outcome
    // is unknown, never success.
    if (!operation.name) throw new ProviderError("gcp", "Compute Engine answered with an unfinished operation that has no name");
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
        onDone?.();
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

/** Whether a resource's network is the cmux-vms VPC (Compute Engine answers with a full self link). */
function sameNetwork(actual: string | undefined, project: string, network: string): boolean {
  return !!actual && (actual === network || actual.endsWith(`/projects/${project}/global/networks/cmux-vms`));
}

function regionCidr(region: string): string {
  const index = (GCP_REGIONS as readonly string[]).indexOf(region);
  if (index < 0) throw new ProviderError("gcp", `region ${region} is not available in the GCP Labs provider`);
  return `10.${208 + Math.floor(index / 16)}.${(index % 16) * 16}.0/20`;
}

function zoneRegion(zone: string): string {
  return zone.replace(/-[a-z]$/, "");
}

function resourceName(value: string): string {
  return value.split("/").filter(Boolean).at(-1) ?? value;
}

function isAlreadyExists(error: unknown): boolean {
  return error instanceof GcpApiError && error.status === 409;
}

function firewallMatches(
  existing: GcpFirewall,
  project: string,
  network: string,
  expected: { readonly priority: number; readonly denied?: readonly unknown[]; readonly allowed?: readonly unknown[]; readonly sourceRanges?: readonly string[] },
): boolean {
  return firewallScopeMatches(existing, project, network) &&
    existing.priority === expected.priority &&
    JSON.stringify(existing.denied ?? []) === JSON.stringify(expected.denied ?? []) &&
    JSON.stringify(existing.allowed ?? []) === JSON.stringify(expected.allowed ?? []) &&
    JSON.stringify(existing.sourceRanges ?? []) === JSON.stringify(expected.sourceRanges ?? []);
}

/** An enabled ingress rule on the cmux-vms network that targets exactly the cmux-vm tag. */
function firewallScopeMatches(existing: GcpFirewall, project: string, network: string): boolean {
  const unscoped = (value: readonly string[] | undefined) => (value ?? []).length === 0;
  return sameNetwork(existing.network, project, network) &&
    existing.direction === "INGRESS" &&
    existing.disabled !== true &&
    JSON.stringify([...(existing.targetTags ?? [])].sort()) === JSON.stringify(["cmux-vm"]) &&
    // Any extra selector would narrow or widen what the rule applies to.
    unscoped(existing.sourceTags) && unscoped(existing.sourceServiceAccounts) &&
    unscoped(existing.targetServiceAccounts) && unscoped(existing.destinationRanges);
}

function assertSegment(value: string, name: string): void {
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(value)) throw new ProviderError("gcp", `invalid GCP ${name}`);
}

