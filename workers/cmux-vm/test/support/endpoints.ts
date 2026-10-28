/**
 * Every endpoint that acts on one VM, with the scope it needs and a valid
 * request for it. The isolation suite runs each one as another tenant and as a
 * key without the scope, and checks that this table covers openapi.json.
 */
import { SCOPES, type Scope } from "../../src/domain/scopes.ts";

export interface VmEndpointCase {
  readonly name: string;
  readonly method: "GET" | "POST" | "PUT" | "DELETE";
  /** The OpenAPI path template. */
  readonly template: string;
  readonly path: (vmId: string) => string;
  readonly scope: Scope;
  readonly json?: unknown;
  readonly bytes?: Uint8Array;
}

export const VM_ENDPOINTS: ReadonlyArray<VmEndpointCase> = [
  { name: "getVmInstanceIdentity", method: "GET", template: "/v1/vms/{vmId}/identity", path: (id) => `/v1/vms/${id}/identity`, scope: "vm:read" },
  { name: "statFile", method: "GET", template: "/v1/vms/{vmId}/files/stat", path: (id) => `/v1/vms/${id}/files/stat?path=%2Fsrv%2Fteam`, scope: "vm:files" },
  { name: "retireVm", method: "POST", template: "/v1/vms/{vmId}/retire", path: (id) => `/v1/vms/${id}/retire`, scope: "vm:write" },
  { name: "resizeVm", method: "POST", template: "/v1/vms/{vmId}/resize", path: (id) => `/v1/vms/${id}/resize`, scope: "vm:write", json: { resources: { vcpus: 8 } } },
  { name: "replaceVmHttpsProxy", method: "PUT", template: "/v1/vms/{vmId}/https-proxies/{hostname}",
    path: (id) => `/v1/vms/${id}/https-proxies/api.example.test`, scope: "vm:network", json: { destination: "https://proxy.example.test" } },
  { name: "getVm", method: "GET", template: "/v1/vms/{vmId}", path: (id) => `/v1/vms/${id}`, scope: "vm:read" },
  { name: "startVm", method: "POST", template: "/v1/vms/{vmId}/start", path: (id) => `/v1/vms/${id}/start`, scope: "vm:write" },
  { name: "stopVm", method: "POST", template: "/v1/vms/{vmId}/stop", path: (id) => `/v1/vms/${id}/stop`, scope: "vm:write" },
  { name: "pauseVm", method: "POST", template: "/v1/vms/{vmId}/pause", path: (id) => `/v1/vms/${id}/pause`, scope: "vm:write" },
  { name: "resumeVm", method: "POST", template: "/v1/vms/{vmId}/resume", path: (id) => `/v1/vms/${id}/resume`, scope: "vm:write" },
  { name: "forkVm", method: "POST", template: "/v1/vms/{vmId}/fork", path: (id) => `/v1/vms/${id}/fork`, scope: "vm:write", json: {} },
  { name: "deleteVm", method: "DELETE", template: "/v1/vms/{vmId}", path: (id) => `/v1/vms/${id}`, scope: "vm:write" },
  {
    name: "execVm",
    method: "POST",
    template: "/v1/vms/{vmId}/exec",
    path: (id) => `/v1/vms/${id}/exec`,
    scope: "vm:exec",
    json: { command: "id -u" },
  },
  {
    name: "readFile",
    method: "GET",
    template: "/v1/vms/{vmId}/files/content",
    path: (id) => `/v1/vms/${id}/files/content?path=%2Fetc%2Fhostname`,
    scope: "vm:files",
  },
  {
    name: "writeFile",
    method: "PUT",
    template: "/v1/vms/{vmId}/files/content",
    path: (id) => `/v1/vms/${id}/files/content?path=%2Ftmp%2Fnote.txt`,
    scope: "vm:files",
    bytes: new TextEncoder().encode("hello"),
  },
  {
    name: "listFiles",
    method: "GET",
    template: "/v1/vms/{vmId}/files/entries",
    path: (id) => `/v1/vms/${id}/files/entries?path=%2Ftmp`,
    scope: "vm:files",
  },
  // Snapshots and terminals (slice S3a).
  {
    name: "createSnapshot",
    method: "POST",
    template: "/v1/vms/{vmId}/snapshots",
    path: (id) => `/v1/vms/${id}/snapshots`,
    scope: "snapshot:write",
    json: {},
  },
  { name: "openTerminal", method: "GET", template: "/v1/vms/{vmId}/terminal", path: (id) => `/v1/vms/${id}/terminal`, scope: "vm:terminal" },
  { name: "listTerminals", method: "GET", template: "/v1/vms/{vmId}/terminals", path: (id) => `/v1/vms/${id}/terminals`, scope: "vm:terminal" },
  {
    name: "attachTerminal",
    method: "GET",
    template: "/v1/vms/{vmId}/terminals/{terminal}",
    path: (id) => `/v1/vms/${id}/terminals/1`,
    scope: "vm:terminal",
  },
  {
    name: "closeTerminal",
    method: "DELETE",
    template: "/v1/vms/{vmId}/terminals/{terminal}",
    path: (id) => `/v1/vms/${id}/terminals/1`,
    scope: "vm:terminal",
  },
  // Client sessions (agent keys); test/workers/agent-keys.test.ts covers the rest.
  { name: "listClientSessions", method: "GET", template: "/v1/vms/{vmId}/client-sessions", path: (id) => `/v1/vms/${id}/client-sessions`, scope: "vm:exec" },
  { name: "createClientSession", method: "POST", template: "/v1/vms/{vmId}/client-session", path: (id) => `/v1/vms/${id}/client-session`, scope: "vm:exec", json: {} },
  {
    name: "revokeClientSession",
    method: "DELETE",
    template: "/v1/vms/{vmId}/client-sessions/{sessionId}",
    path: (id) => `/v1/vms/${id}/client-sessions/vcs_00000000000000000000000000`,
    scope: "vm:exec",
  },
];

