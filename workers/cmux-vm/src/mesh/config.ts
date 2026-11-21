/**
 * Mesh experiment configuration (cx-0op, workers/cmux-vm/mesh/M1-PLAN.md).
 *
 * The experiment is off unless CMUX_VM_MESH_EXPERIMENT is "1" AND either the
 * caller's tenant is listed in CMUX_VM_MESH_TENANT_IDS or the actor is a
 * service key listed in CMUX_VM_MESH_SERVICE_IDS, for any team it acts for.
 * The actor is the request's own principal, or, for a credential-free request
 * (an enrollment code, a device signature), the `created_by` of the row it
 * redeems. The tenant's other callers still see no mesh route. (A service
 * never owns such a row today: actorOf refuses `service:` creators.) While it
 * is off for a request, every mesh route answers 404 before any store or upstream call, so
 * the feature cannot be told apart from a route that does not exist.
 *
 * Budgets are the experiment values from DESIGN.md section 7.1. They are
 * configuration, not secrets.
 */
import { Context, Layer } from "effect";
import type { TenantId } from "../lib/ids.ts";
import { DEFAULT_OVERLAY_RULES_PER_DEVICE, DEFAULT_OVERLAY_RULES_PER_MESH } from "./acl.ts";

export interface MeshBudgets {
  /** Meshes per tenant (`mesh.perTenant`). */
  readonly meshesPerTenant: number;
  /** Devices per mesh (`device.perMesh`). */
  readonly devicesPerMesh: number;
  /** Provider-free, destination-only servers per mesh; separate from tunnel capacity. */
  readonly overlayServersPerMesh: number;
  /** Compiled firewall rules per mesh (`firewallRule.perMesh`). */
  readonly rulesPerMesh: number;
  /**
   * Compiled rules that may name one VM or tunnel (`firewallRule.perResource`).
   * The provider refuses the 201st rule on one resource (measured, DESIGN.md
   * 1.4 Q3); 180 keeps 10 % headroom.
   */
  readonly rulesPerResource: number;
  /** Directed overlay rules; independent of provider firewall capacity. */
  readonly overlayRulesPerMesh: number;
  /** Counts both incoming and outgoing overlay permissions. */
  readonly overlayRulesPerDevice: number;
  /** ACL applies per mesh per minute (`aclApply.perMeshPerMinute`). */
  readonly aclAppliesPerMinute: number;
  /** Least time between two changes of one device's published IPv6 address (each change reconciles the mesh). */
  readonly addressChangeIntervalMs: number;
  /** Enrollment codes per mesh per hour (`enrollmentCode.perMeshPerHour`, M2). */
  readonly enrollmentCodesPerHour: number;
  /** Approved provider-free server invitations per mesh per hour. */
  readonly overlayServerCodesPerHour: number;
  /**
   * Longest receiving-policy lease a VM receiver gets (`checkedAt` to `expiresAt`), before owner leases narrow it.
   * Receivers older than cmux#35467 refuse a lease over 30 s; newer ones renew ahead by their measured read time
   * and accept up to RECEIVER_POLICY_LEASE_MAX_MS.
   */
  readonly receiverPolicyLeaseMs: number;
}

export const DEFAULT_MESH_BUDGETS: MeshBudgets = {
  meshesPerTenant: 1,
  devicesPerMesh: 50,
  overlayServersPerMesh: 50,
  rulesPerMesh: 500,
  rulesPerResource: 180,
  overlayRulesPerMesh: DEFAULT_OVERLAY_RULES_PER_MESH,
  overlayRulesPerDevice: DEFAULT_OVERLAY_RULES_PER_DEVICE,
  aclAppliesPerMinute: 10,
  addressChangeIntervalMs: 10_000,
  enrollmentCodesPerHour: 20,
  overlayServerCodesPerHour: 20,
  receiverPolicyLeaseMs: 30_000,
};

