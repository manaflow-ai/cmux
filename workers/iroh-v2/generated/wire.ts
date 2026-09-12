export interface V2DashboardOpen {
    clientInstanceId: string;
    environment:      string;
    projectId:        string;
    requestId:        string;
    schemaId:         V2DashboardOpenSchemaID;
    teamId:           string;
    userId:           string;
}

export type V2DashboardOpenSchemaID = "dashboard.open.v1";

export interface V2AcknowledgementRequest {
    requestId: string;
    schemaId:  V2AcknowledgementRequestSchemaID;
    sequence:  number;
    token:     string;
}

export type V2AcknowledgementRequestSchemaID = "session.ack.v1";

export interface V2ChallengeRequest {
    device:    V2DeviceDescriptor;
    requestId: string;
    schemaId:  V2ChallengeRequestSchemaID;
}

export interface V2DeviceDescriptor {
    endpointId:         string;
    identity:           V2Identity;
    identityGeneration: number;
    metadata:           V2DeviceMetadata;
}

export interface V2Identity {
    appNamespace: string;
    buildTag:     string;
    deviceId:     string;
    environment:  string;
    projectId:    string;
    teamId:       string;
    userId:       string;
}

export interface V2DeviceMetadata {
    appVersion:     string;
    capabilities:   string[];
    displayName:    string;
    pairingEnabled: boolean;
    platform:       V2Platform;
    relayURLs:      string[];
}

export type V2Platform = "mac" | "ios";

export type V2ChallengeRequestSchemaID = "challenge.request.v1";

export interface V2DirectoryRequest {
    cursor?:       string;
    haveRevision?: number;
    requestId:     string;
    schemaId:      V2DirectoryRequestSchemaID;
}

export type V2DirectoryRequestSchemaID = "directory.request.v1";

export interface V2GoodbyeRequest {
    requestId: string;
    schemaId:  V2GoodbyeRequestSchemaID;
}

export type V2GoodbyeRequestSchemaID = "session.goodbye.v1";

export interface V2MetadataRequest {
    metadata:  V2DeviceMetadata;
    requestId: string;
    schemaId:  V2MetadataRequestSchemaID;
}

export type V2MetadataRequestSchemaID = "device.metadata.v1";

export interface V2PermissionRequest {
    permission: V2Permission;
    requestId:  string;
    schemaId:   V2PermissionRequestSchemaID;
}

export interface V2Permission {
    connect:        boolean;
    deviceRecordId: string;
    manage:         boolean;
    subjectUserId:  string;
}

export type V2PermissionRequestSchemaID = "permission.update.v1";

export interface V2PreferencesRequest {
    expectedRevision: number;
    relayURLs:        [string, ...string[]];
    requestId:        string;
    schemaId:         V2PreferencesRequestSchemaID;
}

export type V2PreferencesRequestSchemaID = "preferences.update.v1";

export interface V2RegisterRequest {
    challengeId: string;
    device:      V2DeviceDescriptor;
    nonce:       string;
    requestId:   string;
    schemaId:    V2RegisterRequestSchemaID;
    signature:   string;
}

export type V2RegisterRequestSchemaID = "device.register.v1";

export interface V2RelayRequest {
    requestId: string;
    schemaId:  V2RelayRequestSchemaID;
}

export type V2RelayRequestSchemaID = "relay.request.v1";

export interface V2RevokeRequest {
    deviceRecordId: string;
    requestId:      string;
    schemaId:       V2RevokeRequestSchemaID;
}

export type V2RevokeRequestSchemaID = "device.revoke.v1";

export interface V2SocketSetup {
    device:        V2DeviceDescriptor;
    haveRevision?: number;
    proof?:        V2DeviceProof;
    requestId:     string;
    schemaId:      V2SocketSetupSchemaID;
}

export interface V2DeviceProof {
    issuedAt:  number;
    nonce:     string;
    requestId: string;
    signature: string;
}

export type V2SocketSetupSchemaID = "session.open.v1";

export interface V2TicketRequest {
    requestId:        string;
    schemaId:         V2TicketRequestSchemaID;
    stackAccessToken: string;
}

export type V2TicketRequestSchemaID = "ticket.request.v1";

export interface V2WorkspaceGetRequest {
    requestId: string;
    schemaId:  V2WorkspaceGetRequestSchemaID;
    vmId:      string;
}

