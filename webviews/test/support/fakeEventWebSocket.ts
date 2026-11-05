// A stand-in for the browser WebSocket for code that opens one with `new WebSocket(url)` and
// listens with `addEventListener`. `install()` swaps it in for the global and returns the restore.

type Listener = (event: Record<string, unknown>) => void;

export class FakeEventWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  static instances: FakeEventWebSocket[] = [];

  static install(): () => void {
    const scope = globalThis as Record<string, unknown>;
    const had = "WebSocket" in scope;
    const saved = scope.WebSocket;
    FakeEventWebSocket.instances = [];
    scope.WebSocket = FakeEventWebSocket;
    return () => {
      if (had) scope.WebSocket = saved;
      else delete scope.WebSocket;
      FakeEventWebSocket.instances = [];
    };
  }

  readyState = FakeEventWebSocket.CONNECTING;
  readonly sent: string[] = [];
  private readonly listeners = new Map<string, Listener[]>();

  constructor(readonly url: string) {
    FakeEventWebSocket.instances.push(this);
  }

  addEventListener(type: string, listener: Listener, options?: { once?: boolean }): void {
    const wrapped: Listener = options?.once
      ? (event) => {
          this.removeEventListener(type, wrapped);
          listener(event);
        }
      : listener;
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), wrapped]);
  }

  removeEventListener(type: string, listener: Listener): void {
    this.listeners.set(
      type,
      (this.listeners.get(type) ?? []).filter((entry) => entry !== listener),
    );
  }

  send(data: string): void {
    this.sent.push(data);
  }

  /** When set, `close()` only starts closing, as a browser does; `finishClose()` delivers the event. */
  holdClose = false;

  close(code = 1000): void {
    if (this.readyState >= FakeEventWebSocket.CLOSING) return;
    this.readyState = FakeEventWebSocket.CLOSING;
    if (!this.holdClose) this.finishClose(code);
  }

  finishClose(code = 1000): void {
    if (this.readyState === FakeEventWebSocket.CLOSED) return;
    this.readyState = FakeEventWebSocket.CLOSED;
    this.emit("close", { code });
  }

  open(): void {
    this.readyState = FakeEventWebSocket.OPEN;
    this.emit("open", {});
  }

  /** Delivers one text frame synchronously, as the browser's message event does. */
  message(data: string): void {
    this.emit("message", { data });
  }

  private emit(type: string, event: Record<string, unknown>): void {
    for (const listener of this.listeners.get(type)?.slice() ?? []) listener(event);
  }
}
