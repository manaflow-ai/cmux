// The account side of the Cloud page: teams (not served yet), the plan with its limits and usage
// (`cloud.plan.get`), plan checkout (`cloud.billing.checkout`, a money action) and the one-way move
// of cmux Cloud classic machines (`cloud.migration.status` and `.start`, contract 4). The plan is read
// on sign-in and after a confirmed change that may move its usage; the page never computes a limit.
import type { PageClient } from "../shared/pageClient";
import type { CloudState } from "./store";
import {
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
    this.host.set({
      teams: teams.status === "fulfilled" ? teams.value : [],
      plan: plan.status === "fulfilled" ? plan.value : undefined,
      migration: migration.status === "fulfilled" ? migration.value : undefined,
    });
  }

  /** Reads the plan again (usage moved). A failure keeps the plan the page has. */
  async readPlan(session: number): Promise<void> {
    if (!this.client || this.host.get().unavailable.includes(CloudOps.planGet)) return;
    try {
      const plan = await this.client.call<CloudPlan>(CloudOps.planGet, {});
      if (session === this.host.session()) this.host.set({ plan });
    } catch {
      // The plan shown stays; the next change or page open reads it again.
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

  /** "Later": the banner stays hidden for this page session. */
  dismissMigration(): void {
    if (!this.host.get().migrationDismissed) this.host.set({ migrationDismissed: true });
  }
}