/** Endpoints that act on one snapshot (slice S3a); test/workers/snapshots.test.ts runs the isolation cases. */
export const SNAPSHOT_ENDPOINTS = [
  { name: "getSnapshotCreation", method: "GET", template: "/v1/snapshot-creations/{snapshotId}", scope: "snapshot:read" },
  { name: "reconcileSnapshotCreation", method: "POST", template: "/v1/snapshot-creations/{snapshotId}/reconcile", scope: "snapshot:write" },
  { name: "cancelSnapshotCreation", method: "POST", template: "/v1/snapshot-creations/{snapshotId}/cancel", scope: "snapshot:write" },
  { name: "getSnapshot", method: "GET", template: "/v1/snapshots/{snapshotId}", scope: "snapshot:read" },
  { name: "deleteSnapshot", method: "DELETE", template: "/v1/snapshots/{snapshotId}", scope: "snapshot:write" },
] as const;

/** Endpoints that act on the tenant rather than one VM. */
export const TENANT_ENDPOINTS = [
  { name: "cancelSnapshotCreationByKey", method: "POST", template: "/v1/snapshot-creations/by-key/cancel", scope: "snapshot:write", json: { expectedSnapshotId: null } },
  { name: "getSnapshotCreationByKey", method: "GET", template: "/v1/snapshot-creations/by-key", scope: "snapshot:read" },
  { name: "listSnapshotCreations", method: "GET", template: "/v1/snapshot-creations", scope: "snapshot:read" },
  { name: "listVmCreations", method: "GET", template: "/v1/vm-creations", scope: "vm:read" },
  { name: "cancelVmCreation", method: "POST", template: "/v1/vm-creations/by-key/cancel", scope: "vm:write" },
  { name: "getVmCreation", method: "GET", template: "/v1/vm-creations/by-key", scope: "vm:read" },
  { name: "reconcileVmCreation", method: "POST", template: "/v1/vm-creations/by-key/reconcile", scope: "vm:write" },
  { name: "createVm", method: "POST", template: "/v1/vms", scope: "vm:write" },
  { name: "listVms", method: "GET", template: "/v1/vms", scope: "vm:read" },
  { name: "listVmImages", method: "GET", template: "/v1/vm-images", scope: "vm:read" },
  { name: "listSnapshots", method: "GET", template: "/v1/snapshots", scope: "snapshot:read" },
  // API key management (cx-b4h.12); test/workers/api-keys.test.ts runs the isolation cases.
  { name: "createApiKey", method: "POST", template: "/v1/api-keys", scope: "admin" },
  { name: "listApiKeys", method: "GET", template: "/v1/api-keys", scope: "admin" },
  { name: "revokeApiKey", method: "DELETE", template: "/v1/api-keys/{keyId}", scope: "admin" },
  // Agent keys; test/workers/agent-keys.test.ts runs the isolation cases.
  { name: "createAgentKey", method: "POST", template: "/v1/agent-keys", scope: "vm:write" },
  { name: "revokeAgentKey", method: "DELETE", template: "/v1/agent-keys/{keyId}", scope: "vm:write" },
] as const;