export type V2WorkspaceGetRequestSchemaID = "workspace.get.v1";

export interface V2WorkspaceSnapshotRequest {
    generation: string;
    requestId:  string;
    revision:   number;
    schemaId:   V2WorkspaceSnapshotRequestSchemaID;
    snapshot:   V2WorkspaceSnapshotRequestSnapshot;
    vmId:       string;
}

export type V2WorkspaceSnapshotRequestSchemaID = "workspace.snapshot.v1";

export interface V2WorkspaceSnapshotRequestSnapshot {
    terminals:  PurpleTerminal[];
    workspaces: PurpleWorkspace[];
}

export interface PurpleTerminal {
    agent:       null | string;
    cwd:         null | string;
    id:          string;
    title:       string;
    workspaceId: null | string;
}

export interface PurpleWorkspace {
    focused: boolean;
    id:      string;
    index:   number;
    name:    string;
}

export interface V2ChallengeResponse {
    challenge:        V2Challenge;
    deliveryReceipt?: V2DeliveryReceipt;
    requestId:        string;
    schemaId:         V2ChallengeResponseSchemaID;
}

export interface V2Challenge {
    challengeId: string;
    expiresAt:   number;
    nonce:       string;
    payloadHash: string;
}

export interface V2DeliveryReceipt {
    sequence: number;
    token:    string;
}

export type V2ChallengeResponseSchemaID = "challenge.result.v1";

export interface V2ChangedResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    revision:         number;
    schemaId:         V2ChangedResponseSchemaID;
    teamId:           string;
}

export type V2ChangedResponseSchemaID = "directory.changed.v1";

export interface V2CompletedResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    requestId:        string;
    revision:         number;
    schemaId:         V2CompletedResponseSchemaID;
}

export type V2CompletedResponseSchemaID = "operation.completed.v1";

export interface V2DashboardConnectedResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    expiresAt:        number;
    requestId:        string;
    schemaId:         V2DashboardConnectedResponseSchemaID;
    sessionId:        string;
    teamRevision:     number;
}

export type V2DashboardConnectedResponseSchemaID = "dashboard.connected.v1";

export interface V2DashboardDirectoryResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    directory:        V2DashboardDirectory;
    requestId:        string;
    schemaId:         V2DashboardDirectoryResponseSchemaID;
}

export interface V2DashboardDirectory {
    canManageTeam:    boolean;
    devices:          V2DeviceRecord[];
    issuedAt:         number;
    managedDeviceIds: string[];
    nextCursor:       null | string;
    relayURLs:        string[];
    revision:         number;
    teamId:           string;
}

export interface V2DeviceRecord {
    descriptor:     V2DeviceDescriptor;
    deviceRecordId: string;
    revision:       number;
    revoked:        boolean;
}

export type V2DashboardDirectoryResponseSchemaID = "dashboard.directory.v1";

export interface V2DashboardReadyResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    requestId:        string;
    schemaId:         V2DashboardReadyResponseSchemaID;
    ticket:           V2Ticket;
}

export type V2DashboardReadyResponseSchemaID = "dashboard.ready.v1";

export interface V2Ticket {
    expiresAt:    number;
    refreshAfter: number;
    token:        string;
}

export interface V2DirectoryResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    directory:        V2Directory;
    requestId:        string;
    schemaId:         V2DirectoryResponseSchemaID;
}

export interface V2Directory {
    devices:             V2DeviceRecord[];
    inboundPeers?:       V2InboundPeerPermission[];
    issuedAt:            number;
    nextCursor:          null | string;
    permissionExpiresAt: number;
    relayURLs:           string[];
    revision:            number;
    teamId:              string;
}

export interface V2InboundPeerPermission {
    device:              V2DeviceRecord;
    permissionExpiresAt: number;
}

export type V2DirectoryResponseSchemaID = "directory.result.v1";

export interface V2ErrorResponse {
    code:             V2ErrorCode;
    deliveryReceipt?: V2DeliveryReceipt;
    requestId:        string;
    retryable:        boolean;
    retryAfterMs?:    number;
    schemaId:         V2ErrorResponseSchemaID;
}

