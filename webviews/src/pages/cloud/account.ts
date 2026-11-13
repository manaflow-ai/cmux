// The account side of the Cloud page: teams (not served yet), the plan with its limits and usage
// (`cloud.plan.get`), plan checkout (`cloud.billing.checkout`, a money action) and the one-way move
// of cmux Cloud classic machines (`cloud.migration.status` and `.start`, contract 4; "Later" is kept
// per account in this browser). The plan is read
// on sign-in and after a confirmed change that may move its usage; the page never computes a limit.
import type { PageClient } from "../shared/pageClient";
import type { CloudState } from "./store";
import {
  type PlanRefusal,
  ACTION_RUN,
  AccountOps,
  CloudOps,
  isUnsupported,
  type ActionRunResult,
  type CloudPlan,
  type CloudTeam,
  type MigrationStarted,
  type MigrationStatus,
} from "./ops";

export interface AccountHost {
  get(): CloudState;
  set(patch: Partial<CloudState>): void;
  /** The store's session: a reply from an older one is dropped. */
  session(): number;
  fail(op: string, error: unknown): void;
  unsupported(op: string): void;
  canChange(): boolean;
  key(): string;
}

/** The classic migration banner shows: classic machines wait to move and "Later" was not chosen. */
export function migrationBanner(state: Pick<CloudState, "migration" | "migrationDismissed">): number | undefined {
  const migration = state.migration;
  if (state.migrationDismissed || migration?.state !== "available" || migration.classic_count <= 0) return undefined;
  return migration.classic_count;
}

/** The browser key of the accounts that chose "Later" on the migration banner. */
const MIGRATION_LATER_KEY = "cmux.cloud.migration.later";
/** How many accounts the key keeps (the oldest goes first). */
const MIGRATION_LATER_MAX = 20;

/** The account a "Later" is kept for: the team the host signed in to (`cloud.auth.status`). */
export function migrationAccount(state: Pick<CloudState, "auth">): string | undefined {
  return state.auth?.signedIn ? (state.auth.team ?? "") : undefined;
}

function safeStorage(): Storage | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

function readLater(storage: Pick<Storage, "getItem"> | undefined): string[] {
  try {
    const list: unknown = JSON.parse(storage?.getItem(MIGRATION_LATER_KEY) ?? "[]");
    return Array.isArray(list) ? list.filter((item): item is string => typeof item === "string") : [];
  } catch {
    return [];
  }
}

/** Whether `account` chose "Later" in this browser. Storage can be absent or refuse: then no. */
export function migrationLater(
  account: string,
  storage: Pick<Storage, "getItem"> | undefined = safeStorage(),
): boolean {
  return readLater(storage).includes(account);
}

/** Keeps `account`'s "Later", so the banner stays hidden on the next page open. */
export function keepMigrationLater(
  account: string,
  storage: Pick<Storage, "getItem" | "setItem"> | undefined = safeStorage(),
): void {
  const list = [...readLater(storage).filter((item) => item !== account), account].slice(-MIGRATION_LATER_MAX);
  try {
    storage?.setItem(MIGRATION_LATER_KEY, JSON.stringify(list));
  } catch {
    // A private window or a full store: the banner shows again next time, nothing else changes.
  }
}

/**
 * Whether a newer plan read lifts `refusal`: the plan changed, the spending cap is no longer reached,
 * or usage is under every machine limit again. A member budget and a locked size stay until the next
 * action or Dismiss (the plan says nothing about them).
 */
export function planLifts(refusal: PlanRefusal, before: CloudPlan | undefined, after: CloudPlan): boolean {
  if (before && before.plan_id !== after.plan_id) return true;
  switch (refusal.kind) {
    case "spend_cap":
      return after.spend_cap?.state !== "at_cap";
    case "quota_exceeded":
      return after.usage.active < after.limits.max_active && after.usage.saved < after.limits.max_saved;
    case "plan_required":
    case "size_locked":
    case "member_budget":
      return false;
  }
}

