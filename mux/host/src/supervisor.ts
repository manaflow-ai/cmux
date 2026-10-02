import type { SessionStatus, SessionSummary } from "./acpmux-client.ts";
import type { WorkStatus } from "./conversation-types.ts";

/** Tag on every agent the mux started (`mux agents spawn`); its value is the mux's session name. */
export const PARENT_TAG = "mux.parent";
/** Prefix of host prompts about child agents; hooks log them as events, not user words. */
export const EVENT_PREFIX = "[mux-event]";

export interface PermissionOption {
  optionId: string;
  name?: string;
  kind?: string;
}

const EXCERPT = 600;

export function excerpt(text: string, limit = EXCERPT): string {
  const flat = text.trim();
  return flat.length <= limit ? flat : `${flat.slice(0, limit - 1)}…`;
}

export function childFinishedPrompt(child: SessionSummary, reply: string): string {
  return `${EVENT_PREFIX} child ${child.name} finished: ${excerpt(reply) || "(no reply text)"}\n(${child.harness}, ${child.cwd}; full reply: \`acpmux last ${child.name}\`.) Tell the user what matters, briefly, and take the next step yourself if there is one.`;
}

export function childPermissionPrompt(child: SessionSummary, request: Record<string, unknown>): string {
  const toolCall = (request.toolCall ?? {}) as { title?: string; rawInput?: unknown };
  const options = ((request.options ?? []) as PermissionOption[]).map((o) => `${o.optionId} (${o.name ?? o.kind ?? ""})`);
  const input = toolCall.rawInput === undefined ? "" : `\nInput: ${JSON.stringify(toolCall.rawInput).slice(0, 600)}`;
  return `${EVENT_PREFIX} child ${child.name} asks permission: ${toolCall.title ?? "a tool call"}${input}\nOptions: ${options.join(", ") || "(none)"}\nAnswer with \`mux agents allow ${child.name} OPTION_ID\` or \`mux agents deny ${child.name}\`. Ask the user first if it is destructive or outward-facing.`;
}

/** The work card status for an acpmux session status. */
export function workStatus(status: SessionStatus): WorkStatus {
  switch (status) {
    case "running":
      return "running";
    case "waiting":
      return "waiting";
    case "disconnected":
    case "closed":
      return "failed";
    default:
      return "done";
  }
}

/** A child turn ended: it left `running` for `ready` or `idle`. */
export function turnEnded(before: SessionStatus | undefined, after: SessionStatus): boolean {
  return before === "running" && (after === "ready" || after === "idle");
}
