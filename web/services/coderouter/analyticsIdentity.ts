import { createHash } from "node:crypto";

export function coderouterTeamAnalyticsId(teamId: string): string {
  const digest = createHash("sha256")
    .update(`coderouter-team-usage:v1:${teamId}`)
    .digest("hex");
  return `coderouter-team-${digest}`;
}
