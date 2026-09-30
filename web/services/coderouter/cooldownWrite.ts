import { sql, type SQL, type SQLWrapper } from "drizzle-orm";

/** Failure reasons that require human intervention instead of waiting. */
export const NON_TRANSIENT_FAILURE_CODES = new Set(["invalid_credential"]);

export function isNonTransientFailureCode(failureCode: string | null | undefined): boolean {
  return failureCode !== null && failureCode !== undefined && NON_TRANSIENT_FAILURE_CODES.has(failureCode);
}

export function nonTransientFailureCodePredicate(column: SQLWrapper): SQL {
  return sql.join(
    [...NON_TRANSIENT_FAILURE_CODES].map(code => sql`${column} IS NOT DISTINCT FROM ${code}`),
    sql` OR `,
  );
}

/**
 * Keeps the longest cooldown and gives non-transient reasons precedence over
 * transient reasons, so the stored reason always describes why an account
 * cannot be used.
 *
 * Both rules are expressed as SQL so the write stays a single statement. A late
 * provider error must never shorten a longer cooldown already recorded by
 * another request, and the database value stays authoritative so every web
 * instance avoids a capacity-hit account consistently.
 */
export function buildCooldownWriteExpressions(
  cooldownUntilColumn: SQLWrapper,
  lastFailureCodeColumn: SQLWrapper,
  until: Date,
  failureCode: string,
): { cooldownUntil: SQL; lastFailureCode: SQL } {
  const cooldownUntilIso = until.toISOString();
  const storedReasonIsNonTransient = nonTransientFailureCodePredicate(lastFailureCodeColumn);
  const newReasonWins = isNonTransientFailureCode(failureCode)
    ? sql`true`
    : sql`NOT (${storedReasonIsNonTransient})
        AND (${cooldownUntilColumn} IS NULL
          OR ${cooldownUntilIso}::timestamptz > ${cooldownUntilColumn})`;
  return {
    cooldownUntil: sql`GREATEST(COALESCE(${cooldownUntilColumn}, ${cooldownUntilIso}::timestamptz), ${cooldownUntilIso}::timestamptz)`,
    lastFailureCode: sql`CASE
      WHEN ${newReasonWins} THEN ${failureCode}
      ELSE ${lastFailureCodeColumn}
    END`,
  };
}