/** The user moved: classic machines may be upgraded one at a time (contract 4.4). */
export function canUpgradeClassic(migration: MigrationStatus | undefined): boolean {
  return migration?.state === "moved";
}

export class AccountReader {
  constructor(
    private readonly client: PageClient | null,
    private readonly host: AccountHost,
  ) {}

  /** After the machine list: teams, the plan and the migration status, each on its own. */
  async load(session: number): Promise<void> {
    const client = this.client;
    if (!client) return;
    const [teams, plan, migration] = await Promise.allSettled([
      client.call<CloudTeam[]>(AccountOps.teamList, {}),
      client.call<CloudPlan>(CloudOps.planGet, {}),
      client.call<MigrationStatus>(CloudOps.migrationStatus, {}),
    ]);
    if (session !== this.host.session()) return;
    for (const [op, result] of [
      [AccountOps.teamList, teams],
      [CloudOps.planGet, plan],
      [CloudOps.migrationStatus, migration],
    ] as const)
      if (result.status === "rejected" && isUnsupported(result.reason)) this.host.unsupported(op);
    const account = migrationAccount(this.host.get());
    this.host.set({
      teams: teams.status === "fulfilled" ? teams.value : [],
      plan: plan.status === "fulfilled" ? plan.value : undefined,
      planFailed: plan.status === "rejected" && !isUnsupported(plan.reason),
      migration: migration.status === "fulfilled" ? migration.value : undefined,
      // "Later" is kept per account across page opens.
      migrationDismissed: account !== undefined && migrationLater(account),
    });
  }

  /** Reads the plan again (usage moved). A failure keeps the plan the page has. */
  async readPlan(session: number): Promise<void> {
    if (!this.client || this.host.get().unavailable.includes(CloudOps.planGet)) return;
    try {
      const before = this.host.get().plan;
      const plan = await this.client.call<CloudPlan>(CloudOps.planGet, {});
      if (session !== this.host.session()) return;
      // A plan refusal the new plan lifts (an upgrade, a cap reset, a machine gone) is no longer true.
      const refusal = this.host.get().refusal;
      const lifted = refusal !== undefined && planLifts(refusal, before, plan);
      this.host.set({ plan, planFailed: false, ...(lifted ? { refusal: undefined } : {}) });
    } catch {
      // The plan shown stays; the next change or page open reads it again. Without one, the
      // storefront shows the failure and Retry.
      if (session === this.host.session() && !this.host.get().plan) this.host.set({ planFailed: true });
    }
  }

  /** "See plans": the host confirms, then opens the checkout URL in the browser (D-MONEY). */
  async checkout(plan: string): Promise<void> {
    if (!this.client || !this.host.canChange()) return;
    try {
      await this.client.call<ActionRunResult | null>(ACTION_RUN, {
        action: CloudOps.billingCheckout,
        args: { plan, idempotency_key: this.host.key() },
      });
    } catch (error) {
      this.host.fail(CloudOps.billingCheckout, error);
    }
  }

  /** "Move them": one way, per user, after the host's confirmation. The banner hides on its answer. */
  async startMigration(): Promise<void> {
    if (!this.client || !this.host.canChange()) return;
    const session = this.host.session();
    try {
      const result = await this.client.call<(ActionRunResult & Partial<MigrationStarted>) | null>(ACTION_RUN, {
        action: CloudOps.migrationStart,
        args: { idempotency_key: this.host.key() },
      });
      if (result?.confirmed === false || session !== this.host.session()) return;
      const current = this.host.get().migration;
      if (current && result?.state) this.host.set({ migration: { ...current, state: result.state } });
    } catch (error) {
      if (session === this.host.session()) this.host.fail(CloudOps.migrationStart, error);
    }
  }

  /** "Later": the banner stays hidden for this account, on this page and the next ones. */
  dismissMigration(): void {
    const account = migrationAccount(this.host.get());
    if (account !== undefined) keepMigrationLater(account);
    if (!this.host.get().migrationDismissed) this.host.set({ migrationDismissed: true });
  }
}
