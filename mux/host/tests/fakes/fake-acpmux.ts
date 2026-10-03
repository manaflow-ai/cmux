import { createServer, type Server, type Socket } from "node:net";
import type { AcpmuxEvent, SessionStatus, SessionSummary } from "../../src/acpmux-client.ts";

// A fake acpmux daemon: newline JSON-RPC 2.0 on a Unix socket with the
// subset the brain host and `mux agents` use. Each session runs one turn at a
// time; a prompt with a promptId it already has is deduped (answered with the
// first result, no new events). Turns are answered by `respond` (default:
// echo), which may return a promise the test resolves to hold a turn open.

type Respond = (session: SessionSummary, text: string, promptId?: string) => string | Promise<string>;

interface Session {
  summary: SessionSummary;
  events: AcpmuxEvent[];
  queue: { text: string; promptId?: string; reply: (result: unknown) => void }[];
  running: boolean;
  /** promptId -> the settled prompt result, or the waiters of a pending one. */
  prompts: Map<string, { result?: unknown; waiters: ((result: unknown) => void)[] }>;
  pending: { permissionId: string; request: Record<string, unknown> }[];
}

export class FakeAcpmux {
  readonly calls: { method: string; params: Record<string, unknown> }[] = [];
  /** Methods whose replies are withheld (a stuck request). */
  readonly hold = new Set<string>();
  respond: Respond = (_s, text) => `echo: ${text}`;
  private server!: Server;
  private readonly clients = new Set<Socket>();
  private readonly watchers = new Set<Socket>();
  private readonly attached = new Map<string, Set<Socket>>();
  readonly sessions = new Map<string, Session>();
  private nextSession = 1;
  private listeners: (() => void)[] = [];

  constructor(readonly path: string) {}

  async start(): Promise<void> {
    this.server = createServer((socket) => this.accept(socket));
    await new Promise<void>((resolve) => this.server.listen(this.path, resolve));
  }

  async stop(): Promise<void> {
    for (const socket of this.clients) socket.destroy();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }

  dropClients(): void {
    for (const socket of this.clients) socket.destroy();
  }

  until(predicate: () => boolean): Promise<void> {
    if (predicate()) return Promise.resolve();
    return new Promise((resolve) => {
      const check = () => {
        if (!predicate()) return;
        this.listeners = this.listeners.filter((l) => l !== check);
        resolve();
      };
      this.listeners.push(check);
    });
  }

  byName(name: string): Session | undefined {
    return [...this.sessions.values()].find((s) => s.summary.name === name);
  }

  /** Prompts (user_message events) a session received, in order. */
  userMessages(name: string): { text: string; promptId?: string }[] {
    return (this.byName(name)?.events ?? [])
      .filter((e) => e.kind === "user_message")
      .map((e) => ({ text: String(e.msg.text), promptId: e.msg.promptId as string | undefined }));
  }

  /** A child asks for a permission (status waiting, permission_pending to watchers). */
  requestPermission(sessionId: string, request: Record<string, unknown>): string {
    const session = this.sessions.get(sessionId)!;
    const permissionId = `perm-${session.pending.length + 1}`;
    session.pending.push({ permissionId, request });
    session.summary.pendingPermissions = session.pending.length;
    this.setStatus(session, "waiting", "permission");
    this.broadcast(this.watchers, "_acpmux/permission_pending", { sessionId, permissionId, request });
    return permissionId;
  }

  /** Open client connections. */
  get clientCount(): number {
    return this.clients.size;
  }

