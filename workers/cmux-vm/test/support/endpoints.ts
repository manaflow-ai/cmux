/**
 * Every endpoint that acts on one VM, with the scope it needs and a valid
 * request for it. The isolation suite runs each one as another tenant and as a
 * key without the scope, and checks that this table covers openapi.json.
 */
import type { Scope } from "../../src/domain/scopes.ts";

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
];

/** Endpoints that act on one snapshot (slice S3a); test/workers/snapshots.test.ts runs the isolation cases. */
export const SNAPSHOT_ENDPOINTS = [
  { name: "getSnapshot", method: "GET", template: "/v1/snapshots/{snapshotId}", scope: "snapshot:read" },
  { name: "deleteSnapshot", method: "DELETE", template: "/v1/snapshots/{snapshotId}", scope: "snapshot:write" },
] as const;

/** Endpoints that act on the tenant rather than one VM. */
export const TENANT_ENDPOINTS = [
  { name: "createVm", method: "POST", template: "/v1/vms", scope: "vm:write" },
  { name: "listVms", method: "GET", template: "/v1/vms", scope: "vm:read" },
  { name: "listSnapshots", method: "GET", template: "/v1/snapshots", scope: "snapshot:read" },
  // API key management (cx-b4h.12); test/workers/api-keys.test.ts runs the isolation cases.
  { name: "createApiKey", method: "POST", template: "/v1/api-keys", scope: "admin" },
  { name: "listApiKeys", method: "GET", template: "/v1/api-keys", scope: "admin" },
  { name: "revokeApiKey", method: "DELETE", template: "/v1/api-keys/{keyId}", scope: "admin" },
] as const;

export const ALL_SCOPES: ReadonlyArray<Scope> = [
  "vm:read",
  "vm:write",
  "vm:exec",
  "vm:files",
  "vm:terminal",
  "snapshot:*",
  "snapshot:read",
  "snapshot:write",
  "domain:*",
  "deploy:*",
  "git:*",
  "mesh:read",
  "mesh:write",
  "mesh:join",
  "acl:read",
  "acl:write",
  "admin",
];

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
  { name: "getTunnel", method: "GET", template: "/v1/tunnels/{tunnelId}", scope: "mesh:read", target: "tunnel" },
  // M2 (cx-0op.4). The code enrollment route has no bearer; test/workers/mesh-m2.test.ts covers it.
  { name: "createEnrollmentCode", method: "POST", template: "/v1/meshes/{meshId}/enrollment-codes", scope: "mesh:join", target: "mesh" },
  { name: "rotateDeviceKey", method: "POST", template: "/v1/devices/{deviceId}/rotate-key", scope: "mesh:join", target: "device" },
] as const;

/** Every scope that does not grant `scope`: the scope itself and its family scope (`snapshot:*`) are left out. */
export const allScopesExcept = (scope: Scope): ReadonlyArray<Scope> =>
  ALL_SCOPES.filter((candidate) => candidate !== scope && !(candidate.endsWith(":*") && scope.startsWith(candidate.slice(0, -1))));

export const bearer = (token: string) => ({ authorization: `Bearer ${token}` });
