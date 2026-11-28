import type { FreestyleClient } from "./client.js";
/**
 * How the edge treats the session's bytes.
 *
 * **`http` is the default.** A rule without a protocol is HTTP; the edge
 * terminates the session so a {@link TlsTransform} (header injection) can act on
 * it.
 *
 * `postgres` is served on **5432**. Two shapes use it. **Ingress** publishes a
 * database by name: the edge terminates the TLS your certificate covers and
 * splices the session to the VM's Postgres port, so your own server still
 * authenticates the client end to end. **Egress** is the interesting one — with a
 * {@link PostgresTransform} the guest connects to a vendor's database with *no
 * password at all*, and the edge completes the real handshake upstream
 * (SCRAM-SHA-256, MD5, or cleartext) with credentials the guest has never held.
 * Connect with `sslmode=require` or stricter: an unencrypted session offers no
 * SNI, and the name is what selects a rule.
 *
 * `minecraft` is served on **25565** for Minecraft: Java Edition. The edge reads
 * the server address out of the client's handshake — the routing key, exactly as
 * `Host` is over HTTP — and then splices the session through to the VM. Point the
 * domain's A/AAAA records at the edge as you would for a web domain and players
 * dial it directly; no SRV record is needed while they use the default port. It
 * terminates nothing, so it carries no transform and needs no certificate. A
 * **status ping** (the multiplayer list) never starts a stopped VM — it is
 * answered with a "sleeping" line instead; a player **joining** is what wakes it.
 *
 * `tcp` is opaque passthrough, and it shares **443** with `http` — the client
 * dials HTTPS either way, and the edge tells them apart by matching the SNI in
 * the ClientHello against your rules. Where an `http` rule has the edge
 * terminate the session, a `tcp` rule has it splice: the bytes go to your VM
 * untouched and **your own certificate** answers the handshake. Ask for it when
 * the session is yours to end — mutual TLS you verify yourself, a protocol over
 * TLS that is not HTTP, a certificate you would rather issue than delegate. The
 * cost is everything the edge could otherwise have done: no transform, no
 * certificate issued for the name, and no HTTP/3 (there is no TCP to splice).
 * It is **public ingress only** — `{ public: true } -> { vmId, port }`.
 *
 * `imap` and `imaps` are served on **993**, and share it the way `http` and
 * `tcp` share 443 — one door, one route table, and the rule decides whether the
 * edge is in the session. `imap` terminates: the edge answers the handshake
 * with a certificate issued for the name and forwards *plain* IMAP to your
 * server, so the rule lands on 143 by default and you run an unadorned mail
 * server. `imaps` splices: your server terminates its own TLS on its own
 * certificate and the platform holds no key to a byte of the mail, at the price
 * of your obtaining that certificate and renewing it. Neither carries a
 * transform — the credential in an IMAP session is your user's own. Both are
 * public ingress only.
 *
 * `smtp` is served on **25** (MX delivery), **587** (submission) and **465**
 * (implicit TLS). It is the one protocol whose `domain` is not a hostname: mail
 * is routed by the **envelope recipient**, so a rule's name is a mail route and
 * may carry a mailbox. `bot@acme.com` serves that one address, `acme.com` serves
 * every mailbox at the name, `bot@*.acme.com` serves that mailbox at any
 * subdomain and `*.acme.com` serves every mailbox at any subdomain — most
 * specific wins. That is what lets a single wildcard MX record at `*.acme.com`
 * give every subdomain its own VM, and what lets `agent-7@acme.com` land
 * somewhere different from `sales@acme.com`; no SNI could express either, which
 * is why the envelope and not the handshake is the routing key. Point an **MX**
 * record at the edge rather than an A/AAAA one. The edge speaks SMTP as far as
 * the first `RCPT TO`, then replays the envelope to your VM and splices — your
 * own server still accepts or refuses the mail itself. **Egress** works like
 * `postgres`: with an {@link SmtpTransform} the guest submits mail through a
 * provider with *no password at all*, and the edge completes `AUTH` upstream
 * with credentials the guest has never held. Your VM sees the edge as the
 * connecting peer, so a guest that scores senders by IP will score the edge.
 *
 * `socks5` (1080) is the mirror image of all of them and the only **egress-only**
 * protocol. Your VM opens SOCKS5 to the platform edge offering *no
 * authentication*, names its destination inside the request, and the edge opens
 * the session onward through your own proxy provider using the credentials a
 * {@link Socks5Transform} carries — so the workload can use the subscription
 * without ever being able to read it. Nothing is terminated: after the proxy
 * answers, the edge copies bytes it cannot decrypt, and your TLS runs end to end
 * to the real origin. Because the destination rides the SOCKS request rather
 * than DNS, a `socks5` rule's `domain` is an **allow-list** and not a name
 * anything resolves — `*` ("everything this VM opens goes through my proxy") is
 * the shape most people want and is accepted here alone. The destination names
 * the proxy: `{ vmId } -> { host: "gate.provider.com", port: 1080 }`.
 *
 * A **VM-to-VM internal service** (`{ vmId | vpcId } -> { vmId }`) is
 * edge-brokered like every other shape (the source opens the name at the edge's
 * front door for its protocol, and the edge forwards to the target VM's port) —
 * and it cannot carry a transform yet.
 */
