// One WebSocket connection of a page to its cmux instance's daemon (cmux-tui spec/transports.md
// "WebSocket"): the same raw protocol-12 envelopes the app sends on the Unix socket, one JSON
// object per text frame. The first frame authenticates: the daemon credential, or a pairing request
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
  | { pair: { onChallenge(code: string, expiresIn: number): void; onCredential(credential: string): void } };

type Pending = { resolve(data: unknown): void; reject(error: unknown): void };

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
  private readonly listeners = new Set<(event: Record<string, unknown>) => void>();
  private readonly closeListeners = new Set<(reason: string) => void>();

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
      let ready = false;
      socket.addEventListener("open", () => {
        if ("token" in auth) {
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
          value = JSON.parse(String(event.data)) as Record<string, unknown>;
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
        for (const waiter of this.pending.values()) waiter.reject(daemonError(code, reason));
        this.pending.clear();
        for (const listener of this.closeListeners) listener(reason);
      });
    });
  }

  private receive(value: Record<string, unknown>): void {
    if (typeof value.event === "string") {
      for (const listener of this.listeners) listener(value);
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
    if (!socket || socket.readyState !== WebSocket.OPEN) return Promise.reject(daemonError("disconnected", "not connected"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: (data) => resolve(data as T), reject });
      socket.send(JSON.stringify({ ...params, id, cmd }));
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
