import { homedir } from "node:os";
import { join } from "node:path";
import type { AcpmuxEvent, SessionSummary } from "../../packages/brain/src/core/acp.ts";
import { LineSocket } from "./line-socket.ts";

// JSON-RPC 2.0 client for the acpmux daemon (newline JSON on its Unix
// socket). New code for the brain host; the method set follows feat-mux
// mux/packages/acpmux/src/client.ts and `acpmux daemon schema`.

/** The longest Unix socket path every host binds (cmux-agent-pane-policy MAX_SOCKET_PATH_BYTES). */
const MAX_SOCKET_PATH_BYTES = 103;

/** FNV-1a 64 of the UTF-8 bytes, as 16 hex digits. */
function fnv1a64(text: string): string {
  let hash = 0xcbf29ce484222325n;
  for (const byte of new TextEncoder().encode(text)) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, "0");
}

/**
 * The acpmux daemon socket every host and client resolves (cmux-agent-pane-policy
 * `environment::socket_path`, tests/cases/environment.json): ACPMUX_SOCKET, except an
 * absolute path past the Unix socket limit (a long TMPDIR), which maps to the short alias
 * acpmux binds; else `<home>/acpmux.sock`, or the alias of a long home.
 */
export function acpmuxSocketPath(
  env: Record<string, string | undefined> = process.env,
  uid: number = process.getuid?.() ?? 0,
): string {
  const alias = (key: string) => `/tmp/acpmux-${uid}/${fnv1a64(key)}.sock`;
  const configured = env.ACPMUX_SOCKET;
  if (configured) {
    const long = configured.startsWith("/") && Buffer.byteLength(configured) > MAX_SOCKET_PATH_BYTES;
    return long ? alias(configured) : configured;
  }
  const home = env.ACPMUX_HOME || join(env.HOME ?? homedir(), ".acpmux");
  const preferred = join(home, "acpmux.sock");
  return Buffer.byteLength(preferred) < 96 ? preferred : alias(home);
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

/** `_acpmux/sessions` and `_acpmux/watch`'s reply: a page of the list, and its cursor when more follow. */
type SessionList = { sessions?: SessionSummary[]; nextCursor?: unknown };

/** acpmux's order (hub/session_pages.rs `sort_session_summaries`): newest first, then by
 * `sessionId`, then by `peer`, this daemon's own row (no `peer`) first. */
function newestFirst(a: SessionSummary, b: SessionSummary): number {
  const row = (session: SessionSummary) => session as unknown as Record<string, unknown>;
  const updated = (session: SessionSummary) => {
    const at = row(session).updatedAt;
    return typeof at === "number" ? at : 0;
  };
  const text = (session: SessionSummary, key: string) => {
    const value = row(session)[key];
    return typeof value === "string" ? value : undefined;
  };
  const order = (x: string | undefined, y: string | undefined) =>
    x === y ? 0 : x === undefined ? -1 : y === undefined ? 1 : x < y ? -1 : 1;
  return (
    updated(b) - updated(a) ||
    order(text(a, "sessionId") ?? "", text(b, "sessionId") ?? "") ||
    order(text(a, "peer"), text(b, "peer"))
  );
}
type Pending = { method: string; resolve: (value: unknown) => void; reject: (error: Error) => void };

export class AcpmuxClient {
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private readonly listeners = new Set<(n: Notification) => void>();
  private socket!: LineSocket;

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
    return this.wholeList("_acpmux/sessions", {}).then((r) => r.sessions ?? []);
  }

  watch(enabled = true): Promise<unknown> {
    return this.wholeList("_acpmux/watch", { enabled });
  }

  /** A list asked without `limit`, whole: past acpmux's largest reply it answers its first rows
   * and a `nextCursor`, and the rest comes from `_acpmux/sessions` with that cursor and the same
   * params but `enabled`. A list that fits (and any older daemon) answers one reply, no cursor.
   * As acpmux's own client (client.rs `whole_list`), a bad or repeated cursor, or a paged reply
   * with no `sessions`, is an error: a short list would pass for the whole one. */
  private async wholeList(method: string, params: Record<string, unknown>): Promise<SessionList> {
    const reply = await this.request<SessionList>(method, params);
    const rest = { ...params };
    delete rest.enabled;
    const seen = new Set<string>();
    for (let next = reply.nextCursor; next !== undefined && next !== null; ) {
      const cursor = JSON.stringify(next);
      if (typeof next !== "string") throw new Error(`${method}: acpmux gave the page cursor ${cursor}`);
      // A cursor that comes back would repeat forever.
      if (seen.has(next)) throw new Error(`${method}: acpmux gave the page cursor ${cursor} twice`);
      seen.add(next);
      const page = await this.request<SessionList>("_acpmux/sessions", { ...rest, cursor: next });
      // A watch reply with no list and no cursor still means "list after watch" (host.ts); a paged one has its list.
      if (!Array.isArray(reply.sessions) || !Array.isArray(page.sessions))
        throw new Error(`${method}: the page after cursor ${cursor} lists no sessions`);
      for (const session of page.sessions) reply.sessions.push(session);
      next = page.nextCursor;
    }
    delete reply.nextCursor;
    // The pages come in an order updates do not change (hash order), not newest first.
    if (seen.size > 0) reply.sessions?.sort(newestFirst);
    return reply;
  }

  attach(sessionId: string, afterSeq = 0, limit = 1_000_000): Promise<{ session: SessionSummary; events: AcpmuxEvent[] }> {
    return this.request("_acpmux/attach", { sessionId, afterSeq, limit });
  }

  /** Up to `limit` events after `afterSeq`, oldest first. A page ends at the daemon's byte
   * limit (1 MiB by default) with `hasMore`, so this reads page after page. */
  async events(sessionId: string, afterSeq = 0, limit = 1_000_000): Promise<AcpmuxEvent[]> {
    const all: AcpmuxEvent[] = [];
    let cursor = afterSeq;
    while (all.length < limit) {
      const page = await this.request<{ events: AcpmuxEvent[]; hasMore?: boolean }>("_acpmux/events", {
        sessionId,
        afterSeq: cursor,
        limit: limit - all.length,
      });
      all.push(...page.events);
      const last = page.events.at(-1)?.seq;
      // A page that does not move the cursor would repeat forever.
      if (!page.hasMore || typeof last !== "number" || last <= cursor) break;
      cursor = last;
    }
    return all;
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
