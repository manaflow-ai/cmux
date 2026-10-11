import type { FreestyleClient } from "./client.js";
/** The transport a matcher is restricted to. */
export type FirewallProtocol = "tcp" | "udp" | "icmp";
/**
 * What a rule does with the traffic it matches.
 *
 * Only `allow` exists today, and every rule states it rather than defaulting:
 * a default would mean that the day `deny` arrives, every rule written before
 * it silently acquires an action it never stated — and "what does this rule
 * do" is the one question a firewall rule must never answer by omission.
 */
export type FirewallAction = "allow";
/**
 * One end of a rule: which traffic this side matches.
 *
 * Fields intersect. `{ vpcId: "vpc-db", port: 5432, protocol: "tcp" }` is
 * "traffic in that network, on 5432, over TCP" — not three alternatives.
 *
 * Matchers select two different ways. `vmId`/`vpcId`/`tunnelId` select by
 * **identity**: they match that resource however it is addressed. `cidr`/
 * `public` select by **address**: `public: true` is every publicly routable
 * address, whoever owns it — another Freestyle VM reached at its public address
 * is reached over the public Internet like any other host. The two overlap, and
 * allow rules union, so that is simply more traffic allowed.
 *
 * The public Internet is `public: true`, never an empty matcher. An empty
 * matcher is the absence of a statement, and that is what
 * {@link VmFirewallSpec} uses to mean "the VM being created"; if emptiness
 * also meant the Internet, the most dangerous rule you can write would be the
 * one you get by forgetting a field.
 *
 * New selectors arrive as new optional fields, so this type only ever grows.
 */
export interface FirewallEndpoint {
    /** A single VM, by id or by your slug for it. Answers hold its id. */
    vmId?: string;
    /** Everything on one private network, by id or by your slug for it. Answers hold its id. */
    vpcId?: string;
    /**
     * Whatever is on the far side of one tunnel — the client that dials it, and
     * any remote range routed over it. Tunnels have no slug, so this is a tunnel
     * id: `tun-…`, or `wg-…` for one carried over from the per-VPC VPN records
     * tunnels replaced.
     *
     * The one selector that names traffic arriving from outside the platform by
     * identity rather than by address: the peer's addresses are the peer's
     * business, and can change without the rules admitting it changing too.
     */
    tunnelId?: string;
    /** An address range, IPv4 or IPv6, in canonical `network/prefix` form. */
    cidr?: string;
    /**
     * Every publicly routable address, whoever owns it — including another
     * Freestyle VM reached at its public address. Only `true` is meaningful —
     * omit the field otherwise — and it is not combined with `vmId` or `vpcId`.
     */
    public?: true;
    /** A single port, 1–65535. Requires {@link FirewallEndpoint.protocol}. */
    port?: number;
    protocol?: FirewallProtocol;
}
/**
 * A resource a rule cannot outlive. Deleting the resource deletes the rule, so
 * no rule is ever left naming something that no longer exists.
 */
export interface FirewallDependency {
    /** `"vm"`, `"vpc"`, or `"tunnel"` today; new selectors add new kinds. */
    kind: string;
    id: string;
    /**
     * Your handle for the named resource, when it has one — so a rule can say
     * what it points at without a lookup per id.
     */
    slug?: string | null;
    /** Your label for the named resource, under the same rules as `slug`. */
    displayName?: string | null;
}
/** An allowed path through the network: traffic matching `source` may reach `destination`. */
export interface FirewallRuleData {
    id: string;
    action: FirewallAction;
    source: FirewallEndpoint;
    destination: FirewallEndpoint;
    description?: string | null;
    /** What this rule dies with. See {@link FirewallDependency}. */
    dependencies: FirewallDependency[];
    createdAt: string;
    updatedAt: string;
}
export interface CreateFirewallRuleOptions {
    /** Required. `"allow"` is the only accepted value. */
    action: FirewallAction;
    source: FirewallEndpoint;
    destination: FirewallEndpoint;
    /** A free-form note, up to 1024 characters. */
    description?: string;
}
/**
 * A rule declared inside a create, where the resource being created has no id
 * yet.
 *
 * Exactly one endpoint may be left without an identity; that one *is* the new
 * VM. So `{ source: { public: true }, destination: { port: 443, protocol:
 * "tcp" } }` is inbound HTTPS to it, and `{ source: {}, destination: { public:
 * true, port: 443, protocol: "tcp" } }` is outbound HTTPS from it.
 */
export type InlineFirewallRule = CreateFirewallRuleOptions;
/** The `firewall` block of a create. */
export interface FirewallSpec {
    rules: InlineFirewallRule[];
}
/** @deprecated Renamed to {@link FirewallSpec}; both creates share one shape. */
export type VmFirewallSpec = FirewallSpec;
export interface ListFirewallRulesOptions {
    /**
     * Rules that apply to this VM: those naming it, plus those naming a private
     * network it is attached to.
     */
    vmId?: string;
    /** Rules naming this private network. */
    vpcId?: string;
    /** Rules naming this tunnel, by its id. */
    tunnelId?: string;
    limit?: number;
    offset?: number;
}
export interface ListFirewallRulesResult {
    /** Newest first. */
    rules: FirewallRuleData[];
    totalCount: number;
}
/**
 * A rule the SDK refused to send.
 *
 * Thrown before the request, so a mistake costs a stack trace rather than a
 * round trip. The server validates the same things and is the authority; this
 * only catches what can be seen without asking it. `path` names the offending
 * field, e.g. `"destination.port"`.
 */
