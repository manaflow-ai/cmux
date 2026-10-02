// acpmux rows -> Codex-shaped turns (conversation/protocol.ts), the one view model the
// ported transcript renders.
//
// Ownership: acpmux owns sessions, the event log and the turn structure. Until it serves
// turn-structured rows itself (`acp.view.subscribe`, `_acpmux/view`, spec/acp-ui.md work
// plan step 2), the direct client folds the event stream into ordered rows
// (agent-session/acpmux/direct.ts) and this pure function regroups those rows into turns.
// It derives nothing the rows do not carry and keeps no state: when acpmux serves turns,
// this file is replaced by a field-for-field mapping and the renderers stay as they are.
import { structuredPatch } from "diff";
import type { AcpmuxActivity, AcpmuxFileDiff, AcpmuxRow, AcpmuxSnapshot } from "../data/acpmux";
import type {
  CommandAction,
  CommandExecutionItem,
  FileChangeItem,
  ThreadItem,
  Turn,
  TurnStatus,
} from "../conversation/protocol";

export type PortTurn = Turn & {
  /** The acpmux row that opened the turn (a user row), for actions such as View changes. */
  anchorRowId: string;
  /** The user's prompt is still sending (no echo from acpmux yet). */
  pending?: boolean;
};

const seconds = (ms: number) => Math.floor(ms / 1000);

/** Path relative to `cwd` when inside it. */
export function relativePath(path: string, cwd?: string): string {
  if (cwd && path.startsWith(cwd.endsWith("/") ? cwd : `${cwd}/`))
    return path.slice(cwd.length + (cwd.endsWith("/") ? 0 : 1));
  return path;
}

/** Hunks of `diff` (no file headers), as Codex's FileUpdateChange carries them. */
export function unifiedHunks(diff: AcpmuxFileDiff): string {
  const patch = structuredPatch("a", "b", diff.oldText ?? "", diff.newText, "", "", { context: 3 });
  return patch.hunks
    .map((hunk) => {
      const header = `@@ -${hunk.oldStart},${hunk.oldLines} +${hunk.newStart},${hunk.newLines} @@`;
      return [header, ...hunk.lines.filter((line) => !line.startsWith("\\"))].join("\n");
    })
    .join("\n");
}

/** The command line of an execute tool call: its raw input when it has one, else the title. */
function commandLine(tool: NonNullable<AcpmuxActivity["tool"]>): string {
  try {
    const input = tool.inputSummary ? JSON.parse(tool.inputSummary) : undefined;
    const command = input?.command ?? input?.cmd;
    if (Array.isArray(command)) {
      // ["bash", "-lc", "..."] shows the script, as Codex does.
      const script =
        command.length >= 3 && String(command[0]).endsWith("sh") ? command[command.length - 1] : command.join(" ");
      return String(script);
    }
    if (typeof command === "string") return command;
  } catch {
    /* a summary that is not JSON is only a title */
  }
  return tool.title;
}

const TITLE_VERB = /^(read|search|searched|list|listed|grep|find|run|ran|edit|edited|fetch)\s+/i;

/** Codex's parsed command actions, from the ACP tool kind and its locations. */
function actionsFor(tool: NonNullable<AcpmuxActivity["tool"]>, cwd?: string): CommandAction[] {
  const command = commandLine(tool);
  const path = tool.locations?.[0]?.path;
  switch (tool.kind) {
    case "read": {
      const target = path ?? tool.title.replace(TITLE_VERB, "");
      const shown = relativePath(target, cwd);
      return [{ type: "read", command, name: shown.slice(shown.lastIndexOf("/") + 1), path: target }];
    }
    case "search": {
      const rest = tool.title.replace(TITLE_VERB, "");
      const match = /^(.*?)\s+in\s+(\S+)$/.exec(rest);
      return [
        {
          type: "search",
          command,
          query: match ? match[1]! : rest || null,
          path: match ? match[2]! : path ? relativePath(path, cwd) : null,
        },
      ];
    }
    default:
      return [{ type: "unknown", command }];
  }
}

const execStatus = (status: string): CommandExecutionItem["status"] =>
  status === "completed"
    ? "completed"
    : status === "failed"
      ? "failed"
      : status === "declined" || status === "cancelled"
        ? "declined"
        : "inProgress";

