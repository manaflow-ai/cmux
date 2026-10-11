import type { FirewallSpec } from "../firewall.js";
import type { TlsSpec } from "../tls.js";
export type VmState = "starting" | "running" | "pausing" | "paused" | "stopped";
/**
 * The base snapshots the platform publishes — the shared starting points every
 * account can boot from, qualified `{owner}/{slug}` because they belong to the
 * `freestyle` account rather than yours. Mirrors `catalog/snapshots.json`.
 *
 * A slug is a name, not a pointer: these are reassigned to a freshly built
 * snapshot on every catalog rebuild, which is the point — booting
 * `freestyle/ubuntu` gets you the current build. Pin a `sh-…` id instead when
 * you need the exact image to stay put.
 */
export type BaseSnapshotId = 
/** Ubuntu 24.04 LTS · 2 vCPU · 4 GiB · 16 GB. */
"freestyle/ubuntu-sm"
/** Ubuntu 24.04 LTS · 4 vCPU · 8 GiB · 32 GB. The platform default. */
 | "freestyle/ubuntu"
/** Ubuntu 24.04 LTS · 8 vCPU · 16 GiB · 64 GB. */
 | "freestyle/ubuntu-lg"
/** Ubuntu 24.04 LTS · 16 vCPU · 32 GiB · 128 GB. */
 | "freestyle/ubuntu-xl"
/** Ubuntu 24.04 LTS · 32 vCPU · 64 GiB · 128 GB. The largest size any plan can actually create. */
 | "freestyle/ubuntu-2xl"
/** Ubuntu 24.04 LTS · 64 vCPU · 128 GiB · 256 GB. Above every plan's per-VM cap. */
 | "freestyle/ubuntu-3xl"
/** BusyBox · 1 vCPU · 128 MiB · 1 GB. For when Ubuntu is too big to fit. */
 | "freestyle/busybox";
/**
 * Anywhere a snapshot is named: a `sh-…` id, your own slug for one, or a
 * public `{owner}/{slug}`. The {@link BaseSnapshotId} arm exists purely so
 * editors suggest the platform's catalog; `(string & {})` keeps every other
 * snapshot just as valid, and stops TypeScript from collapsing the union back
 * to a bare `string` and losing those suggestions.
 */
