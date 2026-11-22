import { type FreestyleOptions } from "./client.js";
import { DomainsNamespace } from "./domains.js";
import { FirewallNamespace } from "./firewall.js";
import { IdentitiesNamespace } from "./identities.js";
import { TlsNamespace } from "./tls.js";
import { TunnelsNamespace } from "./tunnel.js";
import { VmsNamespace } from "./vms/index.js";
import { VpcNamespace } from "./vpc.js";
export * from "./client.js";
export * from "./errors.js";
export * from "./vms/index.js";
export * from "./vpc.js";
export * from "./tunnel.js";
export * from "./domains.js";
export * from "./firewall.js";
export * from "./tls.js";
export * from "./identities.js";
/**
 * The Freestyle API client. See https://freestyle.sh/docs and
 * https://api.freestyle.sh/openapi.json for the underlying HTTP contract.
 *
 * @example
 * const freestyle = new Freestyle({ apiKey: process.env.FREESTYLE_API_KEY });
 * const { vm } = await freestyle.vms.create();
 * const { stdout } = await vm.exec("echo hello");
 */
export declare class Freestyle {
    private readonly client;
    readonly vms: VmsNamespace;
    readonly vpc: VpcNamespace;
    readonly tunnels: TunnelsNamespace;
    /** Allowed network communication, stated as `source -> destination` intent. */
    readonly firewall: FirewallNamespace;
    /** Named TLS sessions, stated as `domain, source -> destination` intent. */
    readonly tls: TlsNamespace;
    readonly domains: DomainsNamespace;
    readonly identities: IdentitiesNamespace;
    constructor(options?: FreestyleOptions);
    /** Low-level escape hatch: an authenticated `fetch` against the API. Pass the whole path, `/v5` included. */
    fetch(path: string, init?: RequestInit): Promise<Response>;
}
//# sourceMappingURL=index.d.ts.map