import { createHmac } from "node:crypto";

export function coderouterTeamAnalyticsId(
  teamId: string,
  scopeSecret: string,
): string {
  const digest = createHmac("sha256", scopeSecret)
    // Keep this domain stable: the fixed customer endpoint groups historical
    // aggregate usage by this pseudonym.
    .update("coderouter-team-usage:v2\0")
    .update(teamId)
    .digest("hex");
  return `coderouter-team-${digest}`;
}

export function coderouterUserAnalyticsId(
  userId: string,
  scopeSecret: string,
): string {
  const digest = createHmac("sha256", scopeSecret)
    .update("coderouter-user-product:v1\0")
    .update(userId)
    .digest("hex");
  return `coderouter-user-${digest}`;
}
