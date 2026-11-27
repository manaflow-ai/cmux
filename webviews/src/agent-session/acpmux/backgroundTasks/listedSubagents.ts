// A chat's subagents as acpmux's subagent tree lists them (`_acpmux/subagents`,
// cmux-tui/crates/acpmux/src/hub/subagent_list.rs), for the Background tasks panel.
//
// The panel used to find subagents only in the rows its page holds, the chat's newest few thousand
// records: a coordinator that started its helpers hours ago had none of them there, so the panel
// said "Nothing runs in the background" while a hundred ran (Leo, 2026-11-24: "this bugged? or had
// an ultra slow load"). acpmux keeps every subagent's last state in the tree it already folds, and
// the panel lists the ones its rows lack from that (backgroundTasks.ts `listed`).
import type { BackgroundState } from "./backgroundTasks";

export type ListedSubagent = {
  id: string;
  /// The subagent that started it; null for one the chat itself started.
  parent: string | null;
  title?: string;
  state: BackgroundState;
  background: boolean;
  /// `workflow` for a Claude workflow.
  kind?: string;
  toolCallId?: string;
  /// Epoch ms, on acpmux's clock.
  startedAt?: number;
  endedAt?: number;
};

export type SubagentListing = {
  /// Every running one, oldest first.
  running: ListedSubagent[];
  /// The latest ended ones, latest first.
  ended: ListedSubagent[];
  endedOmitted: number;
  seen: number;
};

const STATES = new Set<BackgroundState>(["running", "done", "failed", "stopped"]);

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined;
const time = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;

function listed(value: unknown): ListedSubagent | undefined {
  if (!value || typeof value !== "object") return undefined;
  const item = value as Record<string, unknown>;
  const id = text(item.id);
  const state = item.state as BackgroundState;
  if (!id || !STATES.has(state)) return undefined;
  return {
    id,
    parent: text(item.parent) ?? null,
    title: text(item.title),
    state,
    background: item.background === true,
    kind: text(item.kind),
    toolCallId: text(item.toolCallId),
    startedAt: time(item.startedAt),
    endedAt: time(item.endedAt),
  };
}

/// Reads an `_acpmux/subagents` answer; anything malformed in it is left out.
export function subagentListing(result: unknown): SubagentListing {
  const reply = (result && typeof result === "object" ? result : {}) as Record<string, unknown>;
  const list = (value: unknown) =>
    (Array.isArray(value) ? value : []).flatMap((each) => {
      const item = listed(each);
      return item ? [item] : [];
    });
  return {
    running: list(reply.running),
    ended: list(reply.ended),
    endedOmitted: typeof reply.endedOmitted === "number" ? reply.endedOmitted : 0,
    seen: typeof reply.seen === "number" ? reply.seen : 0,
  };
}
