// An in-memory VMProvider for tests — the interface's second implementer, so the
// contract stays general instead of ossifying around one provider's shape.
//
// Feature toggles mirror how real drivers differ: an optional method is either
// present (and works against the in-memory state) or absent entirely, because
// capability derivation (`vmCapabilitiesOf`) reads method presence, never a
// provider name. Tests that need a declared override pass `capabilities`.
import type {
  AttachEndpoint,
  AttachOptions,
  AttachTransport,
  CreateOptions,
  ExecOptions,
  ExecResult,
  ProviderId,
  SnapshotRef,
  SSHEndpoint,
  VMHandle,
  VmCapabilities,
  VMProvider,
  VMStats,
  VMStatus,
} from "./types";

export type MockVMFeatures = {
  readonly fork?: boolean;
  readonly stats?: boolean;
  readonly ports?: boolean;
  readonly ssh?: boolean;
  readonly websocket?: boolean;
  readonly cmuxRemote?: boolean;
};

type MockVM = {
  handle: VMHandle;
  execScript?: (command: string) => ExecResult;
};

export class MockVMProvider implements VMProvider {
  readonly id: ProviderId;
  readonly capabilities?: Partial<VmCapabilities>;
  readonly attachTransports?: readonly AttachTransport[];

  private readonly vms = new Map<string, MockVM>();
  private readonly snapshots = new Map<string, string>(); // snapshotId -> image
  private counter = 0;

  // Optional members are assigned in the constructor so an off feature leaves
  // the method genuinely absent (`typeof x.fork === "undefined"`).
  fork?: (vmId: string) => Promise<VMHandle>;
  getStats?: (vmId: string) => Promise<VMStats>;
  openPort?: (
    vmId: string,
    port: number,
  ) => Promise<{ url: string; token: string; openUrl: string; expiresAtMs?: number }>;
  openSSH?: (vmId: string) => Promise<SSHEndpoint>;
  revokeSSHIdentity?: (identityHandle: string) => Promise<void>;
  openAttach?: (vmId: string, options?: AttachOptions) => Promise<AttachEndpoint>;

  constructor(options?: {
    readonly id?: ProviderId;
    readonly features?: MockVMFeatures;
    readonly capabilities?: Partial<VmCapabilities>;
  }) {
    this.id = options?.id ?? ("freestyle" as ProviderId);
    this.capabilities = options?.capabilities;
    const features = options?.features ?? {};
    const transports: AttachTransport[] = [];
    if (features.cmuxRemote !== false) transports.push("cmux-remote");
    if (features.websocket) transports.push("websocket");
    if (features.ssh) transports.push("ssh");
    this.attachTransports = transports;

    if (features.fork) {
      this.fork = async (vmId) => {
        const source = this.mustGet(vmId);
        return this.insert(source.handle.image);
      };
    }
    if (features.stats) {
      this.getStats = async (vmId) => {
        this.mustGet(vmId);
        return { state: "awake", sampledAt: Date.now(), cpus: 2, memoryTotalMb: 2048 };
      };
    }
    if (features.ports) {
      this.openPort = async (vmId, port) => {
        this.mustGet(vmId);
        const token = `mock-port-token-${port}`;
        const url = `https://mock.invalid/vm/${vmId}/port/${port}`;
        return { url, token, openUrl: `${url}?cmux_token=${token}` };
      };
    }
    if (features.ssh) {
      this.openSSH = async (vmId) => {
        this.mustGet(vmId);
        return {
          transport: "ssh",
          host: "mock.invalid",
          port: 22,
          username: "cmux",
          publicKeyFingerprint: null,
          credential: { kind: "password", value: "mock" },
          identityHandle: `mock-identity-${vmId}`,
        };
      };
      this.revokeSSHIdentity = async () => {};
    }
    if (features.websocket) {
      this.openAttach = async (vmId) => {
        this.mustGet(vmId);
        return {
          transport: "websocket",
          url: `wss://mock.invalid/vm/${vmId}/pty`,
          headers: {},
          token: "mock",
          sessionId: "mock-session",
          attachmentId: "mock-attachment",
          expiresAtUnix: Math.floor(Date.now() / 1000) + 60,
        };
      };
    }
  }

  scriptExec(vmId: string, script: (command: string) => ExecResult): void {
    this.mustGet(vmId).execScript = script;
  }

  private mustGet(vmId: string): MockVM {
    const vm = this.vms.get(vmId);
    if (!vm) throw new Error(`mock VM not found: ${vmId}`);
    return vm;
  }

  private insert(image: string): VMHandle {
    const id = `mock-vm-${++this.counter}`;
    const handle: VMHandle = {
      provider: this.id,
      providerVmId: id,
      status: "running",
      image,
      createdAt: Date.now(),
    };
    this.vms.set(id, { handle });
    return handle;
  }

  async create(options: CreateOptions): Promise<VMHandle> {
    return this.insert(options.image);
  }

  async destroy(vmId: string): Promise<void> {
    this.vms.delete(vmId);
  }

  async getStatus(vmId: string): Promise<VMStatus> {
    return this.vms.get(vmId)?.handle.status ?? "destroyed";
  }

  async pause(vmId: string): Promise<void> {
    this.mustGet(vmId).handle.status = "paused";
  }

  async resume(vmId: string): Promise<VMHandle> {
    const vm = this.mustGet(vmId);
    vm.handle.status = "running";
    return vm.handle;
  }

  async exec(vmId: string, command: string, _opts?: ExecOptions): Promise<ExecResult> {
    const vm = this.mustGet(vmId);
    if (vm.execScript) return vm.execScript(command);
    return { exitCode: 0, stdout: "", stderr: "" };
  }

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    const vm = this.mustGet(vmId);
    const id = `mock-snapshot-${++this.counter}`;
    this.snapshots.set(id, vm.handle.image);
    return { id, createdAt: Date.now(), name };
  }

  async restore(snapshotId: string): Promise<VMHandle> {
    const image = this.snapshots.get(snapshotId);
    if (image === undefined) throw new Error(`mock snapshot not found: ${snapshotId}`);
    return this.insert(image);
  }
}