export type TlsProtocol = "tcp" | "http" | "postgres" | "minecraft" | "smtp" | "imap" | "imaps" | "socks5";
/**
 * What a rule does with the session it matches.
 *
 * Only `allow` exists today, and every rule states it rather than defaulting —
 * the same discipline the firewall keeps, and for the same reason. A default
 * would mean that the day `deny` arrives (here it plausibly does: "allow every
 * domain except this one" is a real thing to want, given the `*` wildcard), every
 * rule written before it silently acquires an action it never stated.
 */
export type TlsAction = "allow";
/**
 * One end of a rule: which session this side matches.
 *
 * The vocabulary is the firewall's — identity (`vmId`/`vpcId`) or address
 * (`public`) — because a reader who knows the firewall should read this by
 * reflex. What differs is that the two ends are *not* symmetric, and the
 * asymmetries fall out of what each side means:
 *
 * - **A source never carries a landing coordinate** (`host`/`port`). A source is
 *   *who opens* the session, not where it goes. The edge authenticates a source
 *   by identity — its switch port, its anti-spoofed address — never by the name
 *   it dials, because the name a client offers proves nothing about the client.
 * - **A destination is never a `vpcId`.** "Which member of a network does this
 *   land on" has no answer; a landing is one place. A whole network may be a
 *   *source* — every VM on it may open the session — but not a destination.
 *
 * `public` also means different things by side. On a source it is the firewall's
 * meaning exactly: every publicly routable client. On a destination it is *the
 * domain's own public origin* — wherever the world's DNS says the name lives — so
 * egress to a vendor is `{ public: true }`, never a blank matcher. The blank
 * matcher never means "the Internet" here, for the same reason it never does in
 * the firewall: the most dangerous statement you can write must not be the one
 * you get by forgetting a field. Every rule states both ends.
 *
 * New selectors arrive as new optional fields, so this type only ever grows.
 */
