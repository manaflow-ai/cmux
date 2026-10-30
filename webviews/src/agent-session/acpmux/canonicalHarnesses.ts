import { agentKey } from "../shared/agentKey";
import { agentDisplayName } from "./agents";
import type { QuickFamily } from "./QuickModelMenu";

/// Claude and Codex launch configurations share one harness tab. Keep the running
/// configuration's models and exact id; switching variants still uses its original callback.
export function canonicalHarnesses(list: QuickFamily[], running?: string): QuickFamily[] {
  const key = (row: QuickFamily) => {
    if (row.starred) return undefined;
    const id = agentKey(row.id);
    const mark = agentKey(row.mark);
    if (id === "claude" || mark === "claude") return "claude";
    if (id === "codex" || mark === "codex" || mark === "openai") return "codex";
    return undefined;
  };
  const seen = new Set<string>();
  return list.flatMap((row) => {
    const brand = key(row);
    if (!brand) return [row];
    if (seen.has(brand)) return [];
    seen.add(brand);
    const members = list.filter((candidate) => key(candidate) === brand);
    const selected =
      members.find((candidate) => candidate.id === running) ??
      members.find((candidate) => candidate.id === brand) ??
      members.find((candidate) => !candidate.launch) ??
      row;
    return [
      {
        ...selected,
        name: agentDisplayName(brand),
        mark: brand,
        launch: false,
        variants: members.filter((candidate) => candidate.id !== selected.id || selected.launch),
      },
    ];
  });
}
