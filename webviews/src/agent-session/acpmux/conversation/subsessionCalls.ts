// l10n-allow-file: it matches the cmux-subsessions server's own text (subsession_mcp.rs) and shows none.
// Calls to the cmux-subsessions MCP server's tools (acpmux subsession_mcp.rs) that the transcript
// draws as sub-session cards (SubsessionCallCard.tsx) instead of the generic MCP row: a
// `start_session` as the sub-session it started, a `send_message` as the message and how it was
// delivered, a `wait_for_sessions` or `list_sessions` as each sub-session's state and reply. The
// cmux server also serves its tools as its own (`mcp__cmux__subsessions_start_session`,
// cli/mcp/upstream.rs), which read the same. The server answers with a line of
// text for the agent and the same facts as `structuredContent`; a harness hands the pane the text
// (Claude Code) or the whole result (Codex), so both are read. A failed call, a call to its other
// tools, and a result in neither form keep the generic MCP row (McpCallRows.tsx), which shows it.
import type { AcpmuxActivity } from "../model";
import { type SessionWaiting, sessionWaiting } from "../sessionList";
import { mcpCall, type McpCall } from "./mcpCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// When the receiver reads a message (subsession_mcp.rs `sent_text`): in its running turn at its
/// next tool step, queued behind that turn at `position`, or at once in a turn of its own.
export type SubsessionDelivery =
  | { kind: "next_step" }
  | { kind: "queued"; position?: number }
  | { kind: "started" }
  /// Its parent already runs as many sub-sessions as `maxRunning` allows: it starts a turn with
  /// the message once a run slot frees.
  | { kind: "slot" };

/// One sub-session `wait_for_sessions` read: its state then, and its last reply once it finished.
export type SubsessionReply = {
  sessionId: string;
  /// Its short name, else its full name, as the result gives them.
  name?: string;
  state: "working" | "input" | "failed" | "done";
  reply?: string;
  /// What it waited on the person for, when it did (the row's `waitingOn`).
  waiting?: SessionWaiting;
  /// It waits for a run slot (the row's `waitsForSlot`): it has not started.
  slot?: true;
  harness?: string;
};

export type SubsessionCall =
  | {
      tool: "start";
      running: boolean;
      sessionId?: string;
      name?: string;
      /// What it was asked (`prompt`), and the harness and model it runs.
      prompt?: string;
      harness?: string;
      model?: string;
    }
  | { tool: "send"; running: boolean; sessionId: string; text: string; delivery?: SubsessionDelivery }
  /// A wait's or a list's sub-sessions (a list never times out).
  | { tool: "wait" | "list"; running: boolean; timedOut: boolean; sessions: SubsessionReply[] };

/// A row's doing line while its session waits on a question, with the question's first prompt.
const QUESTION_DOING = /^Waiting for the user to answer, in the app: (.+)$/s;

/// The server's name as a harness names it (`cmux-subsessions`, or with an underscore).
const SERVER = /^cmux[-_]subsessions$/;

/// The server's tool `call` runs: its own name, or the cmux server's `subsessions_<tool>` for it.
function subsessionTool(call: McpCall): string | undefined {
  if (SERVER.test(call.server)) return call.tool;
  if (call.server === "cmux" && call.tool.startsWith("subsessions_")) return call.tool.slice("subsessions_".length);
  return undefined;
}