export interface TlsEndpoint {
    /**
     * A single VM, by id or by your slug for it. On a source, the VM that may open
     * the session; on a destination, the VM the session lands on. Answers hold its
     * id.
     */
    vmId?: string;
    /**
     * Everything on one private network, by id or by your slug for it. **Source
     * only** — every member may open the session. A landing is one place, so a
     * network cannot be a destination. Answers hold its id.
     */
    vpcId?: string;
    /**
     * On a source, every publicly routable client — the open Internet dials the
     * name. On a destination, the domain's own public origin: wherever the world's
     * DNS resolves the name. Only `true` is meaningful — omit the field otherwise.
     */
    public?: true;
    /**
     * **Destination only.** Pin the session to this host instead of resolving the
     * domain — an alias, or an address reachable over a tunnel — while still
     * presenting `domain` as the SNI.
     */
    host?: string;
    /**
     * **Destination only.** The port the session lands on. Required when the
     * destination is a `vmId` or a `host`; defaults to 443 for a `public` origin.
     */
    port?: number;
}
/**
 * Credentials injected into a Postgres startup handshake. The guest connects with
 * no password (or any); the edge completes the real handshake upstream — so a
 * compromised guest never holds a credential it could exfiltrate.
 */
export interface PostgresTransform {
    /** The upstream role to authenticate as. */
    username: string;
    /** The upstream password. Write-only: sealed at rest, read back as `"***"`. */
    password: string;
    /** The database to select. Optional: omitted leaves the guest's choice. */
    database?: string;
}
/**
 * Credentials injected into an SMTP submission handshake. The guest submits mail
 * with no password; the edge completes `AUTH` upstream on its behalf — so a
 * compromised guest never holds a submission credential it could exfiltrate, and
 * cannot be turned into a spam relay by whoever took it.
 */
export interface SmtpTransform {
    /** The submission username to authenticate as. */
    username: string;
    /** The submission password. Write-only: sealed at rest, read back as `"***"`. */
    password: string;
}
/**
 * Credentials presented to your upstream SOCKS5 proxy. Your VM connects to the
 * platform's SOCKS5 front offering *no authentication at all* and the edge
 * authenticates to the provider on its behalf — so the subscription is never
 * inside the VM to be read out of its environment, its disk or a snapshot of it.
 * A guest that is fully compromised can use the proxy; it cannot take it.
 *
 * Optional. A provider that allow-lists its customers by source address needs no
 * pair, and a `socks5` rule with no transform is an ordinary shape.
 */
export interface Socks5Transform {
    /** The username to present to the upstream proxy. */
    username: string;
    /** The password to present to the upstream proxy. Write-only: sealed at rest, read back as `"***"`. */
    password: string;
}
/**
 * One rewrite applied to a session in flight — something only the platform can
 * do, because the whole point is to do what the guest could not do itself.
 *
 * Externally tagged: the wire is `{ headers: { … } }`, `{ postgres: { … } }`,
 * `{ smtp: { … } }`, `{ socks5: { … } }` or `{ s3: { … } }`, exactly one key — `headers` injects
 * request headers into an `http` session, `postgres` completes a `postgres`
 * handshake, `smtp` completes a submission `AUTH`, and `socks5` authenticates the
 * hop to your proxy provider. Each names the protocol it needs, so a rule's
 * `protocol` is inferred from its transform when you omit it. Credential transforms are
 * **egress** acts: the platform spends a credential the guest never holds, so a
 * `postgres` or `smtp` transform on a rule landing on your own VM is refused —
 * pointed inward the first hands every client a logged-in session and the second
 * turns your mail server into an open relay. (`socks5` has no inward form at all
 * to refuse.) Secrets here are
 * **write-only**: sealed at rest and
 * read back as `"***"`, with the record marked {@link TlsRuleData.redacted}.
 * Header *names* survive a read — they are not secret, and seeing which headers a
 * rule sets is how you audit it.
 */
