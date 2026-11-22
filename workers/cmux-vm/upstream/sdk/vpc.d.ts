import type { FirewallRuleData, FirewallSpec } from "./firewall.js";
import type { FreestyleClient } from "./client.js";
import type { ListTunnelsResult } from "./tunnel.js";
/** A private network. */
export interface VpcData {
    id: string;
    /** The network's IPv4 CIDR block, when it has one. */
    cidr?: string | null;
    /** The network's IPv6 CIDR block — always present. */
    cidrV6: string;
    /** Your handle for this network; usable anywhere its id is. */
    slug?: string | null;
    /** The network's label, if it has one. Shown in place of the slug. */
    displayName?: string | null;
    createdAt: string;
}
export interface CreateVpcOptions {
    /**
     * Firewall rules created with the network and deleted with it.
     *
     * A bare endpoint means the network being created, so `{ source: {},
     * destination: {} }` is the most common thing anyone wants to say about a
     * network: its members can reach each other.
     *
     * @example
     * firewall: {
     *   rules: [
     *     // Members reach each other.
     *     { action: "allow", source: {}, destination: {} },
     *     // Members reach the Internet.
     *     { action: "allow", source: {}, destination: { public: true } },
     *   ],
     * }
     */
    firewall?: FirewallSpec;
    /**
     * The network's IPv4 CIDR. Networks are dual-stack; a `/24` out of
     * `10.0.0.0/8` is derived for you when omitted. Name one to pick the range
     * yourself — worth doing when the network must not overlap an estate you
     * reach over a tunnel, or needs more than 254 IPv4 members.
     */
    cidr?: string;
    /** The network's IPv6 CIDR; a unique-local /64 is derived when omitted. */
    cidrV6?: string;
    /** A URL-safe handle, unique within your account, usable anywhere its id is. */
    slug?: string;
    /**
     * A label for a slug that does not read as a name — one network per tenant
     * or per environment id. Shown in place of the slug.
     */
    displayName?: string;
}
export interface UpdateVpcOptions {
    /** An empty string clears it. */
    slug?: string;
    /** An empty string clears it. See {@link CreateVpcOptions.displayName}. */
    displayName?: string;
}
export interface ListVpcsResult {
    vpcs: VpcData[];
    totalCount: number;
}
/** Tunnels attached to one private network: `vpc.tunnels`. */
export declare class VpcTunnelNamespace {
    private readonly client;
    private readonly basePath;
    constructor(client: FreestyleClient, basePath: string);
    /**
     * List the tunnels attached to this network, newest first. Listings never
     * include a private key: one is returned only by
     * `freestyle.tunnels.create` and `freestyle.tunnels.rotateKey`.
     */
    list(): Promise<ListTunnelsResult>;
}
/** A handle to one private network. */
export declare class Vpc {
    readonly id: string;
    readonly tunnels: VpcTunnelNamespace;
    private readonly client;
    private readonly basePath;
    constructor(client: FreestyleClient, id: string);
    data(): Promise<VpcData>;
    update(options: UpdateVpcOptions): Promise<VpcData>;
    delete(): Promise<void>;
}
/** The `freestyle.vpc` namespace: create and manage private networks. */
export declare class VpcNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    /** List your private networks. */
    list(): Promise<ListVpcsResult>;
    /** Create a private network, optionally with the rules that say what it is for. */
    create(options?: CreateVpcOptions): Promise<{
        vpc: Vpc;
        vpcId: string;
        data: VpcData;
        firewallRules: FirewallRuleData[];
    }>;
    /** Fetch a private network by its id or its slug. */
    get(vpcIdOrSlug: string): Promise<VpcData>;
    /** A handle to a private network, without a network call. */
    ref(vpcIdOrSlug: string): Vpc;
    delete(vpcIdOrSlug: string): Promise<void>;
}
//# sourceMappingURL=vpc.d.ts.map