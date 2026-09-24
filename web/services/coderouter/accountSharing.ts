import { Effect } from "effect";
import { and, eq, isNull, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { coderouterAccounts, coderouterClaudeAccounts } from "../../db/schema";

export type AccountVisibility = "private" | "team";
export function parseAccountVisibility(value: unknown): AccountVisibility | null {
  return value === "private" || value === "team" ? value : null;
}

/** Membership/management permission is checked by the route. Private imports
 * are additionally owned by a person, including when the caller is an admin. */
export function changeAccountVisibility(input: {
  readonly teamId: string;
  readonly userId: string;
  readonly accountId: string;
  readonly family: "native" | "claude";
  readonly visibility: AccountVisibility;
}) {
  return Effect.tryPromise(async () => {
    const table = input.family === "native" ? coderouterAccounts : coderouterClaudeAccounts;
    const rows = await cloudDb().update(table).set({
      visibility: input.visibility,
      createdBy: sql`coalesce(${table.createdBy}, ${input.userId})`,
      updatedAt: new Date(),
    }).where(and(eq(table.teamId, input.teamId), eq(table.id, input.accountId),
      or(eq(table.createdBy, input.userId), and(isNull(table.createdBy), eq(table.visibility, "team"))),
    )).returning({ id: table.id, visibility: table.visibility });
    return rows[0] ?? null;
  });
}
