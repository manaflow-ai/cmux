/**
 * Mesh experiment endpoints (cx-0op, workers/cmux-vm/mesh/M1-PLAN.md): a
 * private network per team that devices join with their own WireGuard key,
 * with an ACL the cmux VM API owns. Off unless the experiment is enabled for
 * the team; every route then answers 404.
 */
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema, OpenApi } from "@effect/platform";
import { Schema } from "effect";
import { BadRequest, Conflict, Forbidden, NotFound, PaymentRequired, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
import { InstallPublicKey, Nonce, Signature, SignedAt } from "../mesh/signed-request.ts";
import { DeviceId, MeshId, TunnelId, VmId } from "../lib/ids.ts";
import { describe, DisplayName, GroupCreateHeaders, GroupTeamHeaders } from "./common.ts";

const EXPERIMENT = "Experiment: answers 404 unless the mesh experiment is enabled for the team.";

/** A Curve25519 public key, base64 (32 bytes). */
export const WgPublicKey = Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/u)).annotations({
  description: "The device's WireGuard public key, base64. The private key never leaves the device.",
});

const DeviceName = Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9][A-Za-z0-9._ -]{0,62}$/u));

export class Mesh extends Schema.Class<Mesh>("Mesh")({
  id: MeshId,
  displayName: Schema.NullOr(Schema.String),
  ipv4Cidr: Schema.String.annotations({ description: "The mesh's IPv4 block; VMs and devices get addresses inside it." }),
  createdAt: Schema.String,
}) {}

export class MeshList extends Schema.Class<MeshList>("MeshList")({ items: Schema.Array(Mesh) }) {}

export class CreateMeshRequest extends Schema.Class<CreateMeshRequest>("CreateMeshRequest")({
  displayName: Schema.optional(DisplayName),
}) {}

const SIGNED =
  "Signed by the device's install key over the cmux-mesh-v1 message (workers/cmux-vm/src/mesh/signed-request.ts); a stale (more than 120 s off), forged or tampered request is 403, a replayed one 409.";

export class EnrollDeviceRequest extends Schema.Class<EnrollDeviceRequest>("EnrollDeviceRequest")(
  {
    name: DeviceName,
    wgPublicKey: WgPublicKey,
    installPublicKey: InstallPublicKey,
    signedAt: SignedAt,
    nonce: Nonce,
    signature: Signature,
  },
  { description: SIGNED },
) {}

/** A one-time enrollment code: `mec_` and 26 base32 characters (130 random bits). */
export const EnrollmentCodeValue = Schema.String.pipe(Schema.pattern(/^mec_[0-9a-hjkmnp-tv-z]{26}$/u)).annotations({
  description: "A one-time enrollment code. Shown once; the server stores only its SHA-256.",
});

export class CodeEnrollDeviceRequest extends Schema.Class<CodeEnrollDeviceRequest>("CodeEnrollDeviceRequest")(
  {
    code: EnrollmentCodeValue,
    name: DeviceName,
    wgPublicKey: WgPublicKey,
    installPublicKey: InstallPublicKey,
    signedAt: SignedAt,
    nonce: Nonce,
    signature: Signature,
  },
  { description: `Enroll with a one-time code instead of a credential. ${SIGNED}` },
) {}

export class CreateEnrollmentCodeRequest extends Schema.Class<CreateEnrollmentCodeRequest>("CreateEnrollmentCodeRequest")({}) {}

export class EnrollmentCode extends Schema.Class<EnrollmentCode>("EnrollmentCode")(
  {
    code: EnrollmentCodeValue,
    meshId: MeshId,
    expiresAt: Schema.String,
  },
  { description: "Single use, valid for 10 minutes. A device enrolled with it belongs to the principal that created it." },
) {}

export class RotateKeyRequest extends Schema.Class<RotateKeyRequest>("RotateKeyRequest")(
  {
    newPublicKey: WgPublicKey,
    signedAt: SignedAt,
    nonce: Nonce,
    signature: Signature,
  },
  { description: `The device's new WireGuard public key. ${SIGNED} The install key must be the one the device enrolled with.` },
) {}

export class SignedDeviceRequest extends Schema.Class<SignedDeviceRequest>("SignedDeviceRequest")(
  {
    signedAt: SignedAt,
    nonce: Nonce,
    signature: Signature,
  },
  {
    description:
      "A device's own request, authenticated only by its install key: the cmux-mesh-v1 message with purpose peers or tunnel, the device id as target, an empty WireGuard key and name, and the device's recorded install public key. Fresh (120 s) and single use.",
  },
) {}

