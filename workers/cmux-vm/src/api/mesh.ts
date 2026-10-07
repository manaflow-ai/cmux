/**
 * Mesh experiment endpoints (cx-0op, workers/cmux-vm/mesh/M1-PLAN.md): a
 * private network per team that devices join with their own WireGuard key,
 * with an ACL the cmux VM API owns. Off unless the experiment is enabled for
 * the team; every route then answers 404.
 */
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema } from "@effect/platform";
import { Schema } from "effect";
import { BadRequest, Conflict, NotFound, PaymentRequired, QuotaExceeded } from "../errors.ts";
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

export class EnrollDeviceRequest extends Schema.Class<EnrollDeviceRequest>("EnrollDeviceRequest")({
  name: DeviceName,
  wgPublicKey: WgPublicKey,
}) {}

export class Device extends Schema.Class<Device>("Device")({
  id: DeviceId,
  meshId: MeshId,
  name: Schema.String,
  wgPublicKey: Schema.String,
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

const MeshPath = Schema.Struct({ meshId: Schema.String });
const DevicePath = Schema.Struct({ deviceId: Schema.String });
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
      .annotateContext(describe("List a mesh's devices", "mesh:read", EXPERIMENT)),
  )
  .add(
    HttpApiEndpoint.get("getDevice", "/v1/devices/:deviceId")
      .setPath(DevicePath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(Device)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Get a device", "mesh:read", EXPERIMENT)),
  )
  .add(
    HttpApiEndpoint.del("deleteDevice", "/v1/devices/:deviceId")
      .setPath(DevicePath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Remove a device and its tunnel", "mesh:join", `Access ends within a second. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.get("getDevicePeers", "/v1/devices/:deviceId/peers")
      .setPath(DevicePath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(PeerMap)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("What this device may reach", "mesh:join", `Compiled from the current ACL. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.get("getTunnel", "/v1/tunnels/:tunnelId")
      .setPath(TunnelPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(TunnelConfig)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Get a device tunnel's config", "mesh:read", `Never includes a private key. ${EXPERIMENT}`)),
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
