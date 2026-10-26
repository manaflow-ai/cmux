/**
 * Mesh networking parity (cx-0op, plans/cmux-next/freestyle-parity.md rows
 * 26-28): the provider's private-network, tunnel and firewall reads and
 * renames, mapped onto the mesh model instead of exposing provider objects. A
 * provider network is a mesh, a tunnel is a mesh device, and the firewall is
 * the mesh ACL with the provider rules it compiled to. Same experiment gate,
 * scopes and per-tenant 404s as src/api/mesh.ts.
 */
import { HttpApiEndpoint, HttpApiGroup } from "@effect/platform";
import { Schema } from "effect";
import { BadRequest, NotFound, QuotaExceeded } from "../errors.ts";
import { DeviceId, MeshId, TunnelId, VmId } from "../lib/ids.ts";
import { Device, Mesh } from "./mesh.ts";
import { describe, DisplayName, GroupTeamHeaders } from "./common.ts";

const EXPERIMENT = "Experiment: answers 404 unless the mesh experiment is enabled for the team.";
const OWN =
  "Only the principal that enrolled the device or a tenant admin (an API key with the admin scope, or a team admin session) sees it; anyone else gets 404.";

const DeviceName = Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9][A-Za-z0-9._ -]{0,62}$/u));

export class UpdateMeshRequest extends Schema.Class<UpdateMeshRequest>("UpdateMeshRequest")(
  { displayName: Schema.NullOr(DisplayName).annotations({ description: "The new name; null clears it." }) },
  { description: "Only the name changes: the mesh keeps its id, address block, devices, VMs and ACL." },
) {}

export class UpdateDeviceRequest extends Schema.Class<UpdateDeviceRequest>("UpdateDeviceRequest")(
  { name: DeviceName },
  { description: "Only the name changes: keys, tunnel, addresses and firewall rules are untouched, so a connected device sees nothing change." },
) {}

export const MeshAddress = Schema.Struct({
  kind: Schema.Literal("vm", "device"),
  id: Schema.String.annotations({ description: "The VM's vm_ id or the device's dev_ id." }),
  ipv4: Schema.NullOr(Schema.String).annotations({ description: "Its IPv4 address inside the mesh; null when none is assigned." }),
}).annotations({ identifier: "MeshAddress" });

export class MeshAddressList extends Schema.Class<MeshAddressList>("MeshAddressList")({
  meshId: MeshId,
  items: Schema.Array(MeshAddress),
}) {}

export const TunnelSummary = Schema.Struct({
  id: TunnelId,
  deviceId: DeviceId,
  meshId: MeshId,
  name: Schema.String,
  createdAt: Schema.String,
}).annotations({ identifier: "TunnelSummary" });

export class TunnelList extends Schema.Class<TunnelList>("TunnelList")({ items: Schema.Array(TunnelSummary) }) {}

export const FirewallRuleId = Schema.String.pipe(Schema.pattern(/^fwr_[0-9a-f]{32}$/u)).annotations({
  description: "Stable for as long as the rule exists; derived from the rule itself, never a provider id.",
});

export const MeshFirewallRule = Schema.Struct({
  id: FirewallRuleId,
  meshId: MeshId,
  deviceId: DeviceId,
  vmId: VmId,
  source: Schema.Literal("tunnel", "address").annotations({
    description: "tunnel: traffic through the device's tunnel. address: the device's published public IPv6 address to the VM's overlay endpoint (UDP 4101) only.",
  }),
  protocol: Schema.NullOr(Schema.Literal("tcp", "udp", "icmp")).annotations({ description: "null: every protocol." }),
  port: Schema.NullOr(Schema.Int).annotations({ description: "null: every port of the protocol." }),
  createdAt: Schema.String,
}).annotations({ identifier: "MeshFirewallRule" });

export class MeshFirewallRuleList extends Schema.Class<MeshFirewallRuleList>("MeshFirewallRuleList")({
  meshId: MeshId,
  aclVersion: Schema.Int,
  items: Schema.Array(MeshFirewallRule),
}) {}