export class Device extends Schema.Class<Device>("Device")({
  id: DeviceId,
  meshId: MeshId,
  name: Schema.String,
  wgPublicKey: Schema.String,
  installPublicKey: Schema.NullOr(Schema.String).annotations({ description: "The install key that signs this device's enroll and key rotation; null for a device enrolled before install keys." }),
  tunnelId: TunnelId,
  createdAt: Schema.String,
}) {}

export class DeviceList extends Schema.Class<DeviceList>("DeviceList")({ items: Schema.Array(Device) }) {}

export class TunnelConfig extends Schema.Class<TunnelConfig>("TunnelConfig")(
  {
    id: TunnelId,
    meshId: MeshId,
    deviceId: DeviceId,
    endpointHost: Schema.String,
    endpointPort: Schema.Int,
    serverPublicKey: Schema.String,
    interfaceAddress: Schema.String.annotations({ description: "The WireGuard interface address inside the tunnel." }),
    meshAddress: Schema.NullOr(Schema.String).annotations({ description: "The device's address as mesh members see it." }),
    allowedIps: Schema.Array(Schema.String),
    mtu: Schema.Int,
    persistentKeepaliveSeconds: Schema.Int.annotations({
      description: "Set it: the gateway forgets an idle session after 5 to 10 minutes.",
    }),
  },
  { description: "Everything a device needs to bring its tunnel up, except its own private key, which only the device has." },
) {}

export class DeviceEnrollment extends Schema.Class<DeviceEnrollment>("DeviceEnrollment")({ device: Device, tunnel: TunnelConfig }) {}

export class MeshMember extends Schema.Class<MeshMember>("MeshMember")({
  meshId: MeshId,
  vmId: VmId,
  ipv4: Schema.NullOr(Schema.String),
  attachedAt: Schema.String,
}) {}

const Selector = Schema.String.pipe(Schema.maxLength(64));
const AllowEntry = Schema.String.pipe(Schema.maxLength(16));

export const AclRule = Schema.Struct({
  src: Schema.Array(Selector).pipe(Schema.minItems(1), Schema.maxItems(64)).annotations({
    description: "Devices: dev_ ids or device:* (every device of the mesh).",
  }),
  dst: Schema.Array(Selector).pipe(Schema.minItems(1), Schema.maxItems(64)).annotations({
    description: "VMs: vm_ ids or vm:* (every VM member of the mesh).",
  }),
  allow: Schema.Array(AllowEntry).pipe(Schema.minItems(1), Schema.maxItems(64)).annotations({
    description: "tcp:<port>, udp:<port>, tcp:*, udp:*, icmp, or * (everything).",
  }),
}).annotations({ identifier: "AclRule" });

const AclRules = Schema.Array(AclRule).pipe(Schema.maxItems(200));

export class Acl extends Schema.Class<Acl>("Acl")({
  meshId: MeshId,
  version: Schema.Int.annotations({ description: "0 before the first apply." }),
  rules: AclRules,
  updatedAt: Schema.NullOr(Schema.String),
}) {}

export class PutAclRequest extends Schema.Class<PutAclRequest>("PutAclRequest")(
  {
    expectedVersion: Schema.Int.pipe(Schema.nonNegative()).annotations({ description: "The version this change is based on; 409 if another apply came first." }),
    rules: AclRules,
  },
  { description: "Default deny: only what these rules allow is reachable." },
) {}

export class AclApplied extends Schema.Class<AclApplied>("AclApplied")({
  meshId: MeshId,
  version: Schema.Int,
  ruleCount: Schema.Int,
  rulesCreated: Schema.Int,
  rulesDeleted: Schema.Int,
  applyMs: Schema.Int,
}) {}

export const PeerAllow = Schema.Struct({
  protocol: Schema.Literal("tcp", "udp", "icmp", "any"),
  port: Schema.optional(Schema.Int),
}).annotations({ identifier: "PeerAllow" });

export const Peer = Schema.Struct({
  kind: Schema.Literal("vm"),
  id: VmId,
  address: Schema.NullOr(Schema.String),
  allow: Schema.Array(PeerAllow),
}).annotations({ identifier: "Peer" });

export class PeerMap extends Schema.Class<PeerMap>("PeerMap")({
  deviceId: DeviceId,
  meshId: MeshId,
  aclVersion: Schema.Int,
  peers: Schema.Array(Peer),
}) {}

const OWN =
  "Only the principal that enrolled the device or a tenant admin (an API key with the admin scope, or a team admin session) sees it; anyone else gets 404.";

const MeshPath = Schema.Struct({ meshId: Schema.String });

