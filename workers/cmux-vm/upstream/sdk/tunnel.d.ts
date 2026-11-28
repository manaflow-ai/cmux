import type { FreestyleClient } from "./client.js";
/**
 * One private network on the far side of a tunnel: the network, your address
 * inside it, and the `[Peer]` key that carries it.
 */
export interface TunnelAttachment {
    vpcId: string;
    /**
     * Your IPv4 address inside the private network, absent on a v6-only
     * attachment. It belongs to this tunnel for as long as the network stays
     * attached, so you can write it into configs and rules.
     */
    ipv4?: string | null;
    /** Your IPv6 address inside the private network, under the same rules. */
    ipv6?: string | null;
    /** @deprecated The primary address, whichever family. Read `ipv4`/`ipv6`. */
    address: string;
    /** @deprecated The second-family address. Read `ipv4`/`ipv6`. */
    secondaryAddress?: string | null;
    vpcCidr: string;
    /** The CIDRs the gateway routes to this network. */
    allowedIps: string[];
    /**
     * Ranges behind your client that this network routes through the tunnel (a
     * site-to-site grant). VMs reach them with an ordinary route via `address`.
     * Absent when the attachment has none.
     */
    remoteCidrs?: string[];
    /**
     * Whether this attachment is a network exit: your client forwards for
     * destinations that are not its own address, and members route through it
     * with an ordinary route via the attachment's address. Absent when false.
     */
    exit?: boolean;
    createdAt: string;
}
/**
 * A tunnel: your WireGuard identity on the platform. It exists until you
 * delete it: connect, disconnect and reconnect as often as you like — a
 * session is set up on the handshake that needs it, so an idle tunnel costs
 * nothing and never expires. A tunnel routes nowhere until you attach a
 * private network to it; attach several and one WireGuard interface reaches
 * them all.
 */
export interface TunnelData {
    /** @deprecated The tunnel's id under its old name. Read `tunnelId`. */
    id: string;
    /**
     * The tunnel's id, under the name the rest of the API uses for it — a
     * firewall rule says `tunnelId`, so the tunnel does too.
     */
    tunnelId: string;
    /**
     * Your handle for this tunnel, if you gave it one. Usable anywhere the id
     * is, in place of it.
     */
    slug?: string | null;
    /** Your label for this tunnel, if you gave it one. Shown in place of the slug. */
    displayName?: string | null;
    /**
     * A complete WireGuard config file, fixed for the life of the tunnel:
     * attaching and detaching networks never changes it, so bring it up once
     * and manage what it reaches through the API. `PrivateKey` is blank except
     * on {@link TunnelsNamespace.create} and {@link TunnelsNamespace.rotateKey},
     * the only two calls that mint a keypair.
     */
    clientConfig: string;
    /** Host to dial. */
    endpointHost?: string | null;
    endpointPort: number;
    clientPublicKey: string;
    /** The one `[Peer]` public key in your config. */
    serverPublicKey: string;
    /**
     * Your fixed addresses inside the tunnel. Only the gateway ever sees them:
     * each attached network sees an address inside its own subnet instead
     * (`attachments[].address`).
     */
    clientAddressV4: string;
    clientAddressV6: string;
    /**
     * The ranges your client routes through the tunnel — its `AllowedIPs`,
     * fixed at create. A network can only be attached if its CIDRs fall inside
     * these.
     */
    routes: string[];
    /** The private networks on the far side, oldest attachment first. */
    attachments: TunnelAttachment[];
    createdAt: string;
    updatedAt: string;
}
/**
 * A tunnel plus a client private key — returned only by the two calls that
 * mint a keypair. The key is never stored and cannot be read back. Empty when
 * you supplied your own public key.
 */