export class EvaluateMeshAclRequest extends Schema.Class<EvaluateMeshAclRequest>("EvaluateMeshAclRequest")(
  {
    src: Schema.String.pipe(Schema.maxLength(64)).annotations({ description: "The dev_ id of the device that opens the connection." }),
    dst: Schema.String.pipe(Schema.maxLength(64)).annotations({ description: "The vm_ or dev_ id it connects to." }),
    protocol: Schema.Literal("tcp", "udp", "icmp"),
    port: Schema.optional(Schema.Int.pipe(Schema.between(1, 65535))).annotations({ description: "Required for tcp and udp; not allowed for icmp." }),
  },
  { description: "A connection to check against the mesh's current ACL. Nothing changes." },
) {}

export class MeshAclEvaluation extends Schema.Class<MeshAclEvaluation>("MeshAclEvaluation")({
  meshId: MeshId,
  aclVersion: Schema.Int,
  allowed: Schema.Boolean,
  path: Schema.Literal("firewall", "overlay").annotations({
    description: "firewall: a device to a VM, enforced by provider firewall rules. overlay: a device to a device, enforced by directed overlay permissions.",
  }),
  ruleIndex: Schema.NullOr(Schema.Int).annotations({ description: "The index in the ACL's rules of the first rule that allows it; null when denied (default deny)." }),
}) {}

const MeshPath = Schema.Struct({ meshId: Schema.String });
const DevicePath = Schema.Struct({ deviceId: Schema.String });
const RulePath = Schema.Struct({ meshId: Schema.String, ruleId: Schema.String });

/** Endpoints without the Authentication middleware; src/api.ts applies it. */
export class MeshNetworkGroupDefinition extends HttpApiGroup.make("meshNetwork")
  .add(
    HttpApiEndpoint.patch("updateMesh", "/v1/meshes/:meshId")
      .setPath(MeshPath)
      .setPayload(UpdateMeshRequest)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(Mesh)
      .addError(BadRequest)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Rename a mesh", "mesh:write", `A session must be a team admin. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.get("listMeshAddresses", "/v1/meshes/:meshId/addresses")
      .setPath(MeshPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(MeshAddressList)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "List the addresses assigned in a mesh",
          "mesh:read",
          `Each member VM's address and each device's address as mesh members see it. A tenant admin sees every device; any other principal only the devices it enrolled. ${EXPERIMENT}`,
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("listTunnels", "/v1/tunnels")
      .setHeaders(GroupTeamHeaders)
      .addSuccess(TunnelList)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "List the team's device tunnels",
          "mesh:read",
          `Every mesh's device tunnels, without keys or configs (GET /v1/tunnels/{tunnelId} returns a config). A tenant admin sees every tunnel; any other principal only those of devices it enrolled. ${EXPERIMENT}`,
        ),
      ),
  )
  .add(
    HttpApiEndpoint.patch("updateDevice", "/v1/devices/:deviceId")
      .setPath(DevicePath)
      .setPayload(UpdateDeviceRequest)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(Device)
      .addError(BadRequest)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Rename a device and its tunnel", "mesh:join", `${OWN} ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.get("listMeshFirewallRules", "/v1/meshes/:meshId/acl/rules")
      .setPath(MeshPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(MeshFirewallRuleList)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "List the firewall rules a mesh's ACL compiled to",
          "acl:read",
          `The provider firewall rules in place for this mesh, one per device, VM and port, as the last apply left them. Device-to-device permissions are not firewall rules; read them with GET /v1/devices/{deviceId}/overlay-policy. ${EXPERIMENT}`,
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("getMeshFirewallRule", "/v1/meshes/:meshId/acl/rules/:ruleId")
      .setPath(RulePath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(MeshFirewallRule)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Get one firewall rule of a mesh", "acl:read", `An unknown rule, or another mesh's, is 404. ${EXPERIMENT}`)),
  )
  .add(
    HttpApiEndpoint.post("evaluateMeshAcl", "/v1/meshes/:meshId/acl/evaluate")
      .setPath(MeshPath)
      .setPayload(EvaluateMeshAclRequest)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(MeshAclEvaluation)
      .addError(BadRequest)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Check whether the mesh's ACL allows a connection",
          "acl:read",
          `Evaluated by the same compiler an apply uses, against the current ACL and the mesh's current devices and VMs; changes nothing. A src that is not a device of this mesh, or a dst that is not one of its devices or VMs, is 400. ${EXPERIMENT}`,
        ),
      ),
  ) {}
