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
    relayFleet:            string[];
    routeContractVersion:  number;
}

export interface Binding {
    bindingId:       string;
    clientNamespace: string;
    deviceId?:       null | string;
    endpointId:      string;
    homeRelayUrl?:   null | string;
    instanceTag?:    null | string;
    updatedAt?:      Date | null;
}

export interface GrantVerificationKey {
    alg:       string;
    keyId:     string;
    publicKey: string;
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
     * rev the server resumed the delta stream from; null means full snapshot follows
     */
    resumedFromRev?: number | null;
    sessionId:       string;
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
    endpointId: string;
    /**
     * highest rev this client has on disk; server streams deltas after it, or a full snapshot
     * when null/too old
     */
    haveRev?:   number | null;
    wantPasses: boolean;
}

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
}

export type CTLSnapshotCompleteType = "snapshot_complete";
