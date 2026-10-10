// Builds PROTOCOL TranscriptItems from acpmux event records (history pages and
// live `_acpmux/event` notifications go through the same path). Item ids are
// derived from record content (promptId, toolCallId, permissionId, seq), so a
// rebuilt transcript has the same ids and the phone's upsert-by-id stays
// consistent across reconnects.

import type { ToolKindP, TranscriptItem } from "../protocol.ts";
import { applyTerminalMeta, applyToolContent, mapToolKind, mapToolStatus, type TerminalTail } from "../providers/agents.ts";

type Item = TranscriptItem;
type ToolItem = Extract<Item, { kind: "tool" }>;
type TextItem = Extract<Item, { kind: "assistant" | "thought" }>;

/** One acpmux record (`Event` in `cmux acp daemon schema`). */
export interface AcpmuxEvent {
  sessionId: string;
  seq: number;
  at: number;
  dir: "in" | "out" | "mux" | "peer" | string;
  kind: string;
  msg: any;
}

export class TranscriptBuilder {
  readonly items: Item[] = [];
  private readonly index = new Map<string, number>();
  private readonly terminalTails = new Map<string, TerminalTail>();
  private openText: { kind: "assistant" | "thought"; id: string; messageId?: string; startedAt: number } | null = null;
  private turnStartedAt = new Map<string, number>();
  private lastSeq = -1;
  commands: { name: string; description: string }[] = [];

  /** Applies one record; returns the items it created or changed. */
  apply(e: AcpmuxEvent): Item[] {
    if (typeof e.seq === "number") {
      if (e.seq <= this.lastSeq) return []; // duplicate from a page/live overlap
      this.lastSeq = e.seq;
    }
    const changed: Item[] = [];
    const upsert = (item: Item) => {
      const i = this.index.get(item.id);
      if (i === undefined) {
        this.index.set(item.id, this.items.length);
        this.items.push(item);
      } else this.items[i] = item;
      if (!changed.includes(item)) changed.push(item);
    };
    const get = <T extends Item>(id: string): T | undefined => {
      const i = this.index.get(id);
      return i === undefined ? undefined : (this.items[i] as T);
    };
    const closeText = (at: number) => {
      const open = this.openText;
      if (!open) return;
      this.openText = null;
      const item = get<TextItem>(open.id);
      if (item && item.streaming) {
        const done: TextItem = { ...item, streaming: false };
        if (done.kind === "thought") done.durationMs = Math.max(0, at - open.startedAt);
        upsert(done);
      }
    };

    if (e.dir === "in" || e.dir === "peer") {
      const update = e.msg?.params?.update ?? e.msg?.update;
      if (update && typeof update.sessionUpdate === "string") this.applyUpdate(e, update, upsert, get, closeText);
      return changed;
    }
    if (e.dir !== "mux") return changed;
    const m = e.msg ?? {};
    switch (e.kind) {
      case "user_message":
      case "queued": {
        closeText(e.at);
        const id = `u-${m.promptId ?? e.seq}`;
        if (!get(id) || e.kind === "user_message") upsert({ id, kind: "user", text: String(m.text ?? ""), attachments: [] });
        break;
      }
      case "turn_started":
        if (m.turnId) this.turnStartedAt.set(m.turnId, e.at);
        break;
      case "turn_result":
      case "turn_end": {
        closeText(e.at);
        if (m.errorText || m.error) upsert({ id: `n-${e.seq}`, kind: "notice", level: "error", text: String(m.errorText ?? m.error) });
        const started = m.turnId ? this.turnStartedAt.get(m.turnId) : undefined;
        const stopReason = m.status && m.status !== "completed" ? String(m.status === "failed" ? "error" : m.status) : String(m.stopReason ?? "end_turn");
        upsert({ id: `end-${m.turnId ?? e.seq}`, kind: "turnEnd", stopReason, durationMs: started !== undefined ? Math.max(0, e.at - started) : 0 });
        break;
      }
      case "turn_error":
        closeText(e.at);
        upsert({ id: `n-${e.seq}`, kind: "notice", level: "error", text: String(m.error ?? "turn failed") });
        break;
      case "permission_request": {
        closeText(e.at);
        const req = m.request ?? {};
        const options = Array.isArray(req.options) ? req.options : [];
        upsert({
          id: `perm-${m.permissionId}`,
          kind: "permission",
          toolCallId: String(req.toolCall?.toolCallId ?? ""),
          title: String(req.toolCall?.title ?? "Permission requested"),
          options: options.map((o: any) => ({ id: String(o.optionId), name: String(o.name ?? o.optionId), kind: o.kind })),
        });
        break;
      }
      case "permission_decision":
      case "permission_auto": {
        const id = `perm-${m.permissionId}`;
        const decided = m.outcome?.optionId ?? m.optionId ?? (m.outcome?.outcome === "cancelled" ? "cancelled" : m.outcome?.outcome) ?? "cancelled";
        const existing = get<Extract<Item, { kind: "permission" }>>(id);
        if (existing) upsert({ ...existing, resolved: String(decided) });
        else if (e.kind === "permission_auto") {
          upsert({ id, kind: "permission", toolCallId: String(m.request?.toolCall?.toolCallId ?? ""), title: String(m.request?.toolCall?.title ?? "Permission"), options: [], resolved: String(decided) });
        }
        break;
      }
      case "message_superseded": {
        const old = get<TextItem>(`a-${m.oldMessageId}`);
        if (old) upsert({ ...old, text: "", streaming: false });
        if (this.openText?.messageId === m.oldMessageId) this.openText = null;
        break;
      }
      case "exited":
        closeText(e.at);
        upsert({ id: `n-${e.seq}`, kind: "notice", level: "error", text: `The agent exited unexpectedly${m.code !== undefined ? ` (code ${m.code})` : ""}.` });
        break;
      case "stopped":
        closeText(e.at);
        upsert({ id: `n-${e.seq}`, kind: "notice", level: "info", text: "The agent stopped." });
        break;
      case "failover":
        upsert({ id: `n-${e.seq}`, kind: "notice", level: "warning", text: `Switched harness${m.to ? ` to ${m.to}` : ""}.` });
        break;
      default:
        break;
    }
    return changed;
  }

