import { Context, Effect } from "effect";
import type { StoreError } from "../db/sql.ts";

export interface UsageQuery {
  readonly tenantId: string;
  readonly from: Date;
  readonly to: Date;
  readonly vmId: string | null;
  readonly allowedVmIds: ReadonlySet<string> | null;
}

export interface UsageVmSummary {
  readonly vmId: string;
  readonly vcpuHours: number;
  readonly memoryGibHours: number;
  readonly storageGibHours: number;
  readonly listCostMicrodollars: number;
  readonly markedUpCostMicrodollars: number;
}

export interface UsageTotals {
  readonly vcpuHours: number;
  readonly memoryGibHours: number;
  readonly storageGibHours: number;
  readonly listCostMicrodollars: number;
  readonly markedUpCostMicrodollars: number;
}

export interface UsageReport {
  readonly items: ReadonlyArray<UsageVmSummary>;
  readonly total: UsageTotals;
}

export interface MeteringResource {
  readonly tenantId: string;
  readonly cmuxVmId: string;
  readonly upstreamVmId: string;
}

export interface MeteringProviderVm {
  readonly state: string;
  readonly vcpus: number;
  readonly memoryMb: number;
  readonly storageMb: number;
}

export type MeteringProviderRead =
  | { readonly kind: "present"; readonly vm: MeteringProviderVm }
  | { readonly kind: "gone" }
  | { readonly kind: "unavailable" };

export interface MeteringLedgerService {
  readonly usage: (query: UsageQuery) => Effect.Effect<UsageReport, StoreError>;
  readonly reconcile: (
    now: Date,
    read: (resource: MeteringResource) => Effect.Effect<MeteringProviderRead>,
  ) => Effect.Effect<void, StoreError>;
  readonly exportStripe: (now: Date) => Effect.Effect<void, StoreError>;
}

export class MeteringLedger extends Context.Tag("cmux-vm/MeteringLedger")<MeteringLedger, MeteringLedgerService>() {}

export interface TenantBillingAccount {
  readonly tenantId: string;
  readonly stripeCustomerId: string;
  readonly status: string;
}

export interface TenantBillingAccountsService {
  readonly activeForTenant: (tenantId: string) => Effect.Effect<TenantBillingAccount | null, StoreError>;
  readonly active: () => Effect.Effect<ReadonlyArray<TenantBillingAccount>, StoreError>;
}

export class TenantBillingAccounts extends Context.Tag("cmux-vm/TenantBillingAccounts")<
  TenantBillingAccounts,
  TenantBillingAccountsService
>() {}