/** Unauthenticated: the one-time code is the credential. src/api.ts adds this group without the Authentication middleware. */
export class MeshEnrollGroupDefinition extends HttpApiGroup.make("meshEnroll").add(
  HttpApiEndpoint.post("codeEnrollDevice", "/v1/meshes/:meshId/device-enrollments")
    .setPath(MeshPath)
    .setPayload(CodeEnrollDeviceRequest)
    .addSuccess(DeviceEnrollment, { status: 201 })
    .addError(BadRequest)
    .addError(Forbidden)
    .addError(NotFound)
    .addError(Conflict)
    .addError(PaymentRequired)
    .addError(QuotaExceeded)
    .addError(ServiceUnavailable)
    .annotateContext(
      OpenApi.annotations({
        summary: "Enroll a headless device with a one-time code",
        description: `Enroll a headless device with a one-time code. No credential: the code is single use and valid for 10 minutes, and the device belongs to the principal that created the code. An unknown, used, expired or other mesh's code is 404, and so is a code whose creator left the team or whose API key was revoked. Any authentication failure (a forged or stale signature, a replayed request, another mesh's path) burns the code. A device budget or provider failure after the code was accepted gives it back, so the same code can be used again. ${EXPERIMENT}`,
      }),
    ),
) {}
const DevicePath = Schema.Struct({ deviceId: Schema.String });

const DEVICE_SIGNED =
  "No credential: the device's install-key signature authenticates it for this one device only. An unknown or deleted device, a signature by another key, for another device or for another request, a device whose owner left the team or whose API key was revoked, and a team without the experiment are all 404; a stale signedAt (more than 120 s off) is 403, a replayed request 409.";

/**
 * Unauthenticated: the device's install-key signature is the credential (mesh
 * M3, cx-0op.5). A device enrolled with a one-time code has no API key or
 * session; these are the only calls it can make. src/api.ts adds this group
 * without the Authentication middleware.
 */
export class MeshDeviceGroupDefinition extends HttpApiGroup.make("meshDevice")
  .add(
    HttpApiEndpoint.post("signedDevicePeers", "/v1/devices/:deviceId/signed/peers")
      .setPath(DevicePath)
      .setPayload(SignedDeviceRequest)
      .addSuccess(PeerMap)
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        OpenApi.annotations({
          summary: "A device reads its own peer map",
          description: `What this device may reach, compiled from the current ACL; signed with purpose peers. ${DEVICE_SIGNED} ${EXPERIMENT}`,
        }),
      ),
  )
  .add(
    HttpApiEndpoint.post("signedDeviceTunnel", "/v1/devices/:deviceId/signed/tunnel")
      .setPath(DevicePath)
      .setPayload(SignedDeviceRequest)
      .addSuccess(TunnelConfig)
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        OpenApi.annotations({
          summary: "A device reads its own tunnel config",
          description: `Never includes a private key; signed with purpose tunnel. ${DEVICE_SIGNED} ${EXPERIMENT}`,
        }),
      ),
  )
  .add(
    HttpApiEndpoint.post("signedDeviceRotateKey", "/v1/devices/:deviceId/signed/rotate-key")
      .setPath(DevicePath)
      .setPayload(RotateKeyRequest)
      .addSuccess(TunnelConfig)
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        OpenApi.annotations({
          summary: "A device rotates its own WireGuard key",
          description: `The same signed body as POST /v1/devices/{deviceId}/rotate-key (purpose rotate-key), without a credential. Switch to the returned config at once. ${DEVICE_SIGNED} ${EXPERIMENT}`,
        }),
      ),
  ) {}

const TunnelPath = Schema.Struct({ tunnelId: Schema.String });
const MemberPath = Schema.Struct({ meshId: Schema.String, vmId: Schema.String });

