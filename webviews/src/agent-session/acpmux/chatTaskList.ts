// A chat's task list across its turns (acpmux `taskList`, cmux-tui/crates/acpmux/src/task_list.rs;
// David Beyer, Nov 20 call: a task list that tracks what is done and what is next across long agent
// chats). The harness's own plan keeps it (Claude Code's TodoWrite, Codex's update_plan), else the
// chat's agent or its Chief (`_acpmux/task_list/set`). A turn's plan row folds when its turn ends
// and pages out of a long transcript; this one stays on the chat, so the composer's hat can show it
// between turns and after reopening the chat.
import type { AcpmuxPlanEntry } from "./model";

/// The summary's `taskList`, as the pane keeps it.
export type ChatTaskList = {
  /// Who keeps it: the harness's plan events, the chat's agent, or its Chief.
  readonly source: "harness" | "agent" | "chief";
  readonly done: number;
  readonly total: number;
  readonly items: readonly AcpmuxPlanEntry[];
  /// When it last changed, Unix ms: the same list keeps its object while this holds.
  readonly updatedAt: number;
};

const STATUSES = new Set<AcpmuxPlanEntry["status"]>(["pending", "in_progress", "completed"]);
const SOURCES = new Set<ChatTaskList["source"]>(["harness", "agent", "chief"]);

/// The summary's `taskList`, else undefined (absent, null, or a row that carries only its counts).
/// `previous` is returned as it is while the list has not changed, so the hat never redraws for a
/// summary that changed elsewhere.
export function chatTaskListOf(value: unknown, previous?: ChatTaskList): ChatTaskList | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const list = value as Record<string, unknown>;
  if (!Array.isArray(list.items)) return undefined;
  const updatedAt = typeof list.updatedAt === "number" ? list.updatedAt : 0;
  const source = SOURCES.has(list.source as ChatTaskList["source"])
    ? (list.source as ChatTaskList["source"])
    : "harness";
  const items: AcpmuxPlanEntry[] = [];
  for (const raw of list.items) {
    if (!raw || typeof raw !== "object") continue;
    const { content, status } = raw as { content?: unknown; status?: unknown };
    if (typeof content !== "string" || !content.trim()) continue;
    items.push({
      content,
      status: STATUSES.has(status as AcpmuxPlanEntry["status"]) ? (status as AcpmuxPlanEntry["status"]) : "pending",
    });
  }
  if (items.length === 0) return undefined;
  if (
    previous &&
    previous.updatedAt === updatedAt &&
    previous.source === source &&
    previous.items.length === items.length &&
    previous.items.every(
      (entry, index) => entry.content === items[index]!.content && entry.status === items[index]!.status,
    )
  )
    return previous;
  const done = items.filter((entry) => entry.status === "completed").length;
  return { source, done, total: items.length, items, updatedAt };
}

/// Whether steps are left.
export const hasStepsLeft = (list: ChatTaskList | undefined): list is ChatTaskList =>
  list !== undefined && list.done < list.total;

/// What the composer's hat shows as its plan. `live`: the running turn's own list; `earlier`: an
/// earlier turn's list with steps left that the transcript still holds; `list`: the chat's kept list.
/// - A running turn's own list leads, as before.
/// - A running turn without one shows the earlier list, marked as from before the person's last
///   message (nothing spins in it); the chat's list stands in for it when that turn's row paged out
///   of a long transcript. A list the Chief or the agent keeps is the chat's current one, not an
///   earlier turn's: it shows as it is.
/// - Between turns the chat's list shows while steps are left (`kept`: nothing spins, the hat is not
///   lit as working), so the person sees what is done and what is next without scrolling back.
export function hatPlanOf({
  working,
  live,
  earlier,
  list,
}: {
  working: boolean;
  live?: readonly AcpmuxPlanEntry[];
  earlier?: readonly AcpmuxPlanEntry[];
  list?: ChatTaskList;
}): { plan: readonly AcpmuxPlanEntry[]; earlier: boolean; kept: boolean } | undefined {
  if (working && live && live.length > 0) return { plan: live, earlier: false, kept: false };
  const kept = hasStepsLeft(list) ? list : undefined;
  if (working) {
    if (kept && kept.source !== "harness") return { plan: kept.items, earlier: false, kept: false };
    if (earlier && earlier.length > 0) return { plan: earlier, earlier: true, kept: false };
    if (kept) return { plan: kept.items, earlier: true, kept: false };
    return undefined;
  }
  return kept ? { plan: kept.items, earlier: false, kept: true } : undefined;
}