/** One ACP tool call as the Codex item the transcript knows how to draw. */
export function toolItem(activity: AcpmuxActivity, cwd?: string): ThreadItem | undefined {
  const tool = activity.tool;
  if (!tool) return undefined;
  const status = execStatus(tool.status);
  if (tool.diffs?.length) {
    const item: FileChangeItem = {
      type: "fileChange",
      id: tool.id,
      status,
      changes: tool.diffs.map((diff) => ({
        path: relativePath(diff.path, cwd),
        kind: diff.oldText === undefined ? { type: "add" } : { type: "update", move_path: null },
        diff:
          diff.oldText === undefined
            ? diff.newText
                .replace(/\n$/, "")
                .split("\n")
                .map((line) => `+${line}`)
                .join("\n")
            : unifiedHunks(diff),
      })),
    };
    return item;
  }
  switch (tool.kind) {
    case "read":
    case "search":
    case "execute":
      return {
        type: "commandExecution",
        id: tool.id,
        command: commandLine(tool),
        cwd: cwd ?? "",
        status,
        commandActions: actionsFor(tool, cwd),
        aggregatedOutput: tool.output ?? null,
        exitCode: status === "failed" ? 1 : status === "completed" ? 0 : null,
        durationMs: null,
      };
    case "fetch":
      return {
        type: "webSearch",
        id: tool.id,
        query: tool.title.replace(/^(search(ed)? the web( for)?|fetch)\s*/i, ""),
        action: null,
      };
    default:
      return {
        type: "mcpToolCall",
        id: tool.id,
        server: "acp",
        tool: tool.title,
        status: status === "declined" ? "failed" : status,
        arguments: { title: tool.title },
        pluginId: null,
        result: tool.output ? { content: [{ type: "text", text: tool.output }] } : null,
        error: null,
        durationMs: null,
      };
  }
}

/**
 * Turns of the session, oldest first. A turn starts at a user row and runs to the next one;
 * rows before the first user row (a resumed session's older context) form a turn of their own.
 */
export function turnsFromRows(rows: readonly AcpmuxRow[], cwd?: string): PortTurn[] {
  const turns: PortTurn[] = [];
  const messageAt = new Map<string, number>();
  let current: PortTurn | undefined;
  const open = (id: string, at: number, pending?: boolean): PortTurn => {
    const turn: PortTurn = {
      id,
      anchorRowId: id,
      items: [],
      status: "inProgress",
      startedAt: seconds(at),
      completedAt: null,
      durationMs: null,
      pending,
    };
    turns.push(turn);
    return turn;
  };
  for (const row of rows) {
    if (row.kind === "user") {
      current = open(row.id, row.at, row.pending || row.failed);
      current.items.push({ type: "userMessage", id: row.id, content: [{ type: "text", text: row.text ?? "" }] });
      if (row.failed) {
        current.status = "failed";
        current.error = { message: "Not sent" };
      }
      continue;
    }
    current ??= open(row.id, row.at);
    switch (row.kind) {
      case "assistant":
        current.items.push({ type: "agentMessage", id: row.id, text: row.text ?? "", phase: "commentary" });
        messageAt.set(row.id, row.at);
        break;
      case "activity":
        for (const activity of row.items ?? []) {
          if (activity.kind === "thought") {
            const last = current.items[current.items.length - 1];
            if (last?.type === "reasoning") last.summary[0] = `${last.summary[0] ?? ""}${activity.text}`;
            else
              current.items.push({
                type: "reasoning",
                id: `${row.id}:thought:${current.items.length}`,
                summary: [activity.text],
                content: [],
              });
            continue;
          }
          const item = toolItem(activity, cwd);
          if (item) current.items.push(item);
        }
        break;
      case "plan":
        current.items.push({ type: "plan", id: row.id, text: row.text ?? "" });
        break;
      case "turnSummary": {
        const status = row.status as TurnStatus | "cancelled" | "error" | undefined;
        current.status =
          status === "cancelled" ? "interrupted" : status === "error" || status === "failed" ? "failed" : "completed";
        if (row.error) current.error = { message: row.error };
        current.completedAt = seconds(row.at);
        current.durationMs = row.durationMs ?? (current.startedAt != null ? row.at - current.startedAt * 1000 : null);
        break;
      }
      default:
        break;
    }
  }
  // The final answer is the last message of a turn that ended with it; earlier text is
  // commentary inside the activity, as Codex marks with `phase`.
  for (const turn of turns) {
    const lastIndex = turn.items.length - 1;
    const last = turn.items[lastIndex];
    if (
      last?.type === "agentMessage" &&
      (turn.status !== "inProgress" ||
        turn.items.every((item) => item.type === "userMessage" || item.type === "agentMessage"))
    ) {
      last.phase = "final_answer";
      // When the final answer started: the transcript's timestamp lines read it.
      turn.finalAnswerStartedAtMs = messageAt.get(last.id) ?? null;
    }
  }
  return turns;
}

/** Working seconds of the running turn, for "Working for 29s". */
export function elapsedMs(turn: Turn | undefined, now: number): number | undefined {
  if (!turn || turn.status !== "inProgress" || turn.startedAt == null) return undefined;
  return Math.max(0, now - turn.startedAt * 1000);
}

/** Whether the selected session has nothing in it yet: the pane shows the new chat hero. */
export const isNewChat = (snapshot: AcpmuxSnapshot) =>
  !snapshot.rows.some((row) => row.kind === "user" || row.kind === "assistant");