export type TlsTransform = {
    headers: Record<string, string>;
} | {
    jsonPatch: JsonPatchOperation[];
} | {
    postgres: PostgresTransform;
} | {
    smtp: SmtpTransform;
} | {
    socks5: Socks5Transform;
} | {
    s3: S3Transform;
};
/** An S3 operation understood by the edge. Other operations fail closed. */
export type S3Operation = "GetObject" | "HeadObject" | "PutObject" | "DeleteObject" | "ListObjectsV2" | "CreateMultipartUpload" | "UploadPart" | "ListParts" | "CompleteMultipartUpload" | "AbortMultipartUpload" | "ListMultipartUploads";
/** Credentials are sealed at rest, redacted on reads, and never sent to the VM. */
export interface S3Credentials {
    accessKeyId: string;
    secretAccessKey: string;
    /** Optional temporary session token. Rotate with tls.rules.update before expiry. */
    sessionToken?: string;
}
export interface S3Scope {
    bucket: string;
    /** Literal key prefix. Use a trailing / for a directory boundary; "" permits all keys. */
    prefix: string;
    operations: S3Operation[];
}
/** Authorize then SigV4-sign HTTP egress. Must be the sole transform, without match.
 * Supports virtual-hosted and path-style bucket addressing at a concrete origin.
 * Listing requires an explicit prefix within scope. Copy, versioned
 * requests, ACLs, and aws-chunked uploads are rejected. Bodies stream over HTTPS
 * using UNSIGNED-PAYLOAD; policies requiring signed payload hashes are unsupported.
 */
export interface S3Transform {
    region: string;
    credentials: S3Credentials;
    scope: S3Scope;
}
/** A JSON value. Patch values are write-only and read back as `"***"`. */
export type JsonPatchValue = null | boolean | number | string | JsonPatchValue[] | {
    [key: string]: JsonPatchValue;
};
/** RFC 6902 operation. Paths use RFC 6901 JSON Pointer, including /~0 and /~1
 * escaping. `add` overwrites object members but inserts array elements; /-
 * appends to an existing array. Parent containers must already exist.
 * A rule accepts one patch of up to 128 operations / 64 KiB. All operations must
 * succeed before forwarding. Applies to every JSON HTTP egress request on the
 * rule; there is no endpoint filtering, provider translation, or wildcard path.
 */
export type JsonPatchOperation = {
    op: "add" | "replace" | "test";
    path: string;
    value: JsonPatchValue;
} | {
    op: "remove";
    path: string;
} | {
    op: "move" | "copy";
    from: string;
    path: string;
};
/** A reusable forward-auth configuration attached to one public HTTP ingress rule. */
export interface TlsForwardAuthReference {
    /** The forward-auth configuration id returned by {@link TlsForwardAuthNamespace.create}. */
    id: string;
}
/** The customer-owned service Freestyle asks before forwarding a request to a VM. */
export interface CreateTlsForwardAuthOptions {
    /** Absolute HTTPS endpoint that receives the authorization subrequest. */
    url: string;
    /** Static headers added to authorization subrequests. Values are write-only. */
    headers?: Record<string, string>;
    /** Authorization deadline in milliseconds. Defaults server-side; accepted range is 100-5000. */
    timeoutMs?: number;
    /** Cookies withheld from the destination VM and protected from being overwritten by it. */
    protectedCookies?: string[];
    /** Headers copied from an allowed authorization response onto the request sent to the VM. */
    authResponseHeaders?: string[];
}
/** A stored forward-auth configuration. Static header values are returned as `"***"`. */
export interface TlsForwardAuthData {
    id: string;
    /** The account that owns the configuration. Taken from your credential, never a request body. */
    accountId: string;
    url: string;
    /** Static authorization-request headers, with every value replaced by `"***"`. */
    headers?: Record<string, string>;
    timeoutMs: number;
    protectedCookies?: string[];
    authResponseHeaders?: string[];
    /** Whether any static header value was redacted out of `headers`. */
    redacted: boolean;
    createdAt: string;
    updatedAt: string;
}
export interface ListTlsForwardAuthResult {
    /** Newest first. */
    configs: TlsForwardAuthData[];
    totalCount: number;
}
/**
 * A resource a rule cannot outlive. Deleting the resource deletes the rule, so no
 * rule is ever left naming something that no longer exists — the same cascade the
 * firewall uses.
 */
