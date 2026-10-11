import { homedir } from "node:os";
import { join } from "node:path";
import type { AcpmuxEvent, SessionSummary } from "../../packages/brain/src/core/acp.ts";
import { LineSocket } from "./line-socket.ts";

// JSON-RPC 2.0 client for the acpmux daemon (newline JSON on its Unix
// socket). New code for the brain host; the method set follows feat-mux
// mux/packages/acpmux/src/client.ts and `acpmux daemon schema`.

export function acpmuxSocketPath(env: Record<string, string | undefined> = process.env): string {
  if (env.ACPMUX_SOCKET) return env.ACPMUX_SOCKET;
  if (env.ACPMUX_HOME) return join(env.ACPMUX_HOME, "acpmux.sock");
  return join(env.HOME ?? homedir(), ".acpmux", "acpmux.sock");
}

export interface Notification {
  method: string;
  params: Record<string, unknown>;
}

// The session and event shapes live in the brain core (packages/brain/src/core/acp.ts).
export type { AcpmuxEvent, SessionStatus, SessionSummary } from "../../packages/brain/src/core/acp.ts";

/** ACP stdio MCP server entry for session/new. */
export interface McpServer {
  name: string;
  command: string;
  args: string[];
  env: { name: string; value: string }[];
}

export class AcpmuxError extends Error {
  constructor(
    readonly method: string,
    readonly rpcMessage: string,
    readonly code?: number,
  ) {
    super(`${method}: ${rpcMessage}`);
  }
}

/** The connection closed before the answer (not a refusal by acpmux). */
export class AcpmuxClosedError extends AcpmuxError {}

type Pending = { method: string; resolve: (value: unknown) => void; reject: (error: Error) => void };

export class AcpmuxClient {
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private readonly listeners = new Set<(n: Notification) => void>();
  private socket!: LineSocket;

  /** Connects and runs `initialize`. */
  /** Connects and runs `initialize`. Aborting `signal` closes the socket, so a stuck handshake leaves nothing open. */
  static async connect(path = acpmuxSocketPath(), clientName = "mux-host", signal?: AbortSignal): Promise<AcpmuxClient> {
    const client = new AcpmuxClient();
    client.socket = await LineSocket.open(path, (message) => client.dispatch(message), signal);
    client.socket.onClose(() => {
      for (const p of client.pending.values())
        p.reject(new AcpmuxClosedError(p.method, "acpmux connection closed"));
      client.pending.clear();
    });
    const abort = () => client.close();
    if (signal?.aborted) abort();
    signal?.addEventListener("abort", abort, { once: true });
    try {
      await client.request("initialize", {
        protocolVersion: 1,
        clientCapabilities: {},
        clientInfo: { name: clientName, version: "0.1.0" },
      });
    } catch (error) {
      client.close();
      throw error;
    } finally {
      signal?.removeEventListener("abort", abort);
    }
    return client;
  }

