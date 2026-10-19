import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema, OpenApi } from "@effect/platform";
import { Schema } from "effect";
import { BadRequest, Conflict, Forbidden, NotFound, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
import { DeviceId, MeshId, TenantId } from "../lib/ids.ts";
import { InstallPublicKey } from "../mesh/signed-request.ts";
import { EnrollDeviceRequest, OverlayPolicy, SignedDeviceRequest, WgPublicKey } from "./mesh.ts";
import { describe, GroupCreateHeaders, GroupTeamHeaders } from "./common.ts";

export class OverlayServer extends Schema.Class<OverlayServer>("OverlayServer")({
  id: DeviceId, meshId: MeshId, name: Schema.String, wgPublicKey: WgPublicKey,
  installPublicKey: InstallPublicKey, createdAt: Schema.String,
  kind: Schema.Literal("server"), transport: Schema.Literal("overlay"),
}, { description: "A provider-free mesh server, excluded from source wildcards. Device-to-device initiation requires an explicit source-id grant. Enrollment does not enable a role, relay admission or execution." }) {}

export class OverlayServerList extends Schema.Class<OverlayServerList>("OverlayServerList")({ items: Schema.Array(OverlayServer) }) {}
export class OverlayServerPolicy extends OverlayPolicy.extend<OverlayServerPolicy>("OverlayServerPolicy")({
  tenantId: TenantId.annotations({ description: "The Native tenant that owns this mesh. A backend binding must match its authoritative tenant mapping and both public keys; an opaque mesh id alone is insufficient." }),
}) {}

const PATH = Schema.Struct({ deviceId: Schema.String });
const MESH_PATH = Schema.Struct({ meshId: Schema.String });
const EXPERIMENT = "Answers 404 unless the mesh experiment is enabled for this tenant.";
const OWN = "Only its enrolling principal or a tenant admin may read or revoke it; resource restrictions still apply.";

export const enrollOverlayServerEndpoint = HttpApiEndpoint.post("enrollOverlayServer", "/v1/meshes/:meshId/overlay-servers")
  .setPath(MESH_PATH).setHeaders(GroupCreateHeaders).setPayload(EnrollDeviceRequest).addSuccess(OverlayServer, { status: 201 })
  .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Enroll a provider-free server destination", "mesh:join", `Sign cmux-mesh-v1 with purpose enroll-overlay-server and the mesh id as target, the server's WireGuard/install keys and name. No tunnel is created. A fresh signed retry with unchanged identity returns the same record. ${EXPERIMENT}`));

export const listOverlayServersEndpoint = HttpApiEndpoint.get("listOverlayServers", "/v1/meshes/:meshId/overlay-servers")
  .setPath(MESH_PATH).setHeaders(GroupTeamHeaders).addSuccess(OverlayServerList).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("List visible provider-free servers", "mesh:read", `${OWN} ${EXPERIMENT}`));

export const getOverlayServerEndpoint = HttpApiEndpoint.get("getOverlayServer", "/v1/overlay-servers/:deviceId")
  .setPath(PATH).setHeaders(GroupTeamHeaders).addSuccess(OverlayServer).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Read a provider-free server", "mesh:join", `${OWN} ${EXPERIMENT}`));

export const getOverlayServerPolicyEndpoint = HttpApiEndpoint.get("getOverlayServerPolicy", "/v1/overlay-servers/:deviceId/policy")
  .setPath(PATH).setHeaders(GroupTeamHeaders).addSuccess(OverlayServerPolicy).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Read a server's directed overlay policy", "mesh:join", `${OWN} The server is excluded from source wildcards; an explicit source-id grant permits device-to-device initiation. ${EXPERIMENT}`));

export const revokeOverlayServerEndpoint = HttpApiEndpoint.del("revokeOverlayServer", "/v1/overlay-servers/:deviceId")
  .setPath(PATH).setHeaders(GroupTeamHeaders).addSuccess(HttpApiSchema.NoContent).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Revoke a provider-free server identity", "mesh:join", `${OWN} No provider I/O. New policy reads omit it. ${EXPERIMENT}`));

export const signedOverlayServerPolicyEndpoint = HttpApiEndpoint.post("signedOverlayServerPolicy", "/v1/overlay-servers/:deviceId/signed/policy")
  .setPath(PATH).setPayload(SignedDeviceRequest).addSuccess(OverlayServerPolicy)
  .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(OpenApi.annotations({ summary: "A server reads its own overlay policy", description: `No credential: sign with purpose overlay-server-policy, device id as target, empty WireGuard key/name and the recorded install key. Fresh (120 s), single use, owner checked afresh. Invalid identity is 404. ${EXPERIMENT}` }));

export const signedRevokeOverlayServerEndpoint = HttpApiEndpoint.post("signedRevokeOverlayServer", "/v1/overlay-servers/:deviceId/signed/revoke")
  .setPath(PATH).setPayload(SignedDeviceRequest).addSuccess(HttpApiSchema.NoContent)
  .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(OpenApi.annotations({ summary: "A server revokes its own overlay identity", description: `No credential: sign with distinct purpose revoke-overlay-server, device id as target, empty WireGuard key/name and the recorded install key. Fresh and single use. Existing grants do not activate another role. ${EXPERIMENT}` }));

export class OverlayServersGroupDefinition extends HttpApiGroup.make("overlayServers")
  .add(enrollOverlayServerEndpoint).add(listOverlayServersEndpoint).add(getOverlayServerEndpoint).add(getOverlayServerPolicyEndpoint).add(revokeOverlayServerEndpoint) {}
export class OverlayServerDeviceGroupDefinition extends HttpApiGroup.make("overlayServerDevice")
  .add(signedOverlayServerPolicyEndpoint).add(signedRevokeOverlayServerEndpoint) {}
