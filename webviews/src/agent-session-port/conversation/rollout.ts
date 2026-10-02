// Codex rollout files (~/.codex/sessions/**/rollout-*.jsonl) -> protocol Turns.
//
// A rollout persists core events, not app-server v2 items: `event_msg` lines carry
// `item_completed` (snake_case core TurnItems: UserMessage, AgentMessage, Reasoning,
// CommandExecution, FileChange, McpToolCall, Extension{kind: "web.search" | "clock.sleep"}),
// and `task_started` / `task_complete` / `turn_aborted` bound each turn. The app-server
// performs the same mapping when it replays a thread (`thread/read` with includeTurns).
// Accepts whole rollout lines or bare payloads (the committed excerpts store payloads).
import type { CommandAction, FileUpdateChange, McpContent, ThreadItem, ToolSurface, Turn } from "./protocol";

type Json = Record<string, unknown>;
const str = (v: unknown): string => (typeof v === "string" ? v : "");
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const obj = (v: unknown): Json => (v && typeof v === "object" ? (v as Json) : {});

function durationMs(d: unknown): number | null {
  const o = obj(d);
  if (typeof o.secs !== "number") return null;
  return o.secs * 1000 + Math.round(Number(o.nanos ?? 0) / 1e6);
}

function commandAction(p: Json): CommandAction {
  const command = str(p.cmd);
  switch (p.type) {
    case "read":
      return { type: "read", command, name: str(p.name), path: str(p.path) };
    case "list_files":
      return { type: "listFiles", command, path: (p.path as string) ?? null };
    case "search":
      return {
        type: "search",
        command,
        query: (p.query as string) ?? null,
        path: (p.path as string) ?? null,
      };
    default:
      return { type: "unknown", command };
  }
}

/** `["/bin/zsh", "-lc", "cmd"]` -> "cmd". */
function shellCommand(command: unknown): string {
  const parts = arr(command).map(str);
  const i = parts.indexOf("-lc");
  return i >= 0 && parts[i + 1] !== undefined ? parts[i + 1] : parts.join(" ");
}

function fileChanges(changes: unknown): FileUpdateChange[] {
  return Object.entries(obj(changes)).map(([path, raw]) => {
    const c = obj(raw);
    if (c.type === "add") {
      const lines = str(c.content).replace(/\n$/, "").split("\n");
      return { path, kind: { type: "add" }, diff: lines.map((l) => `+${l}`).join("\n") };
    }
    if (c.type === "delete") {
      const lines = str(c.content).replace(/\n$/, "").split("\n");
      return { path, kind: { type: "delete" }, diff: lines.map((l) => `-${l}`).join("\n") };
    }
    return {
      path,
      kind: { type: "update", move_path: (c.move_path as string) ?? null },
      diff: str(c.unified_diff),
    };
  });
}