/// The sub-session card a call draws as, or nil for every other call. `call` is its MCP call, when
/// the caller has it read already.
export function subsessionCall(tool: Tool, call: McpCall | undefined = mcpCall(tool)): SubsessionCall | undefined {
  const name = call && subsessionTool(call);
  if (!name || tool.status === "failed") return undefined;
  const args = isRecord(call!.args) ? call!.args : {};
  const running = tool.status === "pending" || tool.status === "in_progress";
  const result = running ? undefined : resultOf(tool.output);
  switch (name) {
    case "start_session": {
      const askedName = text(args.name);
      const asked = {
        ...(typeof args.prompt === "string" && args.prompt.trim() && { prompt: args.prompt }),
        ...(text(args.model) && { model: text(args.model) }),
      };
      const harness = text(result?.value?.harness) ?? text(args.harness);
      if (running)
        return { tool: "start", running, ...(askedName && { name: askedName }), ...asked, ...(harness && { harness }) };
      // "Started sub-session tests (sessionId 0199…, depth 1). …", or "Created …" when it waits for a run slot.
      const said = /^(?:Started|Created) sub-session (.*?) \(sessionId ([^,\s)]+)/.exec(result?.text ?? "");
      const sessionId = text(result?.value?.sessionId) ?? said?.[2];
      if (!sessionId) return undefined;
      const name = text(result?.value?.shortName) ?? text(result?.value?.name) ?? text(said?.[1]) ?? askedName;
      return { tool: "start", running, sessionId, ...(name && { name }), ...asked, ...(harness && { harness }) };
    }
    case "send_message": {
      const sessionId = text(args.sessionId);
      if (!sessionId) return undefined;
      const message = typeof args.text === "string" ? args.text : "";
      const delivery = result && deliveryOf(result);
      // An ended call that does not say how it was delivered was refused: the generic row shows why.
      if (!running && !delivery) return undefined;
      return { tool: "send", running, sessionId, text: message, ...(delivery && { delivery }) };
    }
    case "list_sessions":
    case "wait_for_sessions": {
      const kind = name === "wait_for_sessions" ? "wait" : "list";
      const none = { tool: kind, running, timedOut: false, sessions: [] } as SubsessionCall;
      if (running) return none;
      if (result?.text.trim() === "None of your sub-sessions is running.") return none;
      const rows = result?.value?.sessions;
      if (!Array.isArray(rows)) return undefined;
      const sessions = rows.filter(isRecord).flatMap((row): SubsessionReply[] => {
        const id = text(row.sessionId);
        if (!id) return [];
        const name = text(row.shortName) ?? text(row.name);
        const reply = text(typeof row.lastReply === "string" ? row.lastReply.trim() : undefined);
        const state = rowState(row);
        if (!state) return [];
        // A question's first prompt is in the row's doing line (subsession_send.rs `doing`).
        const asked = typeof row.doing === "string" ? QUESTION_DOING.exec(row.doing)?.[1] : undefined;
        const waiting =
          state === "input" ? sessionWaiting({ waitingOn: row.waitingOn, waitingPrompt: asked }) : undefined;
        const harness = text(row.harness);
        const more = {
          ...(waiting && { waiting }),
          ...(harness && { harness }),
          ...(row.waitsForSlot === true && { slot: true as const }),
        };
        return [{ sessionId: id, ...(name && { name }), state, ...(reply && { reply }), ...more }];
      });
      // A row it cannot read (no id, no state) is not left out: the generic row shows what came back.
      if (sessions.length !== rows.length) return undefined;
      return { tool: kind, running, timedOut: result!.value!.timedOut === true, sessions };
    }
    default:
      return undefined;
  }
}

/// A family row's state (`subsession_row`): its lane, `working`, `input`, `failed`, `lost` or `idle`,
/// else (a session with no lane yet) its status dot or its status, as the session list reads one
/// (subsessionState); nil for a row that says none of them, which the card does not guess at.
function rowState(row: Record<string, unknown>): SubsessionReply["state"] | undefined {
  switch (row.state ?? row.indicator) {
    case "working":
      return "working";
    case "input":
      return "input";
    case "failed":
    case "lost":
      return "failed";
    case "idle":
    case "done":
      return "done";
  }
  if (row.status === "running") return "working";
  if (row.status === "waiting") return "input";
  if (row.status === "idle" || row.status === "done") return "done";
  return undefined;
}

function deliveryOf(result: { value?: Record<string, unknown>; text: string }): SubsessionDelivery | undefined {
  const value = result.value;
  const position = typeof value?.position === "number" ? value.position : undefined;
  switch (value?.delivery) {
    case "next_step":
      return { kind: "next_step" };
    case "queued":
      return { kind: "queued", ...(position !== undefined && { position }) };
    case "started":
      return { kind: "started" };
    case "waiting_for_slot":
      return { kind: "slot" };
  }
  // The text alone (subsession_mcp.rs `sent_text`).
  const said = result.text.trim();
  if (said.startsWith("Delivered into its running turn")) return { kind: "next_step" };
  const queued = /^Queued behind its running turn \(position (\d+)/.exec(said);
  if (queued) return { kind: "queued", position: Number(queued[1]) };
  if (said.startsWith("Sent: it started a turn")) return { kind: "started" };
  if (said.startsWith("Queued: it starts a turn with it once a run slot frees")) return { kind: "slot" };
  return undefined;
}

/// A call's result: its structured facts when the pane has them, and its text for the agent.
/// The output is the text (a sentence, or JSON, `wait_for_sessions`' after a line of its own), or
/// the whole MCP result (`{content, structuredContent}`, perhaps under `result`).
function resultOf(output: string | undefined): { value?: Record<string, unknown>; text: string } | undefined {
  if (!output) return undefined;
  const whole = parseJSON(output);
  if (isRecord(whole)) {
    const result = isRecord(whole.result) ? whole.result : whole;
    const content = Array.isArray(result.content) ? result.content : undefined;
    const said = content
      ?.filter((block) => isRecord(block) && block.type === "text")
      .map((block) => String((block as { text?: unknown }).text ?? ""))
      .join("\n");
    if (isRecord(result.structuredContent)) return { value: result.structuredContent, text: said ?? "" };
    if (said !== undefined) return resultOf(said) ?? { text: said };
    return { value: result, text: output };
  }
  // "Still running after 45 s; …\n{…}".
  const brace = output.indexOf("\n{");
  const after = brace >= 0 ? parseJSON(output.slice(brace + 1)) : undefined;
  return isRecord(after) ? { value: after, text: output } : { text: output };
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
