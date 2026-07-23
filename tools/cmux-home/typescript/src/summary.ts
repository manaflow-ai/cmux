import { adapterOrder, adapters } from "./adapters";
import {
  adapterCounts,
  groupSessionsByStatus,
  statusCounts,
  statusOrder,
  type HomeSession,
  type HomeState,
} from "./state";

export function renderSummary(state: HomeState): string {
  const countsByAdapter = adapterCounts(state.sessions);
  const countsByStatus = statusCounts(state.sessions);
  const lines = [
    "cmux home",
    `sessions: total=${state.sessions.length}`,
    `adapters: ${adapterOrder.map((adapter) => `${adapter}=${countsByAdapter[adapter]}`).join(" ")}`,
    `statuses: ${statusOrder.map((status) => `${status}=${countsByStatus[status]}`).join(" ")}`,
  ];

  for (const group of groupSessionsByStatus(state.sessions)) {
    if (group.sessions.length === 0) {
      continue;
    }
    lines.push("", `${group.status}:`);
    for (const session of group.sessions) {
      lines.push(`- ${summarySessionLine(session)}`);
    }
  }

  lines.push("", "task prompt: describe the next task for an agent");
  return `${lines.join("\n")}\n`;
}

function summarySessionLine(session: HomeSession): string {
  const parts = [
    `${session.adapter}/${session.sessionId ?? session.id}`,
    JSON.stringify(session.title),
  ];
  if (session.cwd) {
    parts.push(`cwd=${session.cwd}`);
  }
  if (session.branch) {
    parts.push(`branch=${session.branch}`);
  }
  if (session.resumeCommand) {
    parts.push(`resume=${JSON.stringify(session.resumeCommand)}`);
  }
  const gaps = adapters[session.adapter].featureGaps.length;
  parts.push(`gaps=${gaps}`);
  return parts.join(" ");
}