export interface TlsDependency {
    /** `"vm"` or `"vpc"` today; new selectors add new kinds. */
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
/**
 * A stored TLS rule: the name a session is addressed to, who may open it, where
 * it lands, and what the edge does to it in flight.
 *
 * `transform` is always redacted here — the sealed secrets live only in storage
 * and reach only the dataplane. When any secret was redacted out, `redacted` is
 * `true`, so a caller knows the shape it sees is not the whole story.
 */
/**
 * Method/exact-path subset of Vercel Sandbox matchers.
 * https://vercel.com/docs/sandbox/concepts/firewall#matchers
 * Dimensions are ANDed; methods are ORed. Non-matches skip all transforms.
 */
export interface HttpRequestMatch {
    /** Case-sensitive HTTP method tokens. Omitted matches any; [] matches none. */
    method?: string[];
    /** Exact path, excluding query. No decoding or trailing-slash normalization. */
    path?: {
        exact: string;
    };
}
export interface TlsRuleData {
    id: string;
    /** The account that owns the rule. Taken from your credential, never a request body. */
    accountId: string;
    action: TlsAction;
    /** The name the session is addressed to: exact, `*.suffix`, or `*`. */
    domain: string;
    protocol: TlsProtocol;
    source: TlsEndpoint;
    destination: TlsEndpoint;
    /** The rewrites this rule applies, with every secret replaced by `"***"`. */
    transform?: TlsTransform[];
    /** Select which HTTP egress requests receive all of this rule's transforms. */
    match?: HttpRequestMatch;
    /** Authorization Freestyle performs before forwarding this public HTTP ingress. */
    forwardAuth?: TlsForwardAuthReference;
    /** Whether any transform secret was redacted out of `transform`. */
    redacted?: boolean;
    /**
     * Whether the platform owns this rule. Managed rules are Freestyle's own (the
     * SSH edge's standing grant, say), invisible to and undeletable by the account.
     */
    managed?: boolean;
    /** What this rule dies with. See {@link TlsDependency}. */
    dependencies: TlsDependency[];
    createdAt: string;
    updatedAt: string;
}
export interface CreateTlsRuleOptions {
    /** Required. `"allow"` is the only accepted value. */
    action: TlsAction;
    /**
     * The name the session is addressed to: exact (`app.acme.com`), `*.suffix`, or
     * `*`. For `smtp` this is a mail route instead, and may name a mailbox —
     * `bot@acme.com`, `acme.com`, `bot@*.acme.com` or `*.acme.com`.
     */
    domain: string;
    /**
     * How the edge treats the bytes. Optional and usually omitted: it is inferred
     * from `transform` when one is present, and defaults to `http` otherwise. Set
     * it to `"imap"` to publish a mailbox on 993 (the edge terminates and forwards
     * plain IMAP to your server; `"imaps"` splices to a server holding its own
     * certificate), `"postgres"` to publish a database on 5432, `"minecraft"` to publish a
     * Minecraft server on 25565, `"smtp"` to receive mail on 25/587/465, or
     * `"tcp"` to have the edge splice the session on 443 without terminating it,
     * so your VM's own certificate answers the handshake. See
     * {@link TlsProtocol}.
     */
    protocol?: TlsProtocol;
    /** Who may open the session. */
    source: TlsEndpoint;
    /** Where the session lands. */
    destination: TlsEndpoint;
    /** Rewrites applied in flight, in order. Secrets here are write-only. */
    transform?: TlsTransform[];
    /** Select which HTTP egress requests receive all of this rule's transforms. */
    match?: HttpRequestMatch;
    /** Ask this reusable configuration before forwarding a public HTTP request to the VM. */
    forwardAuth?: TlsForwardAuthReference;
}
/**
 * A rule declared inside a create, where the resource being created has no id
 * yet.
 *
 * Exactly one endpoint may be left without an identity; that one *is* the new VM.
 * So `{ source: { public: true }, destination: { port: 8000 } }` is inbound to
 * it, and `{ source: {}, destination: { public: true } }` is egress from it. The
 * identity-less destination still owes its `port`: a landing without a port is
 * not a landing.
 */
export type InlineTlsRule = CreateTlsRuleOptions;
/** The `tls` block of a create. */
export interface TlsSpec {
    rules: InlineTlsRule[];
}
export interface ListTlsRulesOptions {
    /** Rules that apply to this VM: those naming it, plus those naming a private network it is on. */
    vmId?: string;
    /** Rules naming this private network. */
    vpcId?: string;
    limit?: number;
    offset?: number;
}
export interface ListTlsRulesResult {
    /** Newest first. */
    rules: TlsRuleData[];
    totalCount: number;
}
/**
 * A rule the SDK refused to send.
 *
 * Thrown before the request, so a mistake costs a stack trace rather than a round
 * trip. The server validates the same things and is the authority; this only
 * catches what can be seen without asking it. `path` names the offending field,
 * e.g. `"destination.port"`.
 */
export declare class TlsRuleValidationError extends Error {
    /** The field the complaint is about, in dotted form. */
    readonly path: string;
    constructor(path: string, message: string);
}
/** A forward-auth configuration the SDK refused to send. */
export declare class TlsForwardAuthValidationError extends Error {
    /** The field the complaint is about, in dotted form. */
    readonly path: string;
    constructor(path: string, message: string);
}
/** Whether a matcher names what the session is, rather than only narrowing it. */
export declare function hasTlsIdentity(endpoint: TlsEndpoint): boolean;
/** Validate a reusable forward-auth configuration before it reaches the API. */
export declare function validateTlsForwardAuth(options: unknown): CreateTlsForwardAuthOptions;
/**
 * Validate a rule's domain. Accepts an exact hostname (`app.acme.com`), a
 * single-label wildcard (`*.acme.com`), or the catch-all `*`. Unlike a mapped
 * custom domain, a wildcard is meaningful here — an egress allow-list wants "any
 * subdomain of this vendor", and containment wants "anything".
 */
export declare function validateTlsDomain(domain: unknown): void;
/**
 * Validate an `smtp` rule's mail route: an optional mailbox, then the same
 * domain grammar every other protocol accepts.
 *
 * The mailbox is matched literally and case-insensitively. RFC 5321 leaves what a
 * local part *means* to the receiving host, so the platform does not fold dots,
 * strip `+tags`, or otherwise guess at an addressing convention your own mail
 * server owns — a rule serves the mailbox it names and no other. Quoted
 * mailboxes (`"a b"@acme.com`) are refused rather than half-supported.
 */
export declare function validateTlsMailRoute(domain: unknown): void;
/**
 * Validate one matcher against the side it is on. `side` is `"source"` or
 * `"destination"`; the rules encode the two asymmetries — a source is a pure
 * identity, a destination is a landing.
 */
export declare function validateTlsEndpoint(endpoint: unknown, side: "source" | "destination"): void;
/**
 * The protocol a rule resolves to: the stated one, the one its transforms imply,
 * or `http`. Throws when a stated protocol disagrees with a transform, or two
 * transforms disagree with each other — a rule terminates one protocol.
 */
export declare function resolveTlsProtocol(protocol: TlsProtocol | undefined, transforms: readonly TlsTransform[]): TlsProtocol;
/** Validate a standalone rule, where both ends must say what they are. */
export declare function validateTlsRule(rule: unknown): CreateTlsRuleOptions;
/**
 * Validate the `tls` block of a VM create.
 *
 * Exactly one end of each rule may be identity-less; that one is the VM being
 * created. On a source that is egress from it (`{} -> { public: true }`); on a
 * destination that is ingress to it (`{ public: true } -> { port: 8000 }`), and
 * the identity-less destination still owes its `port`. Both ends bare would be a
 * rule from the VM to itself, which allows nothing; neither bare would be a rule
 * that never mentions the VM, so nothing would tie its life to the VM's — exactly
 * the dangling reference the dependency model exists to prevent.
 */
export declare function validateTlsSpec(spec: unknown): TlsSpec;
/** Reusable authorization checks for public HTTP ingress: `freestyle.tls.forwardAuth`. */
export declare class TlsForwardAuthNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    /** List your forward-auth configurations, newest first. */
    list(): Promise<ListTlsForwardAuthResult>;
    /** Create a forward-auth configuration. Static request-header values are write-only. */
    create(options: CreateTlsForwardAuthOptions): Promise<TlsForwardAuthData>;
    /** Fetch one forward-auth configuration by id. */
    get(id: string): Promise<TlsForwardAuthData>;
    /** Replace a configuration in place, including rotating its static headers. */
    update(id: string, options: CreateTlsForwardAuthOptions): Promise<TlsForwardAuthData>;
    /** Delete an unused forward-auth configuration. */
    delete(id: string): Promise<void>;
}
/** TLS rules: `freestyle.tls.rules`. */
export declare class TlsRulesNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    /**
     * Allow a named TLS session: `domain`, from `source`, to `destination`.
     *
     * An ingress `domain` is a name you have verified, or any unused subdomain
     * of `style.dev`, which is free and needs no verification or DNS records.
     *
     * @example
     * // Public HTTPS ingress: anyone dialing app.acme.com lands on a VM's port.
     * await freestyle.tls.rules.create({
     *   action: "allow",
     *   domain: "app.acme.com",
     *   source: { public: true },
     *   destination: { vmId: "vm-123456", port: 8000 },
     * });
     *
     * @example
     * // Egress with a secret injected: a VM reaches OpenAI at its real origin,
     * // and the edge adds the Authorization header the guest never held.
     * await freestyle.tls.rules.create({
     *   action: "allow",
     *   domain: "api.openai.com",
     *   source: { vmId: "vm-123456" },
     *   destination: { public: true },
     *   transform: [{ headers: { authorization: "Bearer sk-…" } }],
     * });
     *
     * @example
     * // Internal service: one VM reaches another by a name. The source opens
     * // https://api.internal; the edge terminates it and forwards to the target
     * // VM's port. Steered at the edge, HTTP-only, no transform.
     * await freestyle.tls.rules.create({
     *   action: "allow",
     *   domain: "api.internal",
     *   source: { vmId: "vm-123456" },
     *   destination: { vmId: "vm-654321", port: 8000 },
     * });
     *
     * @throws {TlsRuleValidationError} before any request, when the rule cannot be
     * well formed.
     */
    create(options: CreateTlsRuleOptions): Promise<TlsRuleData>;
    /**
     * List your rules, newest first. Pass `vmId` for the rules that apply to one
     * VM — those naming it, plus those naming a private network it is on.
     */
    list(options?: ListTlsRulesOptions): Promise<ListTlsRulesResult>;
    get(ruleId: string): Promise<TlsRuleData>;
    /**
     * Replace a rule in place. The one mutation the firewall does not allow: a
     * transform carries a rotating secret, and delete-then-create would drop
     * traffic or trip the account limit mid-swap. The rule keeps its id and
     * creation time; everything in `options` is replaced.
     *
     * @throws {TlsRuleValidationError} before any request, when the replacement
     * cannot be well formed.
     */
    update(ruleId: string, options: CreateTlsRuleOptions): Promise<TlsRuleData>;
    /** Delete a rule. The resources it named are untouched. */
    delete(ruleId: string): Promise<void>;
}
/** The `freestyle.tls` namespace. */
export declare class TlsNamespace {
    private readonly client;
    readonly rules: TlsRulesNamespace;
    readonly forwardAuth: TlsForwardAuthNamespace;
    constructor(client: FreestyleClient);
}
//# sourceMappingURL=tls.d.ts.map