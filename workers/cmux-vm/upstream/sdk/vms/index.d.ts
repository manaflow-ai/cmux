import type { FirewallRuleData, ListFirewallRulesResult } from "../firewall.js";
import type { TlsRuleData } from "../tls.js";
import type { FreestyleClient } from "../client.js";
import { VmFilesystem } from "./fs.js";
import { VmLinuxUserPty, VmPty } from "./pty.js";
import { VmSnapshotsNamespace, type SnapshotCreated, type CreateSnapshotOptions } from "./snapshots.js";
import type { CreateVmOptions, ExecOptions, ExecResult, ListVmsOptions, ListVmsResult, ResizeVmOptions, UpdateVmOptions, VmData } from "./types.js";
export * from "./types.js";
export * from "./fs.js";
export * from "./pty.js";
export * from "./snapshots.js";
/**
 * A handle to one VM, keyed by its id or slug. Every method hits the API
 * fresh (nothing is cached); `data()` re-fetches and returns the current
 * record.
 */
export declare class Vm {
    readonly id: string;
    readonly fs: VmFilesystem;
    readonly pty: VmPty;
    private readonly client;
    private readonly basePath;
    constructor(client: FreestyleClient, id: string);
    /** Fetch the current VM record. */
    data(): Promise<VmData>;
    /**
     * The firewall rules that apply to this VM: those naming it, plus those
     * naming a private network it is attached to.
     *
     * Deleting the VM deletes the rules that name it, so this never reports a
     * rule over a machine that no longer exists.
     */
    firewallRules(): Promise<ListFirewallRulesResult>;
    /** Rename the VM, change its slug or idle timeout, or merge in metadata. */
    update(options: UpdateVmOptions): Promise<VmData>;
    /** Boot a stopped VM, or resume a paused one. */
    start(): Promise<VmData>;
    /** Freeze a running VM, keeping its memory so a later start resumes it exactly. */
    pause(): Promise<VmData>;
    /**
     * Change vCPU, memory, or disk. Every axis is grow-only. vCPU and memory
     * apply live to a running VM, on resume for a paused one, and at the next
     * boot for a stopped one. Growing the disk needs a running VM.
     */
    resize(options: ResizeVmOptions): Promise<VmData>;
    /** Permanently destroy the VM */
    delete(): Promise<void>;
    /**
     * Run a command in the guest and wait for it to finish. A non-zero exit
     * status is still a successful call — check `statusCode`, which is null if
     * the command was killed by its timeout.
     */
    exec(options: string | ExecOptions): Promise<ExecResult>;
    /** Scope process and terminal operations to one existing in-guest Linux user. */
    linuxUser(linuxUser: string): VmLinuxUser;
    /**
     * Capture the VM's exact state, memory and disk. The VM must be running or
     * paused. The new snapshot is private and fully materialized when this
     * resolves.
     */
    snapshot(options?: CreateSnapshotOptions): Promise<SnapshotCreated>;
}
/** A VM handle whose process-spawning operations run as one Linux user. */
export declare class VmLinuxUser {
    private readonly vm;
    private readonly linuxUser;
    readonly pty: VmLinuxUserPty;
    constructor(vm: Vm, linuxUser: string);
    exec(options: string | Omit<ExecOptions, "linuxUser">): Promise<ExecResult>;
}
/** The `freestyle.vms` namespace: create, list, and manage VMs. */
export declare class VmsNamespace {
    private readonly client;
    readonly snapshots: VmSnapshotsNamespace;
    constructor(client: FreestyleClient);
    /**
     * Boot a new VM.
     *
     * `firewall` is required: a VM gets nothing implicitly, so state what it may
     * reach. `{ rules: [] }` is a legitimate answer — a VM reachable only through
     * a mapped domain or SSH.
     *
     * @example
     * const { vm, vmId } = await freestyle.vms.create({
     *   firewall: {
     *     rules: [
     *       // This VM can reach the Internet. Without it, it cannot.
     *       { action: "allow", source: {}, destination: { public: true } },
     *     ],
     *   },
     * });
     * await vm.exec("echo hello");
     */
    create(options: CreateVmOptions): Promise<{
        vm: Vm;
        vmId: string;
        data: VmData;
        firewallRules: FirewallRuleData[];
        /** The rules the create's `tls` block produced; empty without one. */
        tlsRules: TlsRuleData[];
    }>;
    /**
     * List your VMs.
     *
     * @example
     * const { vms } = await freestyle.vms.list();
     */
    list(options?: ListVmsOptions): Promise<ListVmsResult>;
    /**
     * Fetch a VM by its id or its slug.
     *
     * @example
     * const vm = await freestyle.vms.get("vmId");
     */
    get(vmIdOrSlug: string): Promise<VmData>;
    /** A handle to a VM, without a network call. */
    ref(vmIdOrSlug: string): Vm;
    delete(vmIdOrSlug: string): Promise<void>;
}
//# sourceMappingURL=index.d.ts.map