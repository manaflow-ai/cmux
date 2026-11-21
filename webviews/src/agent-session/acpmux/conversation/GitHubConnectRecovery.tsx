import { useMemo } from "react";
import type { AcpmuxActivity } from "../model";
import { experimentArm } from "../../../experiments/experiment";
import { GitHubConnectCard } from "./GitHubConnectCard";
import { githubConnect } from "./githubConnect.experiment";
import { needsGitHubConnection } from "./githubConnectModel";

export function GitHubConnectRecovery({ tool }: { tool: NonNullable<AcpmuxActivity["tool"]> }) {
  const needed = useMemo(() => needsGitHubConnection(tool), [tool]);
  // Unrelated rows never read localStorage. No host request runs until the opt-in button is clicked.
  return needed && experimentArm(githubConnect) === "on" ? <GitHubConnectCard /> : null;
}
