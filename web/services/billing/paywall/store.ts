// Postgres persistence for paywall experiments: sticky assignments, the
// change log and optimizer runs (db/schema.ts).

import { and, desc, eq, sql } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import { paywallAssignments, paywallExperimentChanges, paywallExperimentRuns } from "../../../db/schema";

type Db = ReturnType<typeof cloudDb>;

export type PaywallAssignment = {
  readonly variant: string;
  readonly payload: unknown;
  readonly assignedAt: Date;
};

export type PaywallChangeKind =
  | "variant_created"
  | "variant_retired"
  | "copy_changed"
  | "payload_invalid"
  | "allocation_changed"
  | "srm_halt";

export type PaywallChange = {
  readonly experiment: string;
  readonly kind: PaywallChangeKind;
  readonly variant: string | null;
  readonly reason: string;
  readonly details: Record<string, unknown> | null;
  readonly actor: string;
  readonly changedAt?: Date;
};

export type PaywallRun = {
  readonly experiment: string;
  readonly ranAt: Date;
  readonly halted: boolean;
  readonly snapshot: unknown;
  readonly reportMarkdown: string;
};

export type PaywallAssignmentStore = {
  readonly assignment: (userId: string, experiment: string) => Promise<PaywallAssignment | null>;
  /** Records the served variant; `assigned_at` keeps the first assignment of that variant. */
  readonly recordServed: (userId: string, experiment: string, variant: string, payload: unknown) => Promise<void>;
};

export type PaywallExperimentLog = {
  readonly appendChanges: (changes: readonly PaywallChange[]) => Promise<void>;
  readonly recordRun: (run: PaywallRun) => Promise<void>;
  readonly latestRun: (experiment: string) => Promise<PaywallRun | null>;
  readonly changes: (experiment: string, limit: number) => Promise<readonly (PaywallChange & { readonly changedAt: Date })[]>;
  readonly lastChangeAt: (experiment: string, kind: PaywallChangeKind) => Promise<Date | null>;
};

export function databasePaywallAssignmentStore(db: () => Db = cloudDb): PaywallAssignmentStore {
  return {
    assignment: async (userId, experiment) => {
      const [row] = await db()
        .select({ variant: paywallAssignments.variant, payload: paywallAssignments.payload, assignedAt: paywallAssignments.assignedAt })
        .from(paywallAssignments)
        .where(and(eq(paywallAssignments.userId, userId), eq(paywallAssignments.experiment, experiment)))
        .limit(1);
      return row ?? null;
    },
    recordServed: async (userId, experiment, variant, payload) => {
      await db()
        .insert(paywallAssignments)
        .values({ userId, experiment, variant, payload })
        .onConflictDoUpdate({
          target: [paywallAssignments.userId, paywallAssignments.experiment],
          set: {
            variant,
            payload,
            servedAt: sql`now()`,
            assignedAt: sql`case when ${paywallAssignments.variant} = ${variant} then ${paywallAssignments.assignedAt} else now() end`,
          },
        });
    },
  };
}

export function databasePaywallExperimentLog(db: () => Db = cloudDb): PaywallExperimentLog {
  return {
    appendChanges: async (changes) => {
      if (changes.length === 0) return;
      await db().insert(paywallExperimentChanges).values(changes.map((change) => ({
        experiment: change.experiment,
        kind: change.kind,
        variant: change.variant,
        reason: change.reason,
        details: change.details,
        actor: change.actor,
        ...(change.changedAt ? { changedAt: change.changedAt } : {}),
      })));
    },
    recordRun: async (run) => {
      await db().insert(paywallExperimentRuns).values(run);
    },
    latestRun: async (experiment) => {
      const [row] = await db()
        .select()
        .from(paywallExperimentRuns)
        .where(eq(paywallExperimentRuns.experiment, experiment))
        .orderBy(desc(paywallExperimentRuns.ranAt))
        .limit(1);
      return row ?? null;
    },
    changes: async (experiment, limit) => {
      const rows = await db()
        .select()
        .from(paywallExperimentChanges)
        .where(eq(paywallExperimentChanges.experiment, experiment))
        .orderBy(desc(paywallExperimentChanges.changedAt))
        .limit(limit);
      return rows.map((row) => ({
        experiment: row.experiment,
        kind: row.kind as PaywallChangeKind,
        variant: row.variant,
        reason: row.reason,
        details: (row.details ?? null) as Record<string, unknown> | null,
        actor: row.actor,
        changedAt: row.changedAt,
      }));
    },
    lastChangeAt: async (experiment, kind) => {
      const [row] = await db()
        .select({ changedAt: paywallExperimentChanges.changedAt })
        .from(paywallExperimentChanges)
        .where(and(eq(paywallExperimentChanges.experiment, experiment), eq(paywallExperimentChanges.kind, kind)))
        .orderBy(desc(paywallExperimentChanges.changedAt))
        .limit(1);
      return row?.changedAt ?? null;
    },
  };
}

/**
 * The variant a user was last served, for grant analytics. Best effort: a
 * lookup failure means no variant on the event, never a failed purchase.
 */
export async function servedPaywallVariant(
  userId: string,
  experiment: string,
  store: Pick<PaywallAssignmentStore, "assignment"> = databasePaywallAssignmentStore(),
): Promise<string | null> {
  try {
    return (await store.assignment(userId, experiment))?.variant ?? null;
  } catch {
    return null;
  }
}