export type V2ErrorCode = "invalid_request" | "unsupported_method" | "payload_too_large" | "unsupported_media_type" | "unauthorized" | "ticket_expired" | "invalid_device_proof" | "proof_replayed" | "team_access_revoked" | "permission_denied" | "device_revoked" | "identity_mismatch" | "environment_mismatch" | "device_not_enrolled" | "endpoint_already_owned" | "challenge_missing" | "challenge_replaced" | "challenge_expired" | "challenge_invalid" | "key_replacement_required" | "revision_conflict" | "rate_limited" | "client_upgrade_required" | "device_limit" | "storage_limit" | "storage_unavailable" | "upstream_unavailable" | "slow_consumer" | "resync_required" | "internal_error";

export type V2ErrorResponseSchemaID = "error.v1";

export interface V2ReadyResponse {
    challenge?:       V2Challenge;
    deliveryReceipt?: V2DeliveryReceipt;
    device?:          V2DeviceRecord;
    requestId:        string;
    schemaId:         V2ReadyResponseSchemaID;
    sessionId:        string;
    teamRevision:     number;
    ticket?:          V2Ticket;
}

export type V2ReadyResponseSchemaID = "session.ready.v1";

export interface V2RegisteredResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    device:           V2DeviceRecord;
    requestId:        string;
    schemaId:         V2RegisteredResponseSchemaID;
}

export type V2RegisteredResponseSchemaID = "device.registered.v1";

export interface V2RelayResponse {
    credentials:      [V2RelayCredential, ...V2RelayCredential[]];
    deliveryReceipt?: V2DeliveryReceipt;
    requestId:        string;
    schemaId:         V2RelayResponseSchemaID;
}

export interface V2RelayCredential {
    expiresAt:    number;
    refreshAfter: number;
    relayURL:     string;
    token:        string;
}

export type V2RelayResponseSchemaID = "relay.result.v1";

export interface V2RevokedResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    deviceRecordId:   string;
    revision:         number;
    schemaId:         V2RevokedResponseSchemaID;
    teamId:           string;
}

export type V2RevokedResponseSchemaID = "device.revoked.v1";

export interface V2TicketResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    requestId:        string;
    schemaId:         V2TicketResponseSchemaID;
    ticket:           V2Ticket;
}

export type V2TicketResponseSchemaID = "ticket.result.v1";

export interface V2WorkspaceChangedResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    generation:       string;
    revision:         number;
    schemaId:         V2WorkspaceChangedResponseSchemaID;
    teamId:           string;
    vmId:             string;
}

export type V2WorkspaceChangedResponseSchemaID = "workspace.changed.v1";

export interface V2WorkspaceSnapshotResponse {
    deliveryReceipt?: V2DeliveryReceipt;
    generation:       string;
    requestId:        string;
    revision:         number;
    schemaId:         V2WorkspaceSnapshotResponseSchemaID;
    snapshot:         V2WorkspaceSnapshotResponseSnapshot;
    vmId:             string;
}

export type V2WorkspaceSnapshotResponseSchemaID = "workspace.snapshot.result.v1";

export interface V2WorkspaceSnapshotResponseSnapshot {
    terminals:  FluffyTerminal[];
    workspaces: FluffyWorkspace[];
}

export interface FluffyTerminal {
    agent:       null | string;
    cwd:         null | string;
    id:          string;
    title:       string;
    workspaceId: null | string;
}

export interface FluffyWorkspace {
    focused: boolean;
    id:      string;
    index:   number;
    name:    string;
}

export type V2Request = V2AcknowledgementRequest | V2ChallengeRequest | V2DirectoryRequest | V2GoodbyeRequest | V2MetadataRequest | V2PermissionRequest | V2PreferencesRequest | V2RegisterRequest | V2RelayRequest | V2RevokeRequest | V2TicketRequest | V2WorkspaceGetRequest | V2WorkspaceSnapshotRequest;
export type V2Response = V2ChallengeResponse | V2ChangedResponse | V2CompletedResponse | V2DashboardConnectedResponse | V2DashboardDirectoryResponse | V2DashboardReadyResponse | V2DirectoryResponse | V2ErrorResponse | V2ReadyResponse | V2RegisteredResponse | V2RelayResponse | V2RevokedResponse | V2TicketResponse | V2WorkspaceChangedResponse | V2WorkspaceSnapshotResponse;
