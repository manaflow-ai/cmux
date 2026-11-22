import { FreestyleClient } from "./client.js";
/** Experimental; deliberately absent from OpenAPI. */
export interface SecurityKeyInfo {
    id: string;
    name: string;
    approvalOrigins: string[];
    embedOrigins: string[];
    setupUrl: string;
}
export type SecurityKeyPermission = "observe" | "attach" | "approve";
export type SecurityKeyRequestStatus = "pending" | "completed" | "denied" | "cancelled" | "expired" | "failed";
export interface SecurityKeyRequest {
    id: string;
    securityKeyId: string;
    vmId: string;
    operation: "registration" | "authentication";
    rpId: string;
    approvalUrl: string;
    approvalUrls: string[];
    expiresAt: string;
    status: SecurityKeyRequestStatus;
}
export interface SecurityKeyRequestFinished {
    requestId: string;
    securityKeyId: string;
    vmId: string;
    /** Completed means the authenticator responded, not that the service accepted the login. */
    status: Exclude<SecurityKeyRequestStatus, "pending">;
}
export interface SecurityKeyWatchOptions {
    onRequest(request: SecurityKeyRequest): void | Promise<void>;
    onRequestFinished?(event: SecurityKeyRequestFinished): void | Promise<void>;
    onError?(error: unknown): void;
    securityKeyId?: string;
    vmId?: string;
    signal?: AbortSignal;
}
export interface SecurityKeySession {
    /** Single-use session ticket in the fragment; do not log or persist this URL. */
    url: string;
    origin: string;
    ticket: string;
    expiresAt: string;
}
export declare class SecurityKey {
    private readonly client;
    readonly id: string;
    constructor(client: FreestyleClient, id: string);
    private path;
    info(): Promise<SecurityKeyInfo>;
    update(options: {
        approvalOrigins?: string[];
        embedOrigins?: string[];
    }): Promise<SecurityKeyInfo>;
    attach({ vmId, approvalOrigins }: {
        vmId: string;
        approvalOrigins?: string[];
    }): Promise<{
        id: string;
        vmId: string;
        securityKeyId: string;
    }>;
    detach({ vmId }: {
        vmId: string;
    }): Promise<unknown>;
    grant(options: {
        identityId: string;
        permissions: SecurityKeyPermission[];
    }): Promise<unknown>;
    revoke({ identityId }: {
        identityId: string;
    }): Promise<unknown>;
    delete(): Promise<unknown>;
    /** Requires approve permission. Creating a session does not unlock or sign anything. */
    createSession(options?: {
        origin?: string;
        parentOrigin?: string;
        requestId?: string;
    }): Promise<SecurityKeySession>;
}
export declare class SecurityKeysNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    get(id: string): SecurityKey;
    list(): Promise<{
        securityKeys: SecurityKeyInfo[];
    }>;
    create(options: {
        name: string;
        approvalOrigins?: string[];
        embedOrigins?: string[];
    }): Promise<{
        securityKey: SecurityKey;
        setupUrl: string;
    }>;
    private requests;
    /** Observe all keys permitted by the token, in Node or a browser. Reconciles pending requests after reconnect. */
    watch(options: SecurityKeyWatchOptions): Promise<{
        close(): void;
    }>;
    /** Mount the hosted approval UI. The passkey ceremony and signing remain inside its origin. */
    respond(options: {
        requestId: string;
        container: HTMLElement;
        origin?: string;
        signal?: AbortSignal;
    }): Promise<SecurityKeyRequestFinished>;
}
//# sourceMappingURL=security-keys.d.ts.map