  private applyUpdate(
    e: AcpmuxEvent,
    u: any,
    upsert: (i: Item) => void,
    get: <T extends Item>(id: string) => T | undefined,
    closeText: (at: number) => void,
  ): void {
    switch (u.sessionUpdate) {
      case "agent_message_chunk":
      case "agent_thought_chunk": {
        const kind = u.sessionUpdate === "agent_message_chunk" ? "assistant" : "thought";
        const text = u.content?.type === "text" ? String(u.content.text ?? "") : u.content?.type === "image" ? "\n[image]\n" : "";
        if (!text) return;
        const messageId: string | undefined = kind === "assistant" && typeof u.messageId === "string" ? u.messageId : undefined;
        const open = this.openText;
        if (open && open.kind === kind && (!messageId || !open.messageId || open.messageId === messageId)) {
          const item = get<TextItem>(open.id);
          if (item) {
            upsert({ ...item, text: item.text + text });
            return;
          }
        }
        closeText(e.at);
        const id = kind === "assistant" ? `a-${messageId ?? e.seq}` : `t-${e.seq}`;
        const prev = get<TextItem>(id);
        this.openText = { kind, id, messageId, startedAt: e.at };
        upsert(prev ? { ...prev, text: prev.text + text, streaming: true } : kind === "assistant" ? { id, kind, text, streaming: true } : { id, kind, text, streaming: true });
        return;
      }
      case "tool_call":
      case "tool_call_update": {
        const id = `tool-${u.toolCallId}`;
        const existing = get<ToolItem>(id);
        if (!existing) closeText(e.at);
        const item: ToolItem = existing
          ? { ...existing }
          : { id, kind: "tool", toolKind: "other" as ToolKindP, title: "Tool", status: "pending", locations: [] };
        if (u.kind) item.toolKind = mapToolKind(u.kind);
        if (u.title || u.name) item.title = u.title || u.name;
        if (u.status) item.status = mapToolStatus(u.status);
        if (u.locations) item.locations = u.locations.map((l: any) => ({ path: l.path, ...(l.line != null ? { line: l.line } : {}) }));
        applyToolContent(item, u.content ?? undefined, u.rawInput, u.rawOutput);
        applyTerminalMeta(item, this.terminalTails, u._meta);
        upsert(item);
        return;
      }
      case "plan": {
        closeText(e.at);
        const entries = Array.isArray(u.entries) ? u.entries : [];
        upsert({ id: `plan-${e.sessionId}`, kind: "plan", entries: entries.map((x: any) => ({ content: String(x.content), status: x.status, priority: String(x.priority ?? "medium") })) });
        return;
      }
      case "available_commands_update":
        this.commands = (u.availableCommands ?? []).map((c: any) => ({ name: String(c.name), description: String(c.description ?? "") }));
        return;
      default:
        return;
    }
  }
}
