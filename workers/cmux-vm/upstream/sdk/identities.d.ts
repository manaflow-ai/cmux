import type { FreestyleClient } from "./client.js";
export interface IdentityData {
    id: string;
    managed: boolean;
}
export interface IdentityInfo {
    id: string;
    accountId: string;
    managed: boolean;
}
export interface CreatedToken {
    id: string;
    /** Returned once, in full. */
    token: string;
}
export interface AccessTokenInfo {
    id: string;
}
export interface ListIdentitiesResult {
    identities: IdentityData[];
    total: number;
}
export interface ListIdentitiesOptions {
    limit?: number;
    offset?: number;
    includeManaged?: boolean;
}
export interface VmPermission {
    id: string;
    identityId: string;
    vmId: string;
    allowedLinuxUsers: string[] | null;
    grantedAt: string;
    grantedBy: string;
}
export interface GrantVmPermissionOptions {
    vmId: string;
    /** Restrict the grant to these Linux users; omit (or null) for unrestricted access. */
    allowedLinuxUsers?: string[] | null;
}
/** An identity's access tokens: `identity.tokens`. */
export declare class IdentityTokensNamespace {
    private readonly client;
    private readonly basePath;
    constructor(client: FreestyleClient, basePath: string);
    /** Mint an access token for the identity. */
    create(): Promise<CreatedToken>;
    list(): Promise<AccessTokenInfo[]>;
    revoke(tokenId: string): Promise<void>;
}
/** An identity's per-VM permission grants: `identity.permissions.vm`. */
export declare class IdentityVmPermissionsNamespace {
    private readonly client;
    private readonly basePath;
    constructor(client: FreestyleClient, basePath: string);
    /** List the VMs this identity has been granted access to. */
    list(): Promise<VmPermission[]>;
    /** Grant this identity access to a VM. */
    grant(options: GrantVmPermissionOptions): Promise<VmPermission>;
    /** Fetch this identity's grant on a VM. */
    get(vmId: string): Promise<VmPermission>;
    /** Change which Linux users this identity may act as on a VM. */
    update(vmId: string, allowedLinuxUsers: string[] | null): Promise<VmPermission>;
    /** Revoke this identity's access to a VM. */
    revoke(vmId: string): Promise<void>;
}
/** A handle to one identity. */
export declare class Identity {
    readonly id: string;
    readonly tokens: IdentityTokensNamespace;
    readonly permissions: {
        vm: IdentityVmPermissionsNamespace;
    };
    private readonly client;
    private readonly basePath;
    constructor(client: FreestyleClient, id: string);
    data(): Promise<IdentityInfo>;
    /** Delete the identity, along with its tokens and grants. Managed identities cannot be deleted. */
    delete(): Promise<void>;
}
/** The `freestyle.identities` namespace: scoped access for your end users. */
export declare class IdentitiesNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    /** Create an identity. */
    create(options?: {
        managed?: boolean;
    }): Promise<{
        identity: Identity;
        identityId: string;
        data: IdentityData;
    }>;
    list(options?: ListIdentitiesOptions): Promise<ListIdentitiesResult>;
    get(identityId: string): Promise<IdentityInfo>;
    /** A handle to an identity, without a network call. */
    ref(identityId: string): Identity;
    delete(identityId: string): Promise<void>;
}
//# sourceMappingURL=identities.d.ts.map