import { createHmac } from "node:crypto";

export function coderouterTeamAnalyticsId(
  teamId: string,
  scopeSecret: string,
): string {
  const digest = createHmac("sha256", scopeSecret)
    .update("coderouter-team-usage:v2\0")
    .update(teamId)
    .digest("hex");
  return `coderouter-team-${digest}`;
}
