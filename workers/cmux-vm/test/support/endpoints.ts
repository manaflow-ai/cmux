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
];

/** Endpoints that act on the tenant rather than one VM. */
export const TENANT_ENDPOINTS = [
  { name: "createVm", method: "POST", template: "/v1/vms", scope: "vm:write" },
  { name: "listVms", method: "GET", template: "/v1/vms", scope: "vm:read" },
] as const;

export const ALL_SCOPES: ReadonlyArray<Scope> = [
  "vm:read",
  "vm:write",
  "vm:exec",
  "vm:files",
  "vm:terminal",
  "snapshot:*",
  "domain:*",
  "deploy:*",
  "git:*",
  "admin",
];

export const allScopesExcept = (scope: Scope): ReadonlyArray<Scope> => ALL_SCOPES.filter((candidate) => candidate !== scope);

export const bearer = (token: string) => ({ authorization: `Bearer ${token}` });