export const ALL_SCOPES: ReadonlyArray<Scope> = SCOPES;

/**
 * Mesh experiment endpoints (cx-0op); test/workers/mesh.test.ts runs the
 * isolation cases. `target` says which public id the path names: the tenant
 * (no id), a mesh, a device, a tunnel, or a mesh plus a VM.
 */
export const MESH_ENDPOINTS = [
  { name: "createMesh", method: "POST", template: "/v1/meshes", scope: "mesh:write", target: "tenant" },
  { name: "listMeshes", method: "GET", template: "/v1/meshes", scope: "mesh:read", target: "tenant" },
  { name: "getMesh", method: "GET", template: "/v1/meshes/{meshId}", scope: "mesh:read", target: "mesh" },
  { name: "deleteMesh", method: "DELETE", template: "/v1/meshes/{meshId}", scope: "mesh:write", target: "mesh" },
  { name: "enrollDevice", method: "POST", template: "/v1/meshes/{meshId}/devices", scope: "mesh:join", target: "mesh" },
  { name: "listDevices", method: "GET", template: "/v1/meshes/{meshId}/devices", scope: "mesh:read", target: "mesh" },
  { name: "getMeshAcl", method: "GET", template: "/v1/meshes/{meshId}/acl", scope: "acl:read", target: "mesh" },
  { name: "putMeshAcl", method: "PUT", template: "/v1/meshes/{meshId}/acl", scope: "acl:write", target: "mesh" },
  { name: "attachMeshVm", method: "PUT", template: "/v1/meshes/{meshId}/vms/{vmId}", scope: "mesh:write", target: "member" },
  { name: "detachMeshVm", method: "DELETE", template: "/v1/meshes/{meshId}/vms/{vmId}", scope: "mesh:write", target: "member" },
  { name: "getDevice", method: "GET", template: "/v1/devices/{deviceId}", scope: "mesh:read", target: "device" },
  { name: "deleteDevice", method: "DELETE", template: "/v1/devices/{deviceId}", scope: "mesh:join", target: "device" },
  { name: "getDevicePeers", method: "GET", template: "/v1/devices/{deviceId}/peers", scope: "mesh:join", target: "device" },
  { name: "getDeviceOverlayPolicy", method: "GET", template: "/v1/devices/{deviceId}/overlay-policy", scope: "mesh:join", target: "device" },
  { name: "createOverlayServerCode", method: "POST", template: "/v1/meshes/{meshId}/overlay-server-codes", scope: "mesh:join", target: "mesh" },
  { name: "enrollOverlayServer", method: "POST", template: "/v1/meshes/{meshId}/overlay-servers", scope: "mesh:join", target: "mesh" },
  { name: "listOverlayServers", method: "GET", template: "/v1/meshes/{meshId}/overlay-servers", scope: "mesh:read", target: "mesh" },
  { name: "getOverlayServer", method: "GET", template: "/v1/overlay-servers/{deviceId}", scope: "mesh:join", target: "device" },
  { name: "getOverlayServerPolicy", method: "GET", template: "/v1/overlay-servers/{deviceId}/policy", scope: "mesh:join", target: "device" },
  { name: "revokeOverlayServer", method: "DELETE", template: "/v1/overlay-servers/{deviceId}", scope: "mesh:join", target: "device" },
  { name: "getTunnel", method: "GET", template: "/v1/tunnels/{tunnelId}", scope: "mesh:read", target: "tunnel" },
  // M2 (cx-0op.4). The code enrollment route has no bearer; test/workers/mesh-m2.test.ts covers it.
  { name: "createEnrollmentCode", method: "POST", template: "/v1/meshes/{meshId}/enrollment-codes", scope: "mesh:join", target: "mesh" },
  { name: "rotateDeviceKey", method: "POST", template: "/v1/devices/{deviceId}/rotate-key", scope: "mesh:join", target: "device" },
] as const;

/** Every scope that does not grant `scope`: the scope itself and its family scope (`snapshot:*`) are left out. */
export const allScopesExcept = (scope: Scope): ReadonlyArray<Scope> =>
  ALL_SCOPES.filter((candidate) => candidate !== scope && !(candidate.endsWith(":*") && scope.startsWith(candidate.slice(0, -1))));

export const bearer = (token: string) => ({ authorization: `Bearer ${token}` });
