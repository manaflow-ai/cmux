import type { SessionStatus, SessionSummary } from "./acp.ts";
import { utf16Prefix } from "./acp.ts";
import { canonicalJson } from "./text.ts";
import { AGENT_MUX, type Message, messageText, type Part, type ParticipantId, type Summary, type WorkStatus } from "./conversation.ts";

// Pure rules of the brain host: the wake rule (plans/cmux-next/home.md
// section 5), the supervisor's prompt texts and status mapping, reply keys,
// and the host's constants. The Rust port (cmux-chief rules.rs) has the same
// bytes; the shared corpus checks it.

/** The Chief's acpmux session name. */
export const MUX_SESSION_NAME = "mux";
/** The default conversation's create key. */
export const DEFAULT_CONVERSATION_KEY = "mux-home-default";
/** Tag on every agent the mux started (`mux agents spawn`); its value is the mux's session name. */
export const PARENT_TAG = "mux.parent";
/** Prefix of host prompts about child agents; hooks log them as events, not user words. */
export const EVENT_PREFIX = "[mux-event]";
/** The owner's minimum gap between agent messages (2 s) plus a margin. */
export const AGENT_GAP_RETRY_MS = 2_200;
/** Extra delay before the one-shot outbox timer fires after the gap. */
export const AGENT_GAP_TIMER_SLACK_MS = 50;
/** Messages per catch-up page (the owner's maximum). */
export const PAGE = 500;

const EXCERPT = 600;

export interface PermissionOption {
  optionId: string;
  name?: string;
  kind?: string;
}

/**
 * A human message wakes the mux when the mux participates and either the
 * conversation has exactly one human and one agent (every human message), or
 * the message mentions the mux, replies to one of the mux's messages, or the
 * conversation is a DM with the mux.
 */
export function wakes(
  summary: Summary,
  message: Message,
  isMuxMessage: (messageId: string) => boolean,
  mux: ParticipantId = AGENT_MUX,
): boolean {
  const author = summary.participants.find((p) => p.id === message.author);
  if (!author || author.kind !== "human" || message.author === mux) return false;
  if (!summary.participants.some((p) => p.id === mux)) return false;
  if (message.retracted_at) return false;
  const humans = summary.participants.filter((p) => p.kind === "human").length;
  const agents = summary.participants.filter((p) => p.kind === "agent").length;
  if (humans === 1 && agents === 1) return true;
  if (summary.id.startsWith("conv_dm_") && summary.participants.length === 2) return true;
  const mentioned = message.parts.some(
    (part) => part.type === "text" && (part.runs ?? []).some((run) => run.mention === mux),
  );
  if (mentioned) return true;
  return message.reply_to !== undefined && isMuxMessage(message.reply_to.message_id);
}

/** The prompt for a human message that wakes the mux. */
export function inboxPrompt(summary: Summary, message: Message): string {
  const author = summary.participants.find((p) => p.id === message.author);
  return `[conversation ${summary.id} from ${author?.display_name ?? message.author}] ${messageText(message)}`;
}

/**
 * The owner-side idempotency key (and client_msg_id) of a mux turn's reply:
 * `turn:<session>:<turn seq>`, or `turn:<session>:<epoch>:<turn seq>` after a
 * cursor_reset (a re-imported log reuses seqs).
 */
export function turnKey(sessionId: string, turnSeq: number, epoch?: number): string {
  return epoch === undefined ? `turn:${sessionId}:${turnSeq}` : `turn:${sessionId}:${epoch}:${turnSeq}`;
}

/** Trimmed text cut to `limit` UTF-16 units with an ellipsis (a surrogate pair is never split). */
export function excerpt(text: string, limit = EXCERPT): string {
  const flat = text.trim();
  return flat.length <= limit ? flat : `${utf16Prefix(flat, limit - 1)}…`;
}

export function childFinishedPrompt(child: SessionSummary, reply: string): string {
  return `${EVENT_PREFIX} child ${child.name} finished: ${excerpt(reply) || "(no reply text)"}\n(${child.harness}, ${child.cwd}; full reply: \`acpmux last ${child.name}\`.) Tell the user what matters, briefly, and take the next step yourself if there is one.`;
}

/**
 * The prompt for a child's permission request. Only string fields count
 * (a missing or non-string optionId prints as ""; name, else kind, else "");
 * rawInput is canonical JSON (sorted keys), cut to 600 UTF-16 units.
 */
export function childPermissionPrompt(child: SessionSummary, request: Record<string, unknown>): string {
  const str = (value: unknown) => (typeof value === "string" ? value : undefined);
  const field = (value: unknown, key: string) =>
    value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>)[key] : undefined;
  const toolCall = request.toolCall;
  const rawInput = field(toolCall, "rawInput");
  const options = (Array.isArray(request.options) ? request.options : []).map(
    (o: unknown) => `${str(field(o, "optionId")) ?? ""} (${str(field(o, "name")) ?? str(field(o, "kind")) ?? ""})`,
  );
  const input = rawInput === undefined ? "" : `\nInput: ${utf16Prefix(canonicalJson(rawInput), 600)}`;
  return `${EVENT_PREFIX} child ${child.name} asks permission: ${str(field(toolCall, "title")) ?? "a tool call"}${input}\nOptions: ${options.join(", ") || "(none)"}\nAnswer with \`mux agents allow ${child.name} OPTION_ID\` or \`mux agents deny ${child.name}\`. Ask the user first if it is destructive or outward-facing.`;
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

/** A child turn ended: it left `running` or `waiting` (a permission, answered or denied) for `ready` or `idle`. */
export function turnEnded(before: SessionStatus | undefined, after: SessionStatus): boolean {
  return (before === "running" || before === "waiting") && (after === "ready" || after === "idle");
}

/** The work part of a child's card. */
export function workPart(session: string, status: WorkStatus, preview?: string | null): Part {
  return {
    type: "work",
    session,
    status,
    ...(preview ? { preview: excerpt(preview, 200) } : {}),
  };
}