  private accept(socket: Socket): void {
    this.clients.add(socket);
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      for (let nl = buffer.indexOf("\n"); nl >= 0; nl = buffer.indexOf("\n")) {
        const line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        if (!line.trim()) continue;
        const message = JSON.parse(line) as { id?: number; method: string; params?: Record<string, unknown> };
        const params = message.params ?? {};
        this.calls.push({ method: message.method, params });
        const reply = (result: unknown) => {
          if (message.id !== undefined && !socket.destroyed && !this.hold.has(message.method))
            socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result })}\n`);
          this.notify();
        };
        try {
          this.handle(socket, message.method, params, reply);
        } catch (error) {
          if (message.id !== undefined && !socket.destroyed)
            socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: (error as Error).message } })}\n`);
        }
        this.notify();
      }
    });
    socket.on("close", () => {
      this.clients.delete(socket);
      this.watchers.delete(socket);
      for (const set of this.attached.values()) set.delete(socket);
    });
    socket.on("error", () => {});
  }

  private notify(): void {
    for (const listener of [...this.listeners]) listener();
  }

  private resolve(id: unknown): Session {
    const key = String(id);
    const session = this.sessions.get(key) ?? this.byName(key);
    if (!session) throw new Error(`no such session ${key}`);
    return session;
  }

  private handle(socket: Socket, method: string, params: Record<string, unknown>, reply: (r: unknown) => void): void {
    switch (method) {
      case "initialize":
        return reply({ protocolVersion: 1, agentCapabilities: {} });
      case "_acpmux/sessions":
        return reply({ sessions: [...this.sessions.values()].map((s) => s.summary) });
      case "_acpmux/watch":
        if (params.enabled === false) this.watchers.delete(socket);
        else this.watchers.add(socket);
        return reply({});
      case "session/new": {
        const meta = ((params._meta as { acpmux?: Record<string, string> } | undefined)?.acpmux ?? {}) as Record<string, string>;
        const sessionId = `s-${this.nextSession++}`;
        const summary: SessionSummary = {
          sessionId,
          name: meta.name ?? sessionId,
          harness: meta.harness ?? "fake",
          cwd: String(params.cwd),
          status: "idle",
          pendingPermissions: 0,
          stateSeq: 0,
          lastSeq: 0,
          turnCount: 0,
          preview: null,
          tags: {},
        };
        const session: Session = { summary, events: [], queue: [], running: false, prompts: new Map(), pending: [] };
        this.sessions.set(sessionId, session);
        this.record(session, "created", { mcpServers: params.mcpServers, policy: meta.policy });
        this.changed(session, "created");
        return reply({ sessionId });
      }
      case "_acpmux/tag": {
        const session = this.resolve(params.sessionId);
        Object.assign(session.summary.tags, params.set ?? {});
        this.changed(session, "tags");
        return reply(session.summary);
      }
      case "_acpmux/attach": {
        const session = this.resolve(params.sessionId);
        const after = Number(params.afterSeq ?? 0);
        if (after > (session.summary.lastSeq ?? 0)) throw new Error("cursor_future");
        let set = this.attached.get(session.summary.sessionId);
        if (!set) this.attached.set(session.summary.sessionId, (set = new Set()));
        set.add(socket);
        return reply({ session: session.summary, events: session.events.filter((e) => e.seq > after) });
      }
      case "_acpmux/events": {
        const session = this.resolve(params.sessionId);
        const after = Number(params.afterSeq ?? 0);
        return reply({ events: session.events.filter((e) => e.seq > after) });
      }
      case "_acpmux/info": {
        const session = this.resolve(params.sessionId);
        return reply({ ...session.summary, pending: session.pending });
      }
      case "_acpmux/permission_respond": {
        const session = this.resolve(params.sessionId);
        session.pending = session.pending.filter((p) => p.permissionId !== params.permissionId);
        session.summary.pendingPermissions = session.pending.length;
        this.record(session, "permission_decision", { permissionId: params.permissionId, optionId: params.optionId ?? null });
        this.setStatus(session, session.running ? "running" : "ready", "permission");
        return reply({});
      }
      case "_acpmux/wait": {
        const ids = (params.sessions as string[]).map((id) => this.resolve(id).summary.sessionId);
        const until = (params.until as string[]) ?? ["ready", "permission"];
        const check = () => {
          const resolved = ids.map((id) => this.sessions.get(id)!.summary).filter((s) => until.includes(s.status) || (until.includes("permission") && s.pendingPermissions > 0));
          if (resolved.length === 0) return false;
          reply({ timedOut: false, resolved, sessions: resolved });
          return true;
        };
        if (!check()) this.until(check);
        return;
      }
      case "session/prompt":
        return this.prompt(params, reply);
      default:
        throw new Error(`unknown method ${method}`);
    }
  }

  private prompt(params: Record<string, unknown>, reply: (r: unknown) => void): void {
    const session = this.resolve(params.sessionId);
    const text = ((params.prompt as { text?: string }[]) ?? []).map((p) => p.text ?? "").join("");
    const promptId = (params._meta as { acpmux?: { promptId?: string } } | undefined)?.acpmux?.promptId;
    if (promptId) {
      const known = session.prompts.get(promptId);
      if (known) {
        if (known.result !== undefined) reply(known.result);
        else known.waiters.push(reply);
        return;
      }
      session.prompts.set(promptId, { waiters: [reply] });
    }
    const settle = (result: unknown) => {
      if (!promptId) return reply(result);
      const entry = session.prompts.get(promptId)!;
      entry.result = result;
      for (const waiter of entry.waiters.splice(0)) waiter(result);
    };
    session.queue.push({ text, promptId, reply: settle });
    if (session.running) this.record(session, "queued", { text, ...(promptId ? { promptId } : {}) });
    else void this.drain(session);
  }

  private async drain(session: Session): Promise<void> {
    while (session.queue.length > 0) {
      const next = session.queue.shift()!;
      session.running = true;
      this.record(session, "user_message", { text: next.text, ...(next.promptId ? { promptId: next.promptId } : {}) });
      const started = this.record(session, "turn_started", { prompt: next.text });
      session.summary.lastPrompt = next.text;
      this.setStatus(session, "running", "turn");
      const text = await this.respond(session.summary, next.text, next.promptId);
      // Two chunks, as live session/update notifications recorded in the log.
      const half = Math.ceil(text.length / 2);
      for (const piece of [text.slice(0, half), text.slice(half)].filter(Boolean)) this.chunk(session, piece);
      this.record(session, "turn_end", { stopReason: "end_turn" });
      this.record(session, "turn_result", { status: "completed", stopReason: "end_turn", turnSeq: started.seq });
      session.summary.turnCount = (session.summary.turnCount ?? 0) + 1;
      session.summary.preview = text;
      session.running = false;
      this.setStatus(session, "ready", "turn");
      next.reply({ stopReason: "end_turn", _meta: { acpmux: { promptId: next.promptId, turnSeq: started.seq } } });
    }
  }

  private chunk(session: Session, text: string): void {
    const seq = (session.summary.lastSeq ?? 0) + 1;
    session.summary.lastSeq = seq;
    const params = {
      sessionId: session.summary.sessionId,
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
      _meta: { acpmux: { seq, at: Date.now() } },
    };
    session.events.push({ sessionId: session.summary.sessionId, seq, at: Date.now(), dir: "in", kind: "agent_message_chunk", msg: { params } });
    this.broadcast(this.attached.get(session.summary.sessionId), "session/update", params);
  }

  private record(session: Session, kind: string, msg: Record<string, unknown>): AcpmuxEvent {
    const seq = (session.summary.lastSeq ?? 0) + 1;
    session.summary.lastSeq = seq;
    const event: AcpmuxEvent = { sessionId: session.summary.sessionId, seq, at: Date.now(), dir: "mux", kind, msg };
    session.events.push(event);
    this.broadcast(this.attached.get(session.summary.sessionId), "_acpmux/event", event as unknown as Record<string, unknown>);
    this.notify();
    return event;
  }

  private setStatus(session: Session, status: SessionStatus, kind: string): void {
    session.summary.status = status;
    this.changed(session, kind);
  }

  private changed(session: Session, kind: string): void {
    session.summary.stateSeq += 1;
    this.broadcast(this.watchers, "_acpmux/session_changed", { sessionId: session.summary.sessionId, kind, session: { ...session.summary, tags: { ...session.summary.tags } } });
  }

  private broadcast(sockets: Set<Socket> | undefined, method: string, params: Record<string, unknown>): void {
    if (!sockets) return;
    const line = `${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`;
    for (const socket of sockets) if (!socket.destroyed) socket.write(line);
  }
}