export type SnapshotIdOrSlug = BaseSnapshotId | (string & {});
export interface VmResources {
    /** vCPU count. */
    cpu: number;
    /** Memory, MiB. */
    memory: number;
    /** Disk, MiB. */
    storage: number;
}
/** An in-guest static route: reach `cidr` via the gateway `via`, inside the network's CIDR. */
export interface NetworkRoute {
    cidr: string;
    via: string;
    /**
     * Route priority, as `ip route`'s `metric`. Omit for the platform default.
     * Several routes to the same `cidr` at the same metric are installed as one
     * multipath route — the guest spreads flows across their gateways (turn on
     * `net.ipv4.fib_multipath_use_neigh` in the guest so a dead gateway drops
     * out) — while different metrics make a primary and a backup.
     */
    metric?: number;
}
/** A VM's place on a private network. */
export interface VmNetwork {
    /** @deprecated The network's id under its old name. Read `vpcId`. */
    vpc: string;
    /** The network's id, under the name the rest of the API uses. */
    vpcId?: string;
    /** The VM's IPv4 address inside the network; absent unless it asked for one. */
    ipv4?: string | null;
    /** The network's CIDR, alongside `ipv4`. */
    cidr?: string | null;
    /** The VM's IPv6 address, when the network has an IPv6 CIDR. */
    ipv6?: string | null;
    /** The network's IPv6 CIDR, alongside `ipv6`. */
    cidrV6?: string | null;
    routes: NetworkRoute[];
}
/** A VM as its owning account sees it. */
export interface VmData {
    id: string;
    state: VmState;
    /** URL-safe identifier, unique within the account; usable anywhere an id is. */
    slug?: string | null;
    /** The VM's label, if it has one. Shown in place of the slug. */
    displayName?: string | null;
    resources: VmResources;
    /** The snapshot the VM booted from, when it booted from one. */
    snapshotId?: string | null;
    /**
     * What that snapshot was called when the VM was created, qualified
     * `{owner}/{slug}` when it belongs to another account. Recorded once, so it
     * still names the origin after the snapshot is renamed or deleted.
     *
     * A name, not a pointer. Slugs can be reassigned, so boot from `snapshotId`.
     */
    sourceSnapshotSlugAtCreate?: string | null;
    /**
     * What that snapshot is called *now*, resolved when the VM is read. Absent
     * when it has no slug, and when it has been deleted — so against
     * `sourceSnapshotSlugAtCreate` it is what tells a renamed origin from a gone
     * one, without a second request.
     */
    sourceSnapshotSlug?: string | null;
    /** The snapshot's display name now, under the same rules. */
    sourceSnapshotDisplayName?: string | null;
    idleTimeoutSeconds?: number | null;
    /**
     * Delete the VM once it has gone this long without running. Absent means
     * never; 0 means the VM is ephemeral — deleted the moment it stops. Note
     * this can be set for you: some plans cap how long an unused VM is kept,
     * and the cap shows up here.
     */
    autoDeleteSeconds?: number | null;
    /**
     * Whether {@link Vm.autoDeleteSeconds} is your plan's doing rather than
     * yours. A window your plan set goes away by itself if you move to a plan
     * that does not reclaim unused VMs; one you set is yours and stays.
     */
    autoDeleteFromPlan?: boolean;
    /** Delete the VM this long after it was created, whatever it is doing. */
    ttlSeconds?: number | null;
    /** Pause the VM once one run has lasted this long, however busy it is. */
    maxRunSeconds?: number | null;
    /**
     * The VM's lifetime runtime budget in seconds. Spending it pauses the VM and
     * makes every later start a 409 until you raise this.
     */
    maxRunTotalSeconds?: number | null;
    /**
     * Seconds this VM has spent running, across every run it has ever had —
     * what {@link Vm.maxRunTotalSeconds} is measured against.
     */
    totalRunSeconds?: number;
    /** Whether the VM is booted again when it stops without being asked to. */
    automaticRestart?: boolean;
    /**
     * The VM's stable public IPv6 address — assigned at create and kept for the
     * VM's life, across restarts and moves between machines.
     */
    publicIpv6?: string | null;
    /**
     * The public IPv4 address the VM's outbound traffic is seen as coming from.
     * It belongs to your account rather than to this VM: every VM you own shares
     * it, and it survives restarts and moves between machines.
     *
     * Optional, and worth reading as optional even though a VM in service has
     * one: nothing promises an account keeps a single outbound address.
     */
    egressIpv4?: string | null;
    /**
     * The public IPv6 address the VM's outbound traffic is seen as coming from.
     * Today it is the VM's own {@link Vm.publicIpv6} — it appears from the
     * address it answers on — but read it as its own field: where a VM answers
     * and where it appears from are two questions, and {@link Vm.egressIpv4}
     * already answers them differently.
     */
    egressIpv6?: string | null;
    metadata: Record<string, string>;
    /** The placement constraints the VM was created with, when any. */
    placement?: VmPlacement | null;
    /** Total CPU time consumed, seconds. */
    cpuTimeSeconds?: number | null;
    lastNetworkActivity?: string | null;
    /** The private networks the VM is on (at most one today). */
    vpcs: VmNetwork[];
    /** @deprecated The same list as `vpcs`, kept for old readers. */
    networks: VmNetwork[];
    createdAt: string;
    updatedAt: string;
}
/**
 * Placement constraints for a VM, fixed at create time and honored again
 * whenever the platform relocates the VM.
 */
export interface VmPlacement {
    /**
     * Hard rules: the VM will not land on a topology domain already hosting a
     * VM matched by any rule's selector. Creation fails with a 409 when no
     * domain can satisfy every rule. At most 8 rules.
     */
    antiAffinity: VmAntiAffinityRule[];
}
/** One anti-affinity rule: "not on the same `topology` domain as any VM matching `selector`". */
export interface VmAntiAffinityRule {
    /** The domain the rule spreads across. `node` — the only domain today — means "not on the same host machine". */
    topology: "node";
    selector: VmLabelSelector;
}
/**
 * Selects VMs by their metadata: a VM matches when its metadata contains
 * every `matchLabels` entry. 1–8 entries; keys and values are limited to 63
 * characters, like the metadata they match.
 */
