// JSON-RPC client for the acpmux daemon over its Unix socket
// (newline-delimited JSON). One connection serves requests and, after
// `watch`, notifications for every session. Mirrors mux/link's Rust client.

import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

export function socketPath(env: Record<string, string | undefined> = process.env): string {
  return env.ACPMUX_SOCKET ?? join(env.HOME ?? homedir(), ".acpmux", "acpmux.sock");
}

export interface Notification {
  method: string;
  params: Record<string, unknown>;
}

export interface SessionSummary {
  sessionId: string;
  name: string;
  harness: string;
  cwd: string;
  status: "idle" | "ready" | "running" | "waiting" | "disconnected" | "closed";
  pendingPermissions: number;
  stateSeq: number;
  preview: string | null;
  tags: Record<string, string>;
}

type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  method: string;
};

export class AcpmuxClient {
  private socket: Socket;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private listeners = new Set<(n: Notification) => void>();
  private closeListeners = new Set<() => void>();

  private constructor(socket: Socket) {
    this.socket = socket;
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => this.read(chunk));
    socket.on("close", () => {
      for (const p of this.pending.values())
        p.reject(new Error(`acpmux connection closed during ${p.method}`));
      this.pending.clear();
      for (const listener of this.closeListeners) listener();
    });
    socket.on("error", () => socket.destroy());
  }

  /** Connects and runs `initialize`. */
  static async connect(path = socketPath(), clientName = "mux"): Promise<AcpmuxClient> {
    const socket = await new Promise<Socket>((resolve, reject) => {
      const s = connect(path);
      s.once("connect", () => resolve(s));
      s.once("error", reject);
    });
    const client = new AcpmuxClient(socket);
    await client.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {},
      clientInfo: { name: clientName, version: "0.1.0" },
    });
    return client;
  }

  request<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject, method });
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method: string, params: Record<string, unknown>): void {
    this.write({ jsonrpc: "2.0", method, params });
  }

  onNotification(listener: (n: Notification) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  onClose(listener: () => void): void {
    this.closeListeners.add(listener);
  }

  close(): void {
    this.socket.end();
  }

  // Typed helpers for the methods mux uses.

  sessions(): Promise<SessionSummary[]> {
    return this.request<{ sessions: SessionSummary[] }>("_acpmux/sessions").then((r) => r.sessions);
  }

  watch(enabled = true): Promise<unknown> {
    return this.request("_acpmux/watch", { enabled });
  }

  /** Creates a session; acpmux starts its agent. */
  newSession(options: {
    cwd: string;
    name?: string;
    harness?: string;
    policy?: string;
  }): Promise<{ sessionId: string }> {
    const meta: Record<string, string> = {};
    for (const key of ["name", "harness", "policy"] as const)
      if (options[key]) meta[key] = options[key]!;
    return this.request("session/new", {
      cwd: options.cwd,
      mcpServers: [],
      _meta: { acpmux: meta },
    });
  }

  /**
   * Sends a prompt. The returned promise settles when the turn ends; callers
   * that only queue can ignore it as long as the connection stays open.
   */
  prompt(session: string, text: string): Promise<{ stopReason?: string }> {
    return this.request("session/prompt", { sessionId: session, prompt: [{ type: "text", text }] });
  }

  cancel(session: string): void {
    this.notify("session/cancel", { sessionId: session });
  }

  tag(session: string, set: Record<string, string>): Promise<SessionSummary> {
    return this.request("_acpmux/tag", { sessionId: session, set });
  }

  respondPermission(session: string, permissionId: string, optionId?: string): Promise<unknown> {
    return this.request("_acpmux/permission_respond", {
      sessionId: session,
      permissionId,
      ...(optionId ? { optionId } : {}),
    });
  }

  private write(message: unknown): void {
    this.socket.write(`${JSON.stringify(message)}\n`);
  }

  private read(chunk: string): void {
    this.buffer += chunk;
    let newline = this.buffer.indexOf("\n");
    while (newline >= 0) {
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (line.trim()) this.dispatch(line);
      newline = this.buffer.indexOf("\n");
    }
  }

  private dispatch(line: string): void {
    let message: {
      id?: number;
      method?: string;
      params?: Record<string, unknown>;
      result?: unknown;
      error?: { message?: string };
    };
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (typeof message.id === "number" && ("result" in message || "error" in message)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error)
        pending.reject(
          new Error(`${pending.method}: ${message.error.message ?? JSON.stringify(message.error)}`),
        );
      else pending.resolve(message.result);
      return;
    }
    if (message.method) {
      for (const listener of this.listeners)
        listener({ method: message.method, params: message.params ?? {} });
    }
  }
}

/**
 * Runs `attempt` again when the agent process closed while starting: the
 * subrouter launcher (claude-sr) checks Tailscale at start, and that check
 * can be killed on a busy machine. acpmux keeps the session, so the retry
 * starts its agent again, after a backoff (2 s, 4 s, ...) that gives a loaded
 * machine time to recover.
 */
export async function retryAgentStart<T>(
  attempt: () => Promise<T>,
  attempts = 3,
  backoffMs = 2_000,
): Promise<T> {
  for (let i = 1; ; i++) {
    try {
      return await attempt();
    } catch (error) {
      if (i >= attempts || !String(error).includes("agent process closed")) throw error;
      await new Promise((resolve) => setTimeout(resolve, backoffMs * 2 ** (i - 1)));
    }
  }
}
