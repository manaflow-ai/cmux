export interface CTLACK {
    payload: CTLACKPayload;
    /**
     * directory/hint revision the client has applied; stops the server's retry ladder for
     * revisions up to and including it
     */
    rev:  number;
    type: CTLACKType;
    /**
     * control-plane protocol version, 1
     */
    v: number;
}

export interface CTLACKPayload {
    /**
     * optional client stamp of when the acked revision was applied
     */
    appliedAt?: Date;
}

export type CTLACKType = "ack";

export interface CTLError {
    payload: CTLErrorPayload;
    type:    CTLErrorType;
    /**
     * control-plane protocol version, 1
     */
    v: number;
}

export interface CTLErrorPayload {
    code:      string;
    message:   string;
    retryable: boolean;
}

export type CTLErrorType = "error";

export interface CTLDirectory {
    payload: CTLDirectoryPayload;
    /**
     * monotonic account route revision this fact reflects
     */
    rev:  number;
    type: CTLDirectoryType;
    /**
     * control-plane protocol version, 1
     */
    v: number;
}

export interface CTLDirectoryPayload {
    bindings:              Binding[];
    grantVerificationKeys: GrantVerificationKey[];
    /**
     * server stamp when this directory was issued; anchor of the trust lease
     */
    issuedAt: Date;
    /**
     * per-platform app-version floors; clients below the floor must update before participating
     */
    minimumSupportedVersion?: PurpleMinimumSupportedVersion;
    relayFleet:               string[];
    routeContractVersion:     number;
    /**
     * trust lease duration; clients treat the directory as stale once issuedAt + ttlSeconds
     * passes without a re-stamp
     */
    ttlSeconds: number;
}

export interface Binding {
    appVersion?:     string;
    bindingId:       string;
    capabilities?:   string[];
    clientNamespace: string;
    deviceId?:       null | string;
    endpointId:      string;
    homeRelayUrl?:   null | string;
    instanceTag?:    null | string;
    /**
     * when this device last confirmed itself over its own control-plane hello
     */
    lastConfirmedAt?: Date;
    releaseTrack?:    ReleaseTrack;
    /**
     * authorization kill switch, orthogonal to status; peers must deny P2P admission to a
     * revoked device
     */
    revoked: boolean;
    /**
     * device lifecycle state from the account overlay; a binding never confirmed by its own
     * hello stays seeded
     */
    status?:    Status;
    updatedAt?: Date | null;
}

export type ReleaseTrack = "nightly" | "stable" | "internal" | "beta" | "appstore" | "dev";

/**
 * device lifecycle state from the account overlay; a binding never confirmed by its own
 * hello stays seeded
 */
export type Status = "active" | "seeded" | "stale" | "retired" | "suspended" | "pending" | "superseded";

export interface GrantVerificationKey {
    alg:       string;
    keyId:     string;
    publicKey: string;
}

/**
 * per-platform app-version floors; clients below the floor must update before participating
 */
export interface PurpleMinimumSupportedVersion {
    ios?: string;
    mac?: string;
}

export type CTLDirectoryType = "directory";

export interface CTLHelloACK {
    payload: CTLHelloACKPayload;
    type:    CTLHelloACKType;
    /**
     * control-plane protocol version, 1
     */
    v: number;
}

export interface CTLHelloACKPayload {
    /**
     * echo of the directory's per-platform version floors so clients get them before the
     * directory body
     */
    minimumSupportedVersion?: FluffyMinimumSupportedVersion;
    /**
     * rev the server resumed the delta stream from; null means full snapshot follows
     */
    resumedFromRev?: number | null;
    /**
     * control-plane features this server supports (list overlay, ack tracking, revocation)
     */
    serverCapabilities?: string[];
    sessionId:           string;
}

/**
 * echo of the directory's per-platform version floors so clients get them before the
 * directory body
 */
export interface FluffyMinimumSupportedVersion {
    ios?: string;
    mac?: string;
}

export type CTLHelloACKType = "hello_ack";

export interface CTLHello {
    payload: CTLHelloPayload;
    type:    CTLHelloType;
    /**
     * control-plane protocol version, 1
     */
    v: number;
}

