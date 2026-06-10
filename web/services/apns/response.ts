import type { ApnsSendResult } from "./sender";

export interface PushSendSummary {
  readonly sent: number;
  readonly devices: number;
  readonly pruned: number;
}

export function summarizeApnsSendResults(results: readonly ApnsSendResult[]): PushSendSummary {
  const sent = results.filter((r) => r.status >= 200 && r.status < 300).length;
  const pruned = results.filter((r) => r.prune).length;
  return { sent, devices: results.length, pruned };
}
