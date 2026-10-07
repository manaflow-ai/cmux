/**
 * Provider networking for the mesh experiment (cx-0op), as handlers see it:
 * private networks (a mesh), tunnels (a device's), VM membership and firewall
 * rules. The implementation that holds the provider key is
 * src/upstream/live-mesh.ts. Every method demands gdp-ts proofs about its
 * exact named arguments; provider ids come only from proofs or from a create
 * the caller was proven to be allowed.
 */
import type { Named } from "@gdp-ts/core";
import { Context, type Effect } from "effect";
import type { DeviceId, MeshId, TenantId, TunnelId, UpstreamId, VmId } from "../lib/ids.ts";
import type { MeshProtocol } from "../mesh/acl.ts";
import type { DeviceHoldsKey } from "../proofs/device-holds-key.ts";
import type { CallerActsOnDevice } from "../proofs/device-owner.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import type { OwnedMeshRule, SameMesh } from "../proofs/same-mesh.ts";
import type { TenantMayCreate } from "../proofs/tenant-may-create.ts";
import type { TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import type { UpstreamError } from "./client.ts";

/** A private network the provider just created. Only `createNetwork` makes one. */
export interface CreatedNetwork {
  readonly upstreamId: UpstreamId;
  readonly cidr: string;
}

/** What a device needs to bring its tunnel up. Never a private key. */
export interface TunnelInfo {
  /** The gateway's IPv4 address (never the provider's per-tunnel name, which carries the provider id). */
  readonly endpointHost: string;
  readonly endpointPort: number;
  readonly serverPublicKey: string;
  /** The client's address inside the tunnel (the WireGuard interface address). */
  readonly interfaceAddress: string;
  /** The device's address inside the mesh, as VMs see it; null if the provider gave none. */
  readonly meshAddress: string | null;
  /** The tunnel's routes (WireGuard AllowedIPs). */
  readonly allowedIps: ReadonlyArray<string>;
}

/** A tunnel the provider just created. Only `createTunnel` makes one. */
export interface CreatedTunnel {
  readonly upstreamId: UpstreamId;
  readonly info: TunnelInfo;
}

export interface CreatedRule {
  readonly upstreamRuleId: string;
}

export interface UpstreamMeshService {
  readonly createNetwork: <C, M>(
    mesh: Named<M, MeshId>,
    proofs: { readonly scope: KeyHasScope<C, "mesh:write">; readonly mayCreate: TenantMayCreate<C, "mesh"> },
    options: { readonly tenantId: TenantId; readonly cidr: string },
  ) => Effect.Effect<CreatedNetwork, UpstreamError>;
  /** Undoes a create whose ownership row could not be written. Accepts only a value `createNetwork` returned. */
  readonly discardCreatedNetwork: (created: CreatedNetwork) => Effect.Effect<void, UpstreamError>;
  readonly deleteNetwork: <C, M>(
    mesh: Named<M, MeshId>,
    proofs: { readonly owns: TenantOwnsResource<C, M>; readonly scope: KeyHasScope<C, "mesh:write"> },
  ) => Effect.Effect<void, UpstreamError>;

  /**
   * Creates the device's tunnel with the device's own public key, routes
   * limited to the mesh (its IPv4 /20 and the provider's IPv6 /64 for it), attached to the mesh's network. Fails closed (and
   * deletes the tunnel) if the provider minted a private key.
   */
  readonly createTunnel: <C, M>(
    mesh: Named<M, MeshId>,
    proofs: {
      readonly owns: TenantOwnsResource<C, M>;
      readonly scope: KeyHasScope<C, "mesh:join">;
      readonly mayCreate: TenantMayCreate<C, "device">;
      /** The tunnel's client key is the key the device's install key signed for this mesh, never another. */
      readonly holds: DeviceHoldsKey<C, M>;
    },
    options: {
      readonly tenantId: TenantId;
      readonly deviceId: DeviceId;
      readonly routes: ReadonlyArray<string>;
    },
  ) => Effect.Effect<CreatedTunnel, UpstreamError>;
  readonly discardCreatedTunnel: (created: CreatedTunnel) => Effect.Effect<void, UpstreamError>;
  readonly getTunnel: <C, T>(
    tunnel: Named<T, TunnelId>,
    proofs: {
      readonly owns: TenantOwnsResource<C, T>;
      readonly scope: KeyHasScope<C, "mesh:read"> | KeyHasScope<C, "mesh:join">;
      readonly acts: CallerActsOnDevice<C, T>;
    },
  ) => Effect.Effect<TunnelInfo, UpstreamError>;
  /** A device's provider id is its tunnel's: this deletes exactly that tunnel (and the provider drops its rules). */
  readonly deleteDeviceTunnel: <C, D>(
    device: Named<D, DeviceId>,
    proofs: { readonly owns: TenantOwnsResource<C, D>; readonly scope: KeyHasScope<C, "mesh:join">; readonly acts: CallerActsOnDevice<C, D> },
  ) => Effect.Effect<void, UpstreamError>;

  /**
   * Replaces the device tunnel's client key with the key the install key
   * signed for this device (`rotate_tunnel_key`). The tunnel keeps its id,
   * routes and attachments; the server key changes. Fails (without returning
   * it) if the provider minted a private key.
   */
  readonly rotateTunnelKey: <C, D>(
    device: Named<D, DeviceId>,
    proofs: {
      readonly owns: TenantOwnsResource<C, D>;
      readonly scope: KeyHasScope<C, "mesh:join">;
      readonly acts: CallerActsOnDevice<C, D>;
      readonly holds: DeviceHoldsKey<C, D>;
    },
  ) => Effect.Effect<TunnelInfo, UpstreamError>;

  /** Puts the VM on the mesh's network (live; a VM is on at most one). Returns its IPv4 address there. */
  readonly attachVm: <C, M, V>(
    mesh: Named<M, MeshId>,
    vm: Named<V, VmId>,
    proofs: {
      readonly ownsMesh: TenantOwnsResource<C, M>;
      readonly ownsVm: TenantOwnsResource<C, V>;
      readonly meshScope: KeyHasScope<C, "mesh:write">;
      readonly vmScope: KeyHasScope<C, "vm:write">;
    },
  ) => Effect.Effect<{ readonly ipv4: string | null }, UpstreamError>;
  readonly detachVm: <C, V>(
    vm: Named<V, VmId>,
    proofs: { readonly ownsVm: TenantOwnsResource<C, V>; readonly vmScope: KeyHasScope<C, "vm:write"> },
  ) => Effect.Effect<void, UpstreamError>;

  /** `{device's tunnel} -> {vm, protocol, port}`; both ends proven members of the same mesh of the caller's tenant. */
  readonly createRule: <C, M, S, D>(
    mesh: Named<M, MeshId>,
    source: Named<S, DeviceId>,
    destination: Named<D, VmId>,
    proofs: { readonly source: SameMesh<C, M, S>; readonly destination: SameMesh<C, M, D> },
    matcher: { readonly protocol: MeshProtocol | null; readonly port: number | null },
  ) => Effect.Effect<CreatedRule, UpstreamError>;
  readonly deleteRule: <C, M>(rule: OwnedMeshRule<C, M>) => Effect.Effect<void, UpstreamError>;
}

export class UpstreamMesh extends Context.Tag("cmux-vm/UpstreamMesh")<UpstreamMesh, UpstreamMeshService>() {}
