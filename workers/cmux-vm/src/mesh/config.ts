/**
 * Mesh experiment configuration (cx-0op, workers/cmux-vm/mesh/M1-PLAN.md).
 *
 * The experiment is off unless CMUX_VM_MESH_EXPERIMENT is "1" AND the
 * caller's tenant is listed in CMUX_VM_MESH_TENANT_IDS. While it is off for a
 * tenant, every mesh route answers 404 before any store or upstream call, so
 * the feature cannot be told apart from a route that does not exist.
 *
 * Budgets are the experiment values from DESIGN.md section 7.1. They are
 * configuration, not secrets.
 */
import { Context, Layer } from "effect";
import type { TenantId } from "../lib/ids.ts";

export interface MeshBudgets {
  /** Meshes per tenant (`mesh.perTenant`). */
  readonly meshesPerTenant: number;
  /** Devices per mesh (`device.perMesh`). */
  readonly devicesPerMesh: number;
  /** Compiled firewall rules per mesh (`firewallRule.perMesh`). */
  readonly rulesPerMesh: number;
  /**
   * Compiled rules that may name one VM or tunnel (`firewallRule.perResource`).
   * The provider refuses the 201st rule on one resource (measured, DESIGN.md
   * 1.4 Q3); 180 keeps 10 % headroom.
   */
  readonly rulesPerResource: number;
  /** ACL applies per mesh per minute (`aclApply.perMeshPerMinute`). */
  readonly aclAppliesPerMinute: number;
  /** Enrollment codes per mesh per hour (`enrollmentCode.perMeshPerHour`, M2). */
  readonly enrollmentCodesPerHour: number;
}

export const DEFAULT_MESH_BUDGETS: MeshBudgets = {
  meshesPerTenant: 1,
  devicesPerMesh: 50,
  rulesPerMesh: 500,
  rulesPerResource: 180,
  aclAppliesPerMinute: 10,
  enrollmentCodesPerHour: 20,
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
  readonly enabledFor: (tenantId: TenantId) => boolean;
  /** CMUX_VM_MESH_EXPERIMENT itself: off means no mesh route reads anything, even before a tenant is known. */
  readonly experiment: boolean;
  readonly budgets: MeshBudgets;
}

export class MeshConfig extends Context.Tag("cmux-vm/MeshConfig")<MeshConfig, MeshConfigService>() {}

export interface MeshConfigInput {
  readonly experiment: boolean;
  readonly tenantIds: ReadonlyArray<string>;
  readonly budgets?: Partial<MeshBudgets>;
}

export const makeMeshConfig = (input: MeshConfigInput): MeshConfigService => {
  const allowed = new Set(input.tenantIds);
  return {
    enabledFor: (tenantId) => input.experiment && allowed.has(tenantId),
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