/** One core TurnItem -> a v2 ThreadItem (null for kinds the transcript ignores). */
export function threadItem(raw: Json): ThreadItem | null {
  const id = str(raw.id);
  switch (raw.type) {
    case "UserMessage":
      return {
        type: "userMessage",
        id,
        content: arr(raw.content).flatMap((c) => {
          const o = obj(c);
          return o.type === "text" ? [{ type: "text" as const, text: str(o.text) }] : [];
        }),
      };
    case "AgentMessage":
      return {
        type: "agentMessage",
        id,
        text: arr(raw.content)
          .map((c) => str(obj(c).text))
          .join(""),
        phase: raw.phase === "commentary" || raw.phase === "final_answer" ? raw.phase : null,
      };
    case "Reasoning":
      return {
        type: "reasoning",
        id,
        summary: arr(raw.summary_text).map(str),
        content: arr(raw.raw_content).map(str),
      };
    case "CommandExecution":
      return {
        type: "commandExecution",
        id,
        command: shellCommand(raw.command),
        cwd: str(raw.cwd).replace(/^file:\/\//, ""),
        status:
          raw.status === "failed" || raw.status === "declined" || raw.status === "inProgress"
            ? raw.status
            : "completed",
        commandActions: arr(raw.parsed_cmd).map((p) => commandAction(obj(p))),
        aggregatedOutput: (raw.aggregated_output as string) ?? null,
        exitCode: typeof raw.exit_code === "number" ? raw.exit_code : null,
        durationMs: durationMs(raw.duration),
      };
    case "FileChange":
      return {
        type: "fileChange",
        id,
        changes: fileChanges(raw.changes),
        status: raw.status === "failed" || raw.status === "declined" ? raw.status : "completed",
      };
    case "McpToolCall": {
      const result = raw.result ? obj(raw.result) : null;
      const meta = result ? obj(result._meta) : {};
      return {
        type: "mcpToolCall",
        id,
        server: str(raw.server),
        tool: str(raw.tool),
        status: raw.status === "failed" ? "failed" : raw.status === "inProgress" ? "inProgress" : "completed",
        arguments: raw.arguments ? obj(raw.arguments) : null,
        pluginId: (raw.pluginId as string) ?? null,
        result: result && {
          content: arr(result.content).flatMap((c): McpContent[] => {
            const o = obj(c);
            return o.type === "text" ? [{ type: "text", text: str(o.text) }] : [{ type: "image" }];
          }),
          _meta: meta["codex/toolSurface"]
            ? { "codex/toolSurface": meta["codex/toolSurface"] as ToolSurface }
            : undefined,
        },
        error: raw.error ? { message: str(obj(raw.error).message) || str(raw.error) } : null,
        durationMs: durationMs(raw.duration),
      };
    }
    case "Extension":
      if (raw.kind === "web.search") {
        const a = obj(raw.action);
        return {
          type: "webSearch",
          id,
          query: str(raw.query),
          action:
            a.type === "search"
              ? {
                  type: "search",
                  query: (a.query as string) ?? null,
                  queries: (a.queries as string[]) ?? null,
                }
              : { type: "other" },
        };
      }
      if (raw.kind === "clock.sleep") return { type: "sleep", id, durationMs: Number(raw.durationMs ?? 0) };
      return null;
    default:
      return null;
  }
}

/** Parses rollout JSONL text (full lines or bare `event_msg` payloads) into turns, in order. */
export function parseRollout(jsonl: string): Turn[] {
  const turns = new Map<string, Turn>();
  const turn = (id: string): Turn => {
    let t = turns.get(id);
    if (!t) {
      t = {
        id,
        items: [],
        status: "inProgress",
        startedAt: null,
        completedAt: null,
        durationMs: null,
      };
      turns.set(id, t);
    }
    return t;
  };
  for (const line of jsonl.split("\n")) {
    if (!line.trim()) continue;
    const parsed = JSON.parse(line) as Json;
    const p = parsed.type === "event_msg" ? obj(parsed.payload) : parsed;
    const turnId = str(p.turn_id);
    if (!turnId) continue;
    switch (p.type) {
      case "task_started":
        turn(turnId).startedAt = Number(p.started_at) || null;
        break;
      case "task_complete":
      case "turn_aborted": {
        const t = turn(turnId);
        t.status = p.type === "task_complete" ? "completed" : "interrupted";
        t.completedAt = Number(p.completed_at) || null;
        t.durationMs = typeof p.duration_ms === "number" ? p.duration_ms : null;
        break;
      }
      case "item_completed": {
        const item = threadItem(obj(p.item));
        if (!item) break;
        const t = turn(turnId);
        t.items.push(item);
        if (item.type === "agentMessage" && item.phase === "final_answer" && t.finalAnswerStartedAtMs == null)
          t.finalAnswerStartedAtMs = typeof p.started_at_ms === "number" ? p.started_at_ms : null;
        break;
      }
    }
  }
  return [...turns.values()];
}
