import { Effect } from "effect";
import { and, eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { coderouterAccounts, coderouterClaudeAccounts } from "../../db/schema";

export type AccountVisibility = "private" | "team";
export function parseAccountVisibility(value: unknown): AccountVisibility | null {
  return value === "private" || value === "team" ? value : null;
}

/** Membership is checked by the route. Sharing belongs to the importer alone,
 * including when the caller is an admin; ownerless legacy rows stay shared. */
export function changeAccountVisibility(input: {
  readonly teamId: string;
  readonly userId: string;
  readonly accountId: string;
  readonly family: "native" | "claude";
  readonly visibility: AccountVisibility;
}) {
  return Effect.tryPromise(async () => {
    const table = input.family === "native" ? coderouterAccounts : coderouterClaudeAccounts;
    // Only the recorded importer changes sharing. Every team member reaches
    // this route, so an ownerless legacy row must never be claimable: it
    // stays shared, and members can still manage or remove it.
    const rows = await cloudDb().update(table).set({
      visibility: input.visibility,
      updatedAt: new Date(),
    }).where(and(eq(table.teamId, input.teamId), eq(table.id, input.accountId),
      eq(table.createdBy, input.userId),
    )).returning({ id: table.id, visibility: table.visibility });
    return rows[0] ?? null;
  });
}