  request<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { method, resolve: resolve as (v: unknown) => void, reject });
      try {
        this.socket.send({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        this.pending.delete(id);
        reject(error as Error);
      }
    });
  }

  onNotification(listener: (n: Notification) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  onClose(listener: (error?: Error) => void): () => void {
    return this.socket.onClose(listener);
  }

  get isClosed(): boolean {
    return this.socket.isClosed;
  }

  close(): void {
    this.socket.close();
  }

  sessions(): Promise<SessionSummary[]> {
    return this.request<{ sessions: SessionSummary[] }>("_acpmux/sessions").then((r) => r.sessions);
  }

  watch(enabled = true): Promise<unknown> {
    return this.request("_acpmux/watch", { enabled });
  }

  attach(sessionId: string, afterSeq = 0, limit = 1_000_000): Promise<{ session: SessionSummary; events: AcpmuxEvent[] }> {
    return this.request("_acpmux/attach", { sessionId, afterSeq, limit });
  }

  events(sessionId: string, afterSeq = 0, limit = 1_000_000): Promise<AcpmuxEvent[]> {
    return this.request<{ events: AcpmuxEvent[] }>("_acpmux/events", { sessionId, afterSeq, limit }).then(
      (r) => r.events,
    );
  }

  info(sessionId: string): Promise<SessionSummary & { pending?: { permissionId: string; request: Record<string, unknown> }[] }> {
    return this.request("_acpmux/info", { sessionId });
  }

  newSession(options: {
    cwd: string;
    name?: string;
    harness?: string;
    model?: string;
    policy?: string;
    mcpServers?: McpServer[];
  }): Promise<{ sessionId: string }> {
    const meta: Record<string, string> = {};
    for (const key of ["name", "harness", "model", "policy"] as const)
      if (options[key]) meta[key] = options[key]!;
    return this.request("session/new", {
      cwd: options.cwd,
      mcpServers: options.mcpServers ?? [],
      _meta: { acpmux: meta },
    });
  }

  /**
   * Sends a prompt; settles when its turn ends. `delivery: "turn"` makes it its
   * own turn after the current one. acpmux drops a still-queued prompt when
   * this connection closes, so callers keep the connection open.
   */
  prompt(
    session: string,
    text: string,
    options: { promptId?: string; delivery?: "tools" | "response" | "turn" | "hold" | "now" } = {},
  ): Promise<{ stopReason?: string }> {
    const meta: Record<string, string> = {};
    if (options.promptId) meta.promptId = options.promptId;
    if (options.delivery) meta.delivery = options.delivery;
    return this.request("session/prompt", {
      sessionId: session,
      prompt: [{ type: "text", text }],
      ...(Object.keys(meta).length ? { _meta: { acpmux: meta } } : {}),
    });
  }

  tag(sessionId: string, set: Record<string, string>): Promise<SessionSummary> {
    return this.request("_acpmux/tag", { sessionId, set });
  }

  respondPermission(sessionId: string, permissionId: string, optionId?: string): Promise<unknown> {
    return this.request("_acpmux/permission_respond", {
      sessionId,
      permissionId,
      ...(optionId ? { optionId } : {}),
    });
  }

  kill(sessionId: string, purge = false): Promise<unknown> {
    return this.request("_acpmux/kill", { sessionId, purge });
  }

  /** acpmux's own server-side wait (event-driven, no polling here). */
  wait(params: { sessions: string[]; until: string[]; timeoutMs?: number }): Promise<{ timedOut: boolean; resolved: SessionSummary[] }> {
    return this.request("_acpmux/wait", params);
  }

  private dispatch(message: Record<string, unknown>): void {
    const id = message.id;
    if (typeof id === "number" && ("result" in message || "error" in message)) {
      const pending = this.pending.get(id);
      if (!pending) return;
      this.pending.delete(id);
      const error = message.error as { message?: string; code?: number } | undefined;
      if (error) pending.reject(new AcpmuxError(pending.method, error.message ?? JSON.stringify(error), error.code));
      else pending.resolve(message.result);
      return;
    }
    if (typeof message.method === "string") {
      const n = { method: message.method, params: (message.params ?? {}) as Record<string, unknown> };
      for (const listener of this.listeners) listener(n);
    }
  }
}

/**
 * A live ACP `session/update` (agent output) in the shape acpmux records it
 * in its event log, so replay and live events fold the same way.
 */
export function eventFromUpdate(params: Record<string, unknown>): AcpmuxEvent {
  const meta = (params._meta as { acpmux?: { seq?: number; at?: number } } | undefined)?.acpmux ?? {};
  const update = (params.update ?? {}) as { sessionUpdate?: string };
  return {
    sessionId: typeof params.sessionId === "string" ? params.sessionId : undefined,
    seq: meta.seq ?? 0,
    at: meta.at,
    dir: "in",
    kind: update.sessionUpdate ?? "",
    msg: { params },
  };
}
