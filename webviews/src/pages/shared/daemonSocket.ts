// One WebSocket connection of a page to its cmux instance's daemon (cmux-tui spec/transports.md
// "WebSocket"): the same raw protocol-12 envelopes the app sends on the Unix socket, one JSON
// object per text frame. The first frame authenticates (unless a same-origin relay already
// authenticated upstream, `{ origin: true }`): the daemon credential, or a pairing request
// the person approves on a human surface of that instance (the TUI, the verified app); the approved
// pairing returns a reconnect credential. Credentials never go in a URL or a log line.
//
// The same protocol in every host: a plain browser tab, the app's web view, Chromium, GPUI
// (plans: hq .cmux-scratch/hq6d-channels-portable/ARCHITECTURE.md).

export interface DaemonError extends Error {
  code: string;
}

export type DaemonAuth =
  | { token: string }
  /** The page's own origin already authorized this socket: a same-origin relay that identified the
   *  person attaches the credential upstream, so the page sends no preamble and never holds it. */
  | { origin: true }
  | { pair: { onChallenge(code: string, expiresIn: number): void; onCredential(credential: string): void } };

type Pending = { resolve(data: unknown): void; reject(error: unknown): void };

/** The resource API's envelope (spec resource-api-v2.md), on the same connection as raw commands. */
const OPERATION_PROTOCOL = "cmux.protocol/2";
/** The longest a page waits for one operation's answer. */
const OPERATION_TIMEOUT_MS = 20_000;

function daemonError(code: string, message: string): DaemonError {
  const error = new Error(message) as DaemonError;
  error.name = "DaemonError";
  error.code = code;
  return error;
}

export class DaemonSocket {
  private socket: WebSocket | null = null;
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private readonly operations = new Map<string, Pending>();
  private readonly listeners = new Set<(event: Record<string, unknown>) => void>();
  private readonly closeListeners = new Set<(reason: string) => void>();
  private endpoint = "";

  /** The WebSocket URL this connection opened (no credential in it): the daemon's origin, where
   * its listener also serves plain HTTP paths such as attachment download links. */
  get url(): string {
    return this.endpoint;
  }

  /** Opens and authenticates. Resolves once the daemon accepts protocol frames. */
  static async connect(url: string, auth: DaemonAuth): Promise<DaemonSocket> {
    const client = new DaemonSocket();
    await client.open(url, auth);
    return client;
  }

  private open(url: string, auth: DaemonAuth): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      this.socket = socket;
      this.endpoint = url;
      let ready = false;
      socket.addEventListener("open", () => {
        if ("origin" in auth) {
          // The relay authenticated upstream. If it attached no credential, the daemon closes on the
          // first protocol frame (1008, or another close code through the relay), which rejects
          // the identify below like a wrong token.
          ready = true;
          resolve();
        } else if ("token" in auth) {
          socket.send(JSON.stringify({ auth: { token: auth.token } }));
          // The token preamble gets no reply: the next frames are protocol frames. A wrong token
          // closes the socket with 1008 before the first reply, which rejects the identify below.
          ready = true;
          resolve();
        } else {
          socket.send(JSON.stringify({ pair: { request: true } }));
        }
      });
      socket.addEventListener("message", (event) => {
        let value: Record<string, unknown>;
        try {
          const parsed: unknown = JSON.parse(String(event.data));
          if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return;
          value = parsed as Record<string, unknown>;
        } catch {
          return;
        }
        if (!ready && "pair" in auth) {
          const pairing = value.pairing as { code?: string; expires_in?: number } | undefined;
          const paired = value.paired as { credential?: string } | undefined;
          if (pairing?.code) auth.pair.onChallenge(pairing.code, pairing.expires_in ?? 60);
          else if (paired?.credential) {
            auth.pair.onCredential(paired.credential);
            ready = true;
            resolve();
          } else if (value.pairing_error) {
            const failure = value.pairing_error as { code?: string; message?: string };
            reject(daemonError(failure.code ?? "pairing_error", failure.message ?? "pairing failed"));
          }
          return;
        }
        this.receive(value);
      });
      socket.addEventListener("close", (event) => {
        const reason = event.code === 1008 ? "authentication failed" : `closed (${event.code})`;
        if (!ready) reject(daemonError(event.code === 1008 ? "auth_rejected" : "unreachable", reason));
        const code = event.code === 1008 ? "auth_rejected" : "disconnected";
        for (const waiter of [...this.pending.values(), ...this.operations.values()])
          waiter.reject(daemonError(code, reason));
        this.pending.clear();
        this.operations.clear();
        for (const listener of this.closeListeners) listener(reason);
      });
    });
  }

  private receive(value: Record<string, unknown>): void {
    if (typeof value.event === "string") {
      for (const listener of this.listeners) listener(value);
      return;
    }
    if (value.protocol === OPERATION_PROTOCOL && typeof value.id === "string") {
      const waiter = this.operations.get(value.id);
      if (!waiter) return;
      this.operations.delete(value.id);
      if (value.ok === true) waiter.resolve(value.result);
      else {
        const error = (value.error ?? {}) as { code?: unknown; message?: unknown };
        const code = String(error.code ?? "error");
        waiter.reject(daemonError(code, String(error.message ?? code)));
      }
      return;
    }
    const id = typeof value.id === "number" ? value.id : undefined;
    const waiter = id === undefined ? undefined : this.pending.get(id);
    if (!waiter || id === undefined) return;
    this.pending.delete(id);
    if (value.ok === true) waiter.resolve(value.data);
    else {
      const code = String(value.error_code ?? value.reason ?? "error");
      waiter.reject(daemonError(code, String(value.error ?? code)));
    }
  }

  /** One raw command; resolves to its `data`, rejects with the daemon's `error_code`. */
  request<T = Record<string, unknown>>(cmd: string, params: Record<string, unknown> = {}): Promise<T> {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN)
      return Promise.reject(daemonError("disconnected", "not connected"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: (data) => resolve(data as T), reject });
      socket.send(JSON.stringify({ ...params, id, cmd }));
    });
  }

  /** One `cmux.protocol/2` operation (resource-api-v2.md); resolves to its `result`, rejects with
   *  the error's `code`. A mutation needs `idempotencyKey`. */
  operation<T = Record<string, unknown>>(
    operation: string,
    params: Record<string, unknown>,
    idempotencyKey?: string,
  ): Promise<T> {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN)
      return Promise.reject(daemonError("disconnected", "not connected"));
    const id = `op-${this.nextId++}`;
    return new Promise<T>((resolve, reject) => {
      // An operation the daemon never answers ends here instead of hanging its caller.
      const timer = setTimeout(() => {
        if (this.operations.delete(id)) reject(daemonError("timeout", `${operation} got no answer`));
      }, OPERATION_TIMEOUT_MS);
      const settle = (done: () => void) => {
        clearTimeout(timer);
        done();
      };
      this.operations.set(id, {
        resolve: (data) => settle(() => resolve(data as T)),
        reject: (error) => settle(() => reject(error)),
      });
      socket.send(
        JSON.stringify({
          protocol: OPERATION_PROTOCOL,
          type: "request",
          id,
          operation,
          ...(idempotencyKey ? { idempotency_key: idempotencyKey } : {}),
          params,
        }),
      );
    });
  }

  /** Every event frame (`{event: ...}`) of this connection. */
  onEvent(listener: (event: Record<string, unknown>) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  onClose(listener: (reason: string) => void): () => void {
    this.closeListeners.add(listener);
    return () => this.closeListeners.delete(listener);
  }

  close(): void {
    this.socket?.close();
  }
}
