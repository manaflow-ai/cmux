import type { AcpmuxHostConfig, EventRecord } from "./direct";

// Mock transport: the host answers `ready` with `{transport: "mock"}` when no
// acpmux daemon is wanted (demos, screenshots, tests). The page then runs the
// real acpmux client against this in-page daemon, which speaks the daemon's
// JSON-RPC and streams a scripted turn as ACP events, so every frame of a mock
// turn goes through the same reducer and renderers as a real agent's.

const sessionId = "mock-session";
const harnesses = [{ id: "claude", name: "Claude Code", models: [{ id: "claude-sonnet", name: "Claude Sonnet" }] }, { id: "codex", name: "Codex", models: [{ id: "gpt-6-astra", name: "GPT-6-Astra" }] }];
const commands = [{ name: "compact", description: "Clear conversation history but keep a summary in context", input: { hint: "optional custom summarization instructions" } }, { name: "init", description: "Initialize a new CLAUDE.md file with codebase documentation" }, { name: "pr-comments", description: "Get comments from a GitHub pull request" }, { name: "review", description: "Review a pull request" }];
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
  private sessions = [{ ...session }];
  private events: EventRecord[] = [];
  private seq = 0;
  private turns = 0;
  private running?: { cancelled: boolean };
  private closed = false;
  /// Prompts run one at a time, as the daemon queues them.
  private queue: Promise<unknown> = Promise.resolve();

  /// `delay` paces the scripted turn; tests pass one that resolves at once.
  constructor(private readonly delay: (ms: number) => Promise<void> = (ms) => new Promise((resolve) => window.setTimeout(resolve, ms))) {
    // What Claude lists at start, so the composer's + and `/` menu have something to show.
    this.record(sessionId, { update: { sessionUpdate: "available_commands_update", availableCommands: commands } });
    this.record(sessionId, { update: text("Mock agent session. Type a prompt to see the pane render a turn.") });
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

  close(): void {
    this.readyState = 3;
    this.closed = true;
    if (this.running) this.running.cancelled = true;
  }

  private async answer(method: string, params: Record<string, any>): Promise<unknown> {
    const target = String(params.sessionId ?? sessionId);
    switch (method) {
      case "_acpmux/watch": return { sessions: this.sessions };
      case "_acpmux/harnesses": return { harnesses };
      case "_acpmux/attach": return { session: this.sessions.find((entry) => entry.sessionId === target), events: this.events.filter((event) => event.sessionId === target) };
      case "_acpmux/events": return { events: this.events.filter((event) => event.sessionId === target && event.seq > Number(params.afterSeq ?? 0)) };
      case "session/new": {
        const created = { ...session, sessionId: `mock-session-${this.sessions.length + 1}`, title: "New chat" };
        this.sessions.push(created);
        this.deliver({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind: "created", session: created } });
        return { sessionId: created.sessionId };
      }
      case "session/prompt": {
        const turn = this.queue.then(() => this.prompt(target, String(params.prompt?.[0]?.text ?? ""), params._meta?.acpmux?.promptId));
        this.queue = turn.catch(() => undefined);
        return turn;
      }
      default: return {};
    }
  }

  private async prompt(target: string, prompt: string, promptId?: string): Promise<unknown> {
    // A prompt queued behind a closed daemon never starts.
    if (this.closed) return { stopReason: "cancelled" };
    this.turns += 1;
    const running = { cancelled: false };
    this.running = running;
    this.emit(target, { mux: "user_message", msg: { text: prompt, promptId } });
    this.emit(target, { mux: "turn_started" });
    for (const step of mockTurn(prompt, this.turns)) {
      await this.delay(350);
      if (running.cancelled || this.closed) break;
      this.emit(target, step);
    }
    this.emit(target, { mux: "turn_result", msg: { status: running.cancelled ? "cancelled" : "completed" } });
    this.running = undefined;
    return { stopReason: running.cancelled ? "cancelled" : "end_turn" };
  }

  private record(target: string, step: Step): EventRecord {
    this.seq += 1;
    const event: EventRecord = "update" in step
      ? { sessionId: target, seq: this.seq, at: Date.now(), dir: "in", kind: String(step.update.sessionUpdate), msg: { method: "session/update", params: { sessionId: target, update: step.update } } }
      : { sessionId: target, seq: this.seq, at: Date.now(), dir: "mux", kind: step.mux, msg: step.msg ?? {} };
    this.events.push(event);
    return event;
  }

  private emit(target: string, step: Step): void { this.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: this.record(target, step) }); }

  private deliver(message: unknown): void {
    queueMicrotask(() => { if (this.readyState === 1) this.onmessage?.({ data: JSON.stringify(message) }); });
  }
}
