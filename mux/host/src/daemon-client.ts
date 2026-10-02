import {
  LOCAL_CONVERSATIONS_CAPABILITY,
  type Message,
  type Op,
  type OpResult,
  type Participant,
  type ParticipantId,
  type Summary,
} from "./conversation-types.ts";
import { LineSocket } from "./line-socket.ts";

/** A rejected daemon request: `error_code` (e.g. `conversation_rejected`) and the owner's text. */
export class DaemonError extends Error {
  constructor(
    readonly cmd: string,
    message: string,
    readonly code?: string,
  ) {
    super(`${cmd}: ${message}${code ? ` (${code})` : ""}`);
  }
}

/** The daemon cannot host local conversations: the host refuses to start. */
export class MissingCapabilityError extends Error {}

export interface Identity {
  app?: string;
  version?: string;
  protocol?: number;
  capabilities?: string[];
  session?: string;
  pid?: number;
}

type Pending = { cmd: string; resolve: (data: unknown) => void; reject: (error: Error) => void };

/**
 * A client of the cmux daemon's v2 line protocol (`{"id":N,"cmd":...}`), for
 * the local conversation owner (home.md section 2). One connection carries
 * requests and, after `subscribe`, `{"event":...}` lines.
 */
export class DaemonClient {
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private socket!: LineSocket;
  identity: Identity = {};

  private constructor(private readonly onEvent: (event: Record<string, unknown>) => void) {}

  /**
   * Connects, identifies, and refuses a daemon without `local-conversations-v1`.
   * With `subscribe`, the connection then streams events to `onEvent`.
   */
  static async connect(
    path: string,
    options: { onEvent?: (event: Record<string, unknown>) => void; subscribe?: boolean } = {},
  ): Promise<DaemonClient> {
    const client = new DaemonClient(options.onEvent ?? (() => {}));
    client.socket = await LineSocket.open(path, (message) => client.dispatch(message));
    client.socket.onClose(() => {
      for (const pending of client.pending.values())
        pending.reject(new Error(`daemon connection closed during ${pending.cmd}`));
      client.pending.clear();
    });
    try {
      client.identity = await client.request<Identity>("identify");
      if (!client.identity.capabilities?.includes(LOCAL_CONVERSATIONS_CAPABILITY))
        throw new MissingCapabilityError(
          `daemon at ${path} (${client.identity.app ?? "unknown"} ${client.identity.version ?? ""}) lacks ${LOCAL_CONVERSATIONS_CAPABILITY}`,
        );
      if (options.subscribe) await client.request("subscribe", { tree_events: "deltas" });
    } catch (error) {
      client.close();
      throw error;
    }
    return client;
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

  request<T = unknown>(cmd: string, params: Record<string, unknown> = {}): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { cmd, resolve: resolve as (data: unknown) => void, reject });
      try {
        this.socket.send({ id, cmd, ...params });
      } catch (error) {
        this.pending.delete(id);
        reject(error as Error);
      }
    });
  }

  // Typed commands (home.md section 2).

  list(): Promise<Summary[]> {
    return this.request<{ conversations: Summary[] }>("conversation-list").then((d) => d.conversations);
  }

  create(params: {
    idempotency_key: string;
    actor: ParticipantId;
    title: string;
    participants: Participant[];
  }): Promise<{ conversation: Summary; replayed: boolean }> {
    return this.request("conversation-create", params);
  }

  snapshot(conversation: string, tail: number): Promise<{ conversation: Summary; messages: Message[] }> {
    return this.request("conversation-snapshot", { conversation, tail });
  }

  history(conversation: string, beforeSeq: number, limit: number): Promise<Message[]> {
    return this.request<{ messages: Message[] }>("conversation-history", {
      conversation,
      before_seq: beforeSeq,
      limit,
    }).then((d) => d.messages);
  }

  op(params: {
    conversation: string;
    idempotency_key: string;
    actor: ParticipantId;
    transaction?: string;
    op: Op;
  }): Promise<OpResult> {
    return this.request("conversation-op", params);
  }

  /** Binds this connection to agent `participant` (the owner then stamps it as the actor). */
  bind(participant: ParticipantId, token: string): Promise<unknown> {
    return this.request("conversation-bind", { participant, token });
  }

  typing(conversation: string, actor: ParticipantId, on: boolean): Promise<unknown> {
    return this.request("conversation-typing", { conversation, actor, on });
  }

  private dispatch(message: Record<string, unknown>): void {
    if (typeof message.id === "number" && "ok" in message) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.ok === true) pending.resolve(message.data ?? {});
      else
        pending.reject(
          new DaemonError(
            pending.cmd,
            String(message.error ?? "request failed"),
            typeof message.error_code === "string" ? message.error_code : undefined,
          ),
        );
      return;
    }
    if (typeof message.event === "string") this.onEvent(message);
  }
}