/** The receiver's own cap (cmux-link `MAX_POLICY_LEASE_MS`). */
export const RECEIVER_POLICY_LEASE_MAX_MS = 120_000;

/**
 * CMUX_VM_RECEIVER_POLICY_LEASE_MS: a whole number of milliseconds from 1000 to RECEIVER_POLICY_LEASE_MAX_MS.
 * Anything else (unset included) keeps the 30 s default, which every receiver accepts.
 */
export const parseReceiverPolicyLease = (value: string | undefined): number => {
  const ms = Number(value?.trim() ?? "");
  return value !== undefined && /^\d+$/u.test(value.trim()) && ms >= 1000 && ms <= RECEIVER_POLICY_LEASE_MAX_MS
    ? ms
    : DEFAULT_MESH_BUDGETS.receiverPolicyLeaseMs;
};

/** How long an enrollment code stays valid (DESIGN.md section 3). */
export const ENROLLMENT_CODE_TTL_MS = 10 * 60_000;

/** WireGuard settings every device config carries (measured, DESIGN.md 1.4 Q11 and Q14). */
export const MESH_MTU = 1280;
export const MESH_PERSISTENT_KEEPALIVE_SECONDS = 25;

/** Each mesh gets one unique IPv4 /20 out of 10.128.0.0/9: 2048 slots. */
export const MESH_SUPERNET_FIRST_OCTETS = [10, 128] as const;
export const MESH_SLOTS = 2048;

export interface MeshConfigService {
  /** `actor` is an actorRef (`service:<id>`, `user:<id>`, `key:<id>`): the caller, or the creator of the row a credential-free request redeems. */
  readonly enabledFor: (tenantId: TenantId, actor: string) => boolean;
  /** The configured service actor refs that may bootstrap a tenant's mesh. */
  readonly serviceActors: ReadonlySet<string>;
  /** CMUX_VM_MESH_EXPERIMENT itself: off means no mesh route reads anything, even before a tenant is known. */
  readonly experiment: boolean;
  readonly budgets: MeshBudgets;
}

export class MeshConfig extends Context.Tag("cmux-vm/MeshConfig")<MeshConfig, MeshConfigService>() {}

export interface MeshConfigInput {
  readonly experiment: boolean;
  readonly tenantIds: ReadonlyArray<string>;
  /** Service key ids (CMUX_VM_MESH_SERVICE_IDS) whose requests have the experiment for any team they act for. */
  readonly serviceIds?: ReadonlyArray<string>;
  readonly budgets?: Partial<MeshBudgets>;
}

export const makeMeshConfig = (input: MeshConfigInput): MeshConfigService => {
  const allowed = new Set(input.tenantIds);
  const services = new Set((input.serviceIds ?? []).map((id) => `service:${id}`));
  return {
    enabledFor: (tenantId, actor) => input.experiment && (allowed.has(tenantId) || services.has(actor)),
    serviceActors: services,
    experiment: input.experiment,
    budgets: { ...DEFAULT_MESH_BUDGETS, ...input.budgets },
  };
};

export const meshConfigLayer = (input: MeshConfigInput): Layer.Layer<MeshConfig> => Layer.succeed(MeshConfig, makeMeshConfig(input));

/** CMUX_VM_MESH_EXPERIMENT: only the exact string "1" turns the experiment on. */
export const parseMeshExperiment = (value: string | undefined): boolean => value?.trim() === "1";

/** The /20 for slot `slot` (0-based): 10.128.0.0/20, 10.128.16.0/20, ... 10.255.240.0/20. */
export const slotCidr = (slot: number): string => {
  if (!Number.isInteger(slot) || slot < 0 || slot >= MESH_SLOTS) throw new Error("mesh slot out of range");
  const second = MESH_SUPERNET_FIRST_OCTETS[1] + Math.floor(slot / 16);
  const third = (slot % 16) * 16;
  return `${MESH_SUPERNET_FIRST_OCTETS[0]}.${second}.${third}.0/20`;
};