export interface VmLabelSelector {
    matchLabels: Record<string, string>;
}
/** Attach a VM to one of your private networks. A VM may be on at most one. */
export interface AttachNetwork {
    /** The network to join, by id or by your slug for it. */
    vpcId?: string;
    /** @deprecated The network to join, under its old name. Write `vpcId`. */
    vpc?: string;
    /**
     * The IPv4 address to take inside the network: an explicit address, `true`
     * to auto-allocate, or `false` to opt out. Omitted = allocate one, since
     * networks are dual-stack.
     */
    ipv4?: string | boolean;
    /**
     * The IPv6 address to take: an explicit address, `true` to auto-allocate
     * (the default), or `false` to opt out.
     */
    ipv6?: string | boolean;
    /** Static routes to install in the guest. */
    routes?: NetworkRoute[];
}
export interface CreateVmOptions {
    /** Boot from this snapshot: its id, your slug for it, or a public `{owner}/{slug}`. Omit for the platform default. */
    snapshotId?: SnapshotIdOrSlug | null;
    /**
     * URL-safe identifier, unique within your account: 1–63 chars of
     * `[a-z0-9-]`, no leading, trailing, or repeated hyphens.
     *
     * How you address the VM everywhere — the API, the CLI, the dashboard.
     */
    slug?: string | null;
    /** Take `slug` from whichever VM currently holds it; the holder keeps running, slugless. Requires `slug`. */
    reassignSlug?: boolean;
    /**
     * A label for a slug that does not read as a name — one minted per run,
     * per commit or per tenant (`run-7f3a91c2`). Shown in place of the slug.
     */
    displayName?: string | null;
    /**
     * Pause the VM after this many seconds without network activity. Traffic
     * over its public address counts, as does anything typed in a terminal
     * session; -1 (or omitting this) means it is never paused for being idle.
     */
    idleTimeoutSeconds?: number | null;
    /**
     * Delete the VM once it has gone this many seconds without running. Every
     * start resets the clock, and a running VM is never deleted for this.
     * -1 (or omitting this) means never; 0 makes the VM ephemeral — deleted
     * the moment it stops.
     *
     * Some plans cap how long an unused VM is kept. On those, omitting this (or
     * sending -1) gets you the cap rather than "keep forever", and asking for
     * longer is a 400.
     */
    autoDeleteSeconds?: number | null;
    /**
     * Delete the VM this many seconds after it is created, whatever it is doing
     * at the time. A deadline, not an idle window: nothing resets it. -1 (or
     * omitting this) means no deadline.
     */
    ttlSeconds?: number | null;
    /**
     * Pause the VM once a single run has lasted this many seconds, however busy
     * it is. Starting it again gives it a fresh budget — unlike
     * {@link CreateVmOptions.maxRunTotalSeconds}, which never resets. -1 (or
     * omitting this) means no cap.
     */
    maxRunSeconds?: number | null;
    /**
     * How many seconds this VM may run in total, ever. Spending the budget
     * pauses the VM, and every later start is a 409 until you raise it. -1 (or
     * omitting this) means no budget.
     */
    maxRunTotalSeconds?: number | null;
    /**
     * Boot the VM again if it stops without you asking it to — the VMM crashes,
     * the guest kernel panics, the machine it runs on loses power. Defaults to
     * `true`.
     *
     * It never fights you: shutting the VM down, pausing it, running `poweroff`
     * inside it, or hitting an idle timeout all leave it off. This only decides
     * who gets the last word when a *failure* stops it.
     */
    automaticRestart?: boolean;
    /** Put the VM on your private networks. Omit to leave it off them. At most one is accepted today. */
    vpcs?: AttachNetwork[];
    /** @deprecated The same list as `vpcs`; write `vpcs`. */
    networks?: AttachNetwork[];
    /** Up to 64 metadata entries; keys and values are limited to 63 characters. */
    metadata?: Record<string, string>;
    /**
     * Placement constraints (anti-affinity), fixed for the VM's life. Selectors
     * match the metadata of your other VMs.
     */
    placement?: VmPlacement | null;
    /**
     * Firewall rules created with the VM and deleted with it.
     *
     * Inside this block an endpoint with no identity means the VM being created,
     * which is how a rule names a VM whose id does not exist yet. See
     * {@link FirewallSpec}.
     *
     * @example
     * firewall: {
     *   rules: [
     *     // Inbound HTTPS from anywhere.
     *     { action: "allow", source: { public: true }, destination: { port: 443, protocol: "tcp" } },
     *     // Outbound HTTPS to anywhere.
     *     { action: "allow", source: {}, destination: { public: true, port: 443, protocol: "tcp" } },
     *   ],
     * }
     *
     * Required. A VM gets nothing implicitly — no outbound Internet, no inbound —
     * so a VM that wants either says so here. `{ rules: [] }` is a legitimate
     * answer: a VM reachable only through a mapped domain or SSH.
     */
    firewall: FirewallSpec;
    /**
     * TLS rules created with the VM and deleted with it — named sessions the VM
     * may serve or open. Optional, unlike `firewall`: a TLS rule is a grant
     * layered on top of the firewall's packet decision, never a baseline a VM
     * must state.
     *
     * Inside this block an endpoint with no identity means the VM being created,
     * exactly as in `firewall`. See {@link TlsSpec}.
     *
     * @example
     * tls: {
     *   rules: [
     *     // Publish app.acme.com to port 8000 on this VM.
     *     { action: "allow", domain: "app.acme.com", source: { public: true }, destination: { port: 8000 } },
     *   ],
     * }
     */
    tls?: TlsSpec;
}
export interface UpdateVmOptions {
    /** Change the slug; an empty string clears it. */
    slug?: string;
    /** Take `slug` from whichever VM currently holds it. */
    reassignSlug?: boolean;
    /**
     * Change the display label; an empty string clears it. See
     * {@link CreateVmOptions.displayName}.
     */
    displayName?: string;
    /** Seconds of network idleness before the VM is paused; -1 removes the timeout. */
    idleTimeoutSeconds?: number;
    /**
     * Seconds of not running before the VM is deleted; -1 removes the window
     * (on a plan that caps it, -1 puts you back on the cap rather than off it),
     * and 0 makes the VM ephemeral — deleted the moment it stops, or right away
     * if it is already stopped.
     */
    autoDeleteSeconds?: number;
    /**
     * Seconds from creation — not from now — before the VM is deleted; -1
     * removes the deadline. A value already in the past deletes it shortly.
     */
    ttlSeconds?: number;
    /** Seconds one run may last before the VM is paused; -1 removes the cap. */
    maxRunSeconds?: number;
    /**
     * The lifetime runtime budget in seconds; -1 removes it. Raising this past
     * `totalRunSeconds` is how you start a VM that has spent its budget.
     */
    maxRunTotalSeconds?: number;
    /**
     * Turn automatic restart on or off. Applies to the next failure: this neither
     * boots a stopped VM nor stops a running one.
     */
    automaticRestart?: boolean;
    /** Metadata merged into the VM. Only the keys you send are touched; send an empty value to remove one. */
    metadata?: Record<string, string>;
}
export interface ResizeVmOptions {
    /** vCPU count. Grow-only. Applies live to a running VM. */
    cpu?: number;
    /** Memory, MiB. Grow-only. Applies live to a running VM. */
    memory?: number;
    /** Disk, MiB. Grow-only, and only while the VM is running. */
    storage?: number;
}
export interface ExecOptions {
    /** The command line, run through the guest's shell. */
    command: string;
    /**
     * Guest Linux user to run as. Omit for the VM's default user: the account
     * holding uid 1000, or `root` in an image that has no such account. Required
     * when an identity grant restricts users.
     */
    linuxUser?: string;
    /** Wall-clock limit, milliseconds. 1–300000; defaults to the guest's own. */
    timeoutMs?: number;
    /** Extra environment variables. Keys must be valid POSIX names. */
    env?: Record<string, string>;
    /** Base64-encoded stdin, up to 1 MiB decoded. */
    stdin?: string;
}
export interface ExecResult {
    stdout?: string | null;
    stderr?: string | null;
    /** The command's exit status; null if it was killed by the timeout. */
    statusCode?: number | null;
}
export interface ListVmsOptions {
    /** Only VMs in this state. */
    state?: VmState;
    /** Exact slug match. */
    slug?: string;
    /** Only VMs booted from this snapshot. */
    snapshotId?: SnapshotIdOrSlug;
    /** Comma-separated `key:value` pairs, e.g. `env:prod,region:us-west`. */
    metadata?: string;
    limit?: number;
    offset?: number;
}
export interface ListVmsResult {
    vms: VmData[];
    totalCount: number;
    runningCount: number;
    startingCount: number;
    pausingCount: number;
    pausedCount: number;
    stoppedCount: number;
}
export interface DirEntry {
    name: string;
    /** `file`, `directory`, or `symlink`. */
    kind: string;
}
export interface FileStat {
    /** Size in bytes. */
    size: number;
    isFile: boolean;
    isDirectory: boolean;
    isSymlink: boolean;
    /** Octal mode, e.g. `0644`. */
    permissions: string;
    owner: string;
    group: string;
    modified: string;
}
//# sourceMappingURL=types.d.ts.map