export interface CTLHelloPayload {
    appVersion?:   string;
    capabilities?: string[];
    /**
     * optional client self-identification; presence of any client-info field confirms the
     * device into the account overlay
     */
    deviceId?:  string;
    endpointId: string;
    /**
     * highest rev this client has on disk; server streams deltas after it, or a full snapshot
     * when null/too old
     */
    haveRev?:      number | null;
    platform?:     Platform;
    releaseTrack?: ReleaseTrack;
    wantPasses:    boolean;
}

export type Platform = "mac" | "ios";

export type CTLHelloType = "hello";

export interface CTLHintUpdate {
    payload: CTLHintUpdatePayload;
    /**
     * monotonic account route revision this fact reflects
     */
    rev:  number;
    type: CTLHintUpdateType;
    /**
     * control-plane protocol version, 1
     */
    v: number;
}

export interface CTLHintUpdatePayload {
    endpointId:   string;
    homeRelayUrl: string;
    updatedAt?:   Date | null;
}

export type CTLHintUpdateType = "hint_update";

export interface CTLMintRequest {
    payload: CTLMintRequestPayload;
    type:    CTLMintRequestType;
    /**
     * control-plane protocol version, 1
     */
    v: number;
}

export interface CTLMintRequestPayload {
    endpointId: string;
    /**
     * Optional signed identity assertion (reserved for the source-of-truth migration; phase A
     * authorizes via the bearer-authenticated socket and confirms hints by re-fetching
     * discovery)
     */
    proof?: PurpleProof;
}

/**
 * Optional signed identity assertion (reserved for the source-of-truth migration; phase A
 * authorizes via the bearer-authenticated socket and confirms hints by re-fetching
 * discovery)
 */
export interface PurpleProof {
    bindingId: string;
    /**
     * base64 Ed25519 signature by the endpoint key
     */
    signature: string;
    /**
     * RFC3339 issue time; server enforces freshness window
     */
    timestamp: string;
}

export type CTLMintRequestType = "mint_request";

export interface CTLPublishHint {
    payload: CTLPublishHintPayload;
    type:    CTLPublishHintType;
    /**
     * control-plane protocol version, 1
     */
    v: number;
}

export interface CTLPublishHintPayload {
    endpointId:   string;
    homeRelayUrl: string;
    /**
     * Optional signed identity assertion (reserved for the source-of-truth migration; phase A
     * authorizes via the bearer-authenticated socket and confirms hints by re-fetching
     * discovery)
     */
    proof?: FluffyProof;
}

/**
 * Optional signed identity assertion (reserved for the source-of-truth migration; phase A
 * authorizes via the bearer-authenticated socket and confirms hints by re-fetching
 * discovery)
 */
export interface FluffyProof {
    bindingId: string;
    /**
     * base64 Ed25519 signature by the endpoint key
     */
    signature: string;
    /**
     * RFC3339 issue time; server enforces freshness window
     */
    timestamp: string;
}

export type CTLPublishHintType = "publish_hint";

export interface CTLRelayPasses {
    payload: CTLRelayPassesPayload;
    /**
     * monotonic account route revision this fact reflects
     */
    rev:  number;
    type: CTLRelayPassesType;
    /**
     * control-plane protocol version, 1
     */
    v: number;
}

export interface CTLRelayPassesPayload {
    endpointId: string;
    passes:     Pass[];
}

export interface Pass {
    expiresAt:  Date;
    generation: number;
    /**
     * server-driven early-refresh point (expiry minus margin)
     */
    refreshAfter: Date;
    relayUrl:     string;
    token:        string;
}

export type CTLRelayPassesType = "relay_passes";

export interface CTLSnapshotComplete {
    payload: CTLSnapshotCompletePayload;
    /**
     * monotonic account route revision this fact reflects
     */
    rev:  number;
    type: CTLSnapshotCompleteType;
    /**
     * control-plane protocol version, 1
     */
    v: number;
}

export interface CTLSnapshotCompletePayload {
    /**
     * server freshness re-stamp; when a hello's haveRev already matches head this frame alone
     * re-arms the directory trust lease without resending the body
     */
    issuedAt?: Date;
}

export type CTLSnapshotCompleteType = "snapshot_complete";