export declare class FirewallRuleValidationError extends Error {
    /** The field the complaint is about, in dotted form. */
    readonly path: string;
    constructor(path: string, message: string);
}
/** Whether a matcher names what the traffic is, rather than only narrowing it. */
export declare function hasIdentity(endpoint: FirewallEndpoint): boolean;
/** Validate one matcher. `path` is `"source"` or `"destination"`. */
export declare function validateFirewallEndpoint(endpoint: unknown, path: string): void;
/** Validate a standalone rule, where both ends must say what they are. */
export declare function validateFirewallRule(rule: unknown): CreateFirewallRuleOptions;
/**
 * Validate the `firewall` block of a VM create.
 *
 * Exactly one end of each rule may be identity-less; that one is the VM being
 * created. Both would be a rule from the VM to itself, which allows nothing.
 * Neither would be a rule that never mentions the VM, so nothing would tie its
 * life to the VM's — and a rule outliving the create it was written in is
 * exactly the dangling reference the dependency model exists to prevent.
 */
export declare function validateFirewallSpec(spec: unknown, 
/** What the block hangs off, for the error messages. */
subject?: "VM" | "network"): FirewallSpec;
/** One end of a connection to ask about: everything true about the party. */
export interface TrafficParty {
    /**
     * Freestyle's own ingress — the web proxy serving a mapped domain, or the
     * SSH proxy. Always allowed, whatever your rules say.
     */
    platform?: boolean;
    vmId?: string;
    /** Every private network this party is on; a rule naming one of them matches. */
    vpcIds?: string[];
    tunnelId?: string;
    /** The address in use, when there is one — what `cidr` rules are tested against. */
    address?: string;
    /** Whether that address is publicly routable — what `public: true` matches. */
    public?: boolean;
    port?: number;
}
/** A connection to decide about. */
export interface TrafficDescription {
    source: TrafficParty;
    destination: TrafficParty;
    protocol?: FirewallProtocol;
}
/**
 * Why a connection would be allowed, or that it would not.
 *
 * `allowedByPlatform` means Freestyle itself delivered it — a mapped domain,
 * an SSH session — which no rule can block. `allowedByRule` names the rule.
 * `deniedByPlatform` runs the other way: platform policy closed the connection
 * and no rule opens it — today, outbound mail, which goes through an `smtp`
 * TLS rule instead.
 */
export type FirewallDecision = {
    outcome: "allowedByPlatform";
    side: "source" | "destination" | "both";
} | {
    outcome: "allowedByRule";
    ruleId: string;
} | {
    outcome: "deniedByPlatform";
    reason: "outboundMail";
} | {
    outcome: "denied";
};
/** Firewall rules: `freestyle.firewall.rules`. */
export declare class FirewallRulesNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    /**
     * Allow traffic from one place to another.
     *
     * @example
     * // Public Internet -> a VM, on HTTPS.
     * await freestyle.firewall.rules.create({
     *   action: "allow",
     *   source: { public: true },
     *   destination: { vmId: "vm-123456", port: 443, protocol: "tcp" },
     * });
     *
     * @example
     * // One private network -> another, on Postgres.
     * await freestyle.firewall.rules.create({
     *   action: "allow",
     *   source: { vpcId: "vpc-frontend" },
     *   destination: { vpcId: "vpc-backend", port: 5432, protocol: "tcp" },
     * });
     *
     * @throws {FirewallRuleValidationError} before any request, when the rule
     * cannot be well formed.
     */
    create(options: CreateFirewallRuleOptions): Promise<FirewallRuleData>;
    /**
     * List your rules, newest first. Pass `vmId` for the rules that apply to one
     * VM — those naming it, plus those naming a private network it is on.
     */
    list(options?: ListFirewallRulesOptions): Promise<ListFirewallRulesResult>;
    get(ruleId: string): Promise<FirewallRuleData>;
    /** Delete a rule. The resources it named are untouched. */
    delete(ruleId: string): Promise<void>;
}
/** The `freestyle.firewall` namespace. */
export declare class FirewallNamespace {
    private readonly client;
    readonly rules: FirewallRulesNamespace;
    constructor(client: FreestyleClient);
    /**
     * Ask whether a connection would be allowed, without changing anything.
     *
     * Useful for checking a rule set before you rely on it — and for confirming
     * what you already believe, e.g. that a mapped domain reaches a VM with no
     * rules at all.
     *
     * @example
     * // A mapped domain: allowed whatever your rules say.
     * await freestyle.firewall.evaluate({
     *   source: { platform: true },
     *   destination: { vmId: "vm-123456", port: 3000 },
     *   protocol: "tcp",
     * });
     * // => { outcome: "allowedByPlatform", side: "source" }
     */
    evaluate(traffic: TrafficDescription): Promise<FirewallDecision>;
}
//# sourceMappingURL=firewall.d.ts.map