export interface CreatedTunnel extends TunnelData {
    /** Returned once. Already embedded in `clientConfig`. */
    clientPrivateKey: string;
}
export interface CreateTunnelOptions {
    /**
     * A URL-safe handle, unique within your account: lowercase letters, digits
     * and single hyphens, up to 63 characters. Address the tunnel by it instead
     * of by id.
     */
    slug?: string;
    /**
     * A label for a slug that does not read as a name — a tunnel per device id,
     * per session. Shown in place of the slug.
     */
    displayName?: string;
    /**
     * The public key of a keypair you already hold. Omit to have one minted for
     * you; supply it and the platform never sees a private key at all.
     */
    clientPublicKey?: string;
    /**
     * The ranges your client will route through the tunnel — its `AllowedIPs`,
     * fixed for the tunnel's life so attaching and detaching networks never
     * changes your config. Omit for the default (`10.0.0.0/8` and `fd00::/8`),
     * which covers every network with default addressing. Only networks whose
     * CIDRs fall inside the routes can be attached.
     */
    routes?: string[];
    /**
     * Networks to attach in the same call, so one request yields a tunnel that
     * already routes somewhere. All-or-nothing: if any attachment is refused,
     * nothing is created.
     */
    vpcs?: CreateTunnelVpc[];
}
/** One network named at create, with the same address choices as an attach. */
export interface CreateTunnelVpc {
    /** The network to attach: a VPC id, or your slug for it. */
    vpcId?: string;
    /** @deprecated The network to attach, under its old name. Write `vpcId`. */
    vpc?: string;
    /** The address you want inside it; omit to be assigned one. */
    ipv4?: string;
    /** An explicit IPv6 address instead; only one may be set. */
    ipv6?: string;
    /** Ranges behind your client this network may route to; see {@link AttachVpcOptions.remoteCidrs}. */
    remoteCidrs?: string[];
    /** See {@link AttachVpcOptions.exit}. */
    exit?: boolean;
}
export interface AttachVpcOptions {
    /**
     * The address you want inside the private network. Omit to be assigned one.
     * It must be free: a VM already holding it makes this a conflict, and once
     * yours, no VM can be given it.
     */
    ipv4?: string;
    /**
     * An explicit IPv6 address, equivalent to passing one in `ipv4`; only one
     * may be set.
     */
    ipv6?: string;
    /**
     * Ranges behind your client that this network routes through the tunnel — a
     * site-to-site setup where your client machine forwards for other hosts on
     * its side. Hosts inside these ranges keep their real addresses inside the
     * network. A range carved out of the network's own CIDR just works: VMs
     * reach it with no configuration, and the range is excluded from VM address
     * allocation (it must be free when granted). A range outside the network's
     * CIDRs is reached by giving VMs a route via the attachment's `address`. A
     * range may not straddle the network's CIDR boundary, nor overlap a range
     * another tunnel already grants this network.
     */
    remoteCidrs?: string[];
    /**
     * Make your client this network's exit — a router members can name as a
     * next hop. A VM routes through it with an ordinary NIC route via the
     * attachment's address, and everything it sends the exit — whatever the
     * destination — is forwarded to your client, which is expected to NAT it
     * onward. Several attachments per network may be exits: members choose per
     * route, so two exits and two same-metric routes are a redundant pair, and
     * a dead exit stops being ARP/NDP-answered so the others take over by
     * themselves.
     */
    exit?: boolean;
}
export interface UpdateTunnelOptions {
    /** An empty string clears it. */
    slug?: string;
    /** An empty string clears it. See {@link CreateTunnelOptions.displayName}. */
    displayName?: string;
}
export interface ListTunnelsResult {
    tunnels: TunnelData[];
    totalCount: number;
}
export declare class TunnelsNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    /** List your tunnels, newest first. Listings never include a private key. */
    list(): Promise<ListTunnelsResult>;
    /**
     * Create a tunnel, optionally attaching networks in the same call
     * (`vpcs`, all-or-nothing). This is a one-time setup: the tunnel lives
     * until you delete it and its config never changes — save it, bring it up
     * once, and manage which networks it reaches by attaching and detaching
     * them.
     */
    create(options?: CreateTunnelOptions): Promise<CreatedTunnel>;
    /** Read one tunnel by its id or its slug. Its config comes back with a blank `PrivateKey`. */
    get(tunnelIdOrSlug: string): Promise<TunnelData>;
    /**
     * Rename a tunnel or change its slug. Only the labels move: the keys,
     * addresses, routes and attached networks are untouched, so a connected
     * client sees nothing change and the config you saved keeps working.
     */
    update(tunnelIdOrSlug: string, options: UpdateTunnelOptions): Promise<TunnelData>;
    /**
     * Replace a tunnel's keys, keeping its id and every attached network's
     * address. Use this if you lost the config or need to revoke one that
     * leaked.
     */
    rotateKey(tunnelIdOrSlug: string, options?: {
        clientPublicKey?: string;
    }): Promise<CreatedTunnel>;
    /** Delete a tunnel, detaching every network as it goes. */
    delete(tunnelIdOrSlug: string): Promise<void>;
    /**
     * Attach a private network to a tunnel. The tunnel gains an address inside
     * the network — what that network's VMs see as your address — and a
     * connected client can reach it immediately, with no config change. The
     * network's CIDRs must fall inside the tunnel's routes and must not
     * overlap another attached network's.
     */
    attachVpc(tunnelIdOrSlug: string, vpcIdOrSlug: string, options?: AttachVpcOptions): Promise<TunnelData>;
    /**
     * Detach a private network from a tunnel: it stops being reachable and the
     * tunnel's address inside it is released. The tunnel — and any connected
     * client — carries on untouched.
     */
    detachVpc(tunnelIdOrSlug: string, vpcIdOrSlug: string): Promise<TunnelData>;
}
//# sourceMappingURL=tunnel.d.ts.map