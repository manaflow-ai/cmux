import type { AcpmuxHostConfig, EventRecord } from "./direct";

// Mock transport: the host answers `ready` with `{transport: "mock"}` when no
// acpmux daemon is wanted (demos, screenshots, tests). The page then runs the
// real acpmux client against this in-page daemon, which speaks the daemon's
// JSON-RPC and streams a scripted turn as ACP events, so every frame of a mock
// turn goes through the same reducer and renderers as a real agent's.

const sessionId = "mock-session";
const harnesses = [{ id: "claude", name: "Claude", models: [{ id: "claude-sonnet", name: "Claude Sonnet" }] }, { id: "codex", name: "Codex", models: [{ id: "gpt-6-astra", name: "GPT-6-Astra" }] }];
const session = { sessionId, title: "Mock session", harness: "claude", model: "claude-sonnet", status: "idle" };

/// The host config the page connects with in mock mode.
export const mockHost: AcpmuxHostConfig = { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://mock.invalid/acp", token: "mock", sessionId };

export function mockReply(prompt: string): string {
  return `Mock reply to **${prompt.replace(/[*_`]/g, "")}**. No acpmux daemon is attached; this pane is running in mock mode.`;
}

type Update = Record<string, unknown>;
/// One scripted step: an ACP `session/update`, or a daemon (mux) event.
type Step = { update: Update } | { mux: string; msg?: Record<string, unknown> };

const text = (value: string): Update => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: value } });
const tool = (toolCallId: string, kind: string, title: string, status: string, extra: Update = {}): Update => ({ sessionUpdate: "tool_call", toolCallId, kind, title, status, ...extra });
const done = (toolCallId: string, extra: Update = {}): Update => ({ sessionUpdate: "tool_call_update", toolCallId, status: "completed", ...extra });

/// A turn shaped like a real agent's: text, a tool call, more text, file edits, a closing answer.
export function mockTurn(prompt: string, turn: number): Step[] {
  const greeting = "/mock/project/src/greeting.ts";
  const notes = "/mock/project/NOTES.md";
  return [
    { update: text("I'll look at the greeting helper") },
    { update: text(" first.") },
    { update: tool(`read-${turn}`, "read", "Read src/greeting.ts", "in_progress", { locations: [{ path: greeting }] }) },
    { update: done(`read-${turn}`, { content: [{ type: "content", content: { type: "text", text: 'export function greet(name: string) {\n  return "Hello " + name;\n}' } }] }) },
    { update: text("It concatenates without punctuation, so I'll add an optional argument and a notes file.") },
    { update: tool(`edit-${turn}`, "edit", "Edit src/greeting.ts", "in_progress", { locations: [{ path: greeting, line: 1 }], content: [{ type: "diff", path: greeting, oldText: 'export function greet(name: string) {\n  return "Hello " + name;\n}\n', newText: 'export function greet(name: string, punctuation = "!") {\n  return `Hello, ${name}${punctuation}`;\n}\n' }] }) },
    { update: done(`edit-${turn}`) },
    { update: tool(`write-${turn}`, "edit", "Write NOTES.md", "completed", { locations: [{ path: notes }], content: [{ type: "diff", path: notes, newText: `# Notes\n\nMock turn ${turn}.\n` }] }) },
    { update: text(`${mockReply(prompt)}\n\n- \`greet(name)\` now ends with "!"\n- \`greet(name, "?")\` picks the punctuation:\n  - \`greet("Ada", "?")\` returns \`Hello, Ada?\`\n  - the default keeps old callers working`) },
  ];
}

/// An in-page acpmux daemon behind the WebSocket interface the client uses.
export class MockAcpmuxSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  private events: EventRecord[] = [];
  private seq = 0;
  private turns = 0;
  private running?: { cancelled: boolean };

  /// `delay` paces the scripted turn; tests pass one that resolves at once.
  constructor(private readonly delay: (ms: number) => Promise<void> = (ms) => new Promise((resolve) => window.setTimeout(resolve, ms))) {
    this.record({ update: text("Mock agent session. Type a prompt to see the pane render a turn.") });
    queueMicrotask(() => { this.readyState = 1; this.onopen?.(); });
  }

  send(raw: string): void {
    const request = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, any> };
    if (request.method === "session/cancel") { if (this.running) this.running.cancelled = true; return; }
    if (request.id === undefined) return;
    void this.answer(request.method, request.params ?? {}).then(
      (result) => this.deliver({ jsonrpc: "2.0", id: request.id, result }),
      (error: Error) => this.deliver({ jsonrpc: "2.0", id: request.id, error: { message: error.message } }),
    );
  }

  close(): void { this.readyState = 3; }

  private async answer(method: string, params: Record<string, any>): Promise<unknown> {
    switch (method) {
      case "_acpmux/watch": return { sessions: [session] };
      case "_acpmux/harnesses": return { harnesses };
      case "_acpmux/attach": return { session, events: this.events };
      case "_acpmux/events": return { events: this.events.filter((event) => event.seq > Number(params.afterSeq ?? 0)) };
      case "session/new": return { sessionId };
      case "session/prompt": return this.prompt(String(params.prompt?.[0]?.text ?? ""), params._meta?.acpmux?.promptId);
      default: return {};
    }
  }

  private async prompt(prompt: string, promptId?: string): Promise<unknown> {
    this.turns += 1;
    const running = { cancelled: false };
    this.running = running;
    this.emit({ mux: "user_message", msg: { text: prompt, promptId } });
    this.emit({ mux: "turn_started" });
    for (const step of mockTurn(prompt, this.turns)) {
      await this.delay(350);
      if (running.cancelled) break;
      this.emit(step);
    }
    this.emit({ mux: "turn_result", msg: { status: running.cancelled ? "cancelled" : "completed" } });
    this.running = undefined;
    return { stopReason: running.cancelled ? "cancelled" : "end_turn" };
  }

  private record(step: Step): EventRecord {
    this.seq += 1;
    const event: EventRecord = "update" in step
      ? { sessionId, seq: this.seq, at: Date.now(), dir: "in", kind: String(step.update.sessionUpdate), msg: { method: "session/update", params: { sessionId, update: step.update } } }
      : { sessionId, seq: this.seq, at: Date.now(), dir: "mux", kind: step.mux, msg: step.msg ?? {} };
    this.events.push(event);
    return event;
  }

  private emit(step: Step): void { this.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: this.record(step) }); }

  private deliver(message: unknown): void {
    queueMicrotask(() => { if (this.readyState === 1) this.onmessage?.({ data: JSON.stringify(message) }); });
  }
}