/** Endpoints without the Authentication middleware; src/api.ts applies it. */
export class MeshGroupDefinition extends HttpApiGroup.make("mesh")
  .add(
    HttpApiEndpoint.post("createMesh", "/v1/meshes")
      .setPayload(CreateMeshRequest)
      .setHeaders(GroupCreateHeaders)
      .addSuccess(Mesh, { status: 201 })
      .addError(NotFound)
      .addError(PaymentRequired)
      .addError(QuotaExceeded)
      .annotateContext(describe("Create the team's mesh", "mesh:write", `A session must be a team admin. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.get("listMeshes", "/v1/meshes")
      .setHeaders(GroupTeamHeaders)
      .addSuccess(MeshList)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("List the team's meshes", "mesh:read", EXPERIMENT)),
  )
  .add(
    HttpApiEndpoint.get("getMesh", "/v1/meshes/:meshId")
      .setPath(MeshPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(Mesh)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Get a mesh", "mesh:read", EXPERIMENT)),
  )
  .add(
    HttpApiEndpoint.del("deleteMesh", "/v1/meshes/:meshId")
      .setPath(MeshPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(describe("Delete a mesh", "mesh:write", `409 while it has devices or VMs. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.post("enrollDevice", "/v1/meshes/:meshId/devices")
      .setPath(MeshPath)
      .setPayload(EnrollDeviceRequest)
      .setHeaders(GroupCreateHeaders)
      .addSuccess(DeviceEnrollment, { status: 201 })
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(Conflict)
      .addError(PaymentRequired)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Enroll a device with its own WireGuard public key",
          "mesh:join",
          `Creates the device's tunnel into the mesh and applies the current ACL before it answers. ${EXPERIMENT}`,
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("listDevices", "/v1/meshes/:meshId/devices")
      .setPath(MeshPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(DeviceList)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("List a mesh's devices", "mesh:read", `A tenant admin sees every device; any other principal only the devices it enrolled. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.get("getDevice", "/v1/devices/:deviceId")
      .setPath(DevicePath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(Device)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Get a device", "mesh:read", `Only the principal that enrolled the device or a tenant admin (an API key with the admin scope, or a team admin session) sees it; anyone else gets 404. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.del("deleteDevice", "/v1/devices/:deviceId")
      .setPath(DevicePath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Remove a device and its tunnel", "mesh:join", `Access ends within a second. Only the principal that enrolled the device or a tenant admin (an API key with the admin scope, or a team admin session) sees it; anyone else gets 404. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.get("getDevicePeers", "/v1/devices/:deviceId/peers")
      .setPath(DevicePath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(PeerMap)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("What this device may reach", "mesh:join", `Compiled from the current ACL. Only the principal that enrolled the device or a tenant admin (an API key with the admin scope, or a team admin session) sees it; anyone else gets 404. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.post("createEnrollmentCode", "/v1/meshes/:meshId/enrollment-codes")
      .setPath(MeshPath)
      .setPayload(CreateEnrollmentCodeRequest)
      .setHeaders(GroupCreateHeaders)
      .addSuccess(EnrollmentCode, { status: 201 })
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(
        describe("Create a one-time enrollment code for a headless machine", "mesh:join", `Single use, 10 minutes; at most 20 per mesh per hour. ${EXPERIMENT}`),
      ),
  )
  .add(
    HttpApiEndpoint.post("rotateDeviceKey", "/v1/devices/:deviceId/rotate-key")
      .setPath(DevicePath)
      .setPayload(RotateKeyRequest)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(TunnelConfig)
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        describe(
          "Rotate a device's WireGuard key",
          "mesh:join",
          `The tunnel keeps its id and addresses; the server key changes too, so switch to the returned config at once. The old key stops working within about a second. ${OWN} ${EXPERIMENT}`,
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("getTunnel", "/v1/tunnels/:tunnelId")
      .setPath(TunnelPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(TunnelConfig)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Get a device tunnel's config", "mesh:read", `Never includes a private key. Only the principal that enrolled the device or a tenant admin (an API key with the admin scope, or a team admin session) sees it; anyone else gets 404. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.put("attachMeshVm", "/v1/meshes/:meshId/vms/:vmId")
      .setPath(MemberPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(MeshMember)
      .addError(BadRequest)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(
        describe("Add a VM to a mesh", "mesh:write", `Also needs vm:write. Live on a running, stopped or paused VM; a VM is in at most one mesh. ${EXPERIMENT}`),
      ),
  )
  .add(
    HttpApiEndpoint.del("detachMeshVm", "/v1/meshes/:meshId/vms/:vmId")
      .setPath(MemberPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(describe("Remove a VM from a mesh", "mesh:write", `Also needs vm:write. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.get("getMeshAcl", "/v1/meshes/:meshId/acl")
      .setPath(MeshPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(Acl)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Get a mesh's ACL", "acl:read", EXPERIMENT)),
  )
  .add(
    HttpApiEndpoint.put("putMeshAcl", "/v1/meshes/:meshId/acl")
      .setPath(MeshPath)
      .setPayload(PutAclRequest)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(AclApplied)
      .addError(BadRequest)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Replace a mesh's ACL and apply it",
          "acl:write",
          `A session must be a team admin. New rules are created before old ones are deleted, so traffic both versions allow never stops. ${EXPERIMENT}`,
        ),
      ),
  ) {}
