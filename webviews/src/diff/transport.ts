import type {
  DiffEvent,
  DiffRequest,
  DiffResourceRef,
  DiffResult,
  DiffResponse,
  DiffTransportConfig,
} from "./generated/protocol";

type WithoutEnvelope<T> = T extends unknown ? Omit<T, "id" | "version"> : never;
type DiffCommand = WithoutEnvelope<DiffRequest>;
type DiffEventListener = (event: DiffEvent) => void;

declare global {
  interface Window {
    cmuxDiffBridge?: {
      receive(event: DiffEvent): void;
    };
  }
}

export interface DiffTransport {
  request(command: DiffCommand): Promise<DiffResult>;
  subscribe(listener: DiffEventListener): () => void;
  openResource(ref: DiffResourceRef): Promise<Response>;
  close(): void;
}

abstract class BaseDiffTransport implements DiffTransport {
  protected readonly version: number;
  private readonly listeners = new Set<DiffEventListener>();

  constructor(version: number) {
    this.version = version;
  }

  abstract request(command: DiffCommand): Promise<DiffResult>;

  subscribe(listener: DiffEventListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  openResource(ref: DiffResourceRef): Promise<Response> {
    return fetch(ref.id, { cache: "no-store" });
  }

  close(): void {}

  protected receive(event: DiffEvent): void {
    for (const listener of this.listeners) {
      listener(event);
    }
  }

  protected makeRequest(command: DiffCommand): DiffRequest {
    return {
      id: makeRequestId(),
      version: this.version,
      ...command,
    } as DiffRequest;
  }

  protected unwrap(response: DiffResponse): DiffResult {
    if (response.error) {
      throw new DiffTransportError(response.error.code, response.error.message);
    }
    if (!response.result) {
      throw new DiffTransportError("missingResult", "Diff transport returned no result");
    }
    return response.result;
  }
}

export class FetchDiffTransport extends BaseDiffTransport {
  private readonly endpoint: string;

  constructor(endpoint: string, version: number) {
    super(version);
    this.endpoint = endpoint;
  }

  async request(command: DiffCommand): Promise<DiffResult> {
    const response = await fetch(this.endpoint, {
      method: "POST",
      cache: "no-store",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(this.makeRequest(command)),
    });
    if (!response.ok) {
      throw new DiffTransportError("requestFailed", `Diff transport request failed (${response.status})`);
    }
    return this.unwrap((await response.json()) as DiffResponse);
  }
}

export class WebKitDiffTransport extends BaseDiffTransport {
  private readonly handler: NonNullable<NonNullable<NonNullable<Window["webkit"]>["messageHandlers"]>["cmuxDiff"]>;

  constructor(
    handler: NonNullable<NonNullable<NonNullable<Window["webkit"]>["messageHandlers"]>["cmuxDiff"]>,
    version: number,
  ) {
    super(version);
    this.handler = handler;
    window.cmuxDiffBridge = { receive: (event) => this.receive(event) };
  }

  async request(command: DiffCommand): Promise<DiffResult> {
    return this.unwrap(await this.handler.postMessage(this.makeRequest(command)));
  }

  override close(): void {
    delete window.cmuxDiffBridge;
  }
}

export class WebSocketDiffTransport extends BaseDiffTransport {
  private readonly endpoint: string;
  private socket: WebSocket | null = null;
  private connecting: Promise<WebSocket> | null = null;
  private readonly pending = new Map<
    string,
    { resolve: (result: DiffResult) => void; reject: (error: Error) => void }
  >();

  constructor(endpoint: string, version: number) {
    super(version);
    this.endpoint = endpoint;
  }

  async request(command: DiffCommand): Promise<DiffResult> {
    const socket = await this.connect();
    const request = this.makeRequest(command);
    return new Promise<DiffResult>((resolve, reject) => {
      this.pending.set(request.id, { resolve, reject });
      socket.send(JSON.stringify(request));
    });
  }

  override close(): void {
    this.socket?.close();
    this.socket = null;
    this.connecting = null;
    this.rejectPending(new DiffTransportError("closed", "Diff transport closed"));
  }

  private connect(): Promise<WebSocket> {
    if (this.socket?.readyState === WebSocket.OPEN) {
      return Promise.resolve(this.socket);
    }
    if (this.connecting) {
      return this.connecting;
    }
    this.connecting = new Promise<WebSocket>((resolve, reject) => {
      const socket = new WebSocket(this.endpoint);
      socket.addEventListener("open", () => {
        this.socket = socket;
        this.connecting = null;
        resolve(socket);
      }, { once: true });
      socket.addEventListener("message", (message) => this.handleMessage(message));
      socket.addEventListener("close", () => {
        this.socket = null;
        this.connecting = null;
        this.rejectPending(new DiffTransportError("closed", "Diff transport closed"));
      });
      socket.addEventListener("error", () => {
        this.connecting = null;
        reject(new DiffTransportError("connectFailed", "Could not connect to diff transport"));
      }, { once: true });
    });
    return this.connecting;
  }

  private handleMessage(message: MessageEvent): void {
    if (typeof message.data !== "string") {
      return;
    }
    const decoded = JSON.parse(message.data) as DiffResponse | DiffEvent;
    if ("id" in decoded) {
      const pending = this.pending.get(decoded.id);
      if (!pending) {
        return;
      }
      this.pending.delete(decoded.id);
      try {
        pending.resolve(this.unwrap(decoded));
      } catch (error) {
        pending.reject(error instanceof Error ? error : new Error(String(error)));
      }
      return;
    }
    this.receive(decoded);
  }

  private rejectPending(error: Error): void {
    for (const pending of this.pending.values()) {
      pending.reject(error);
    }
    this.pending.clear();
  }
}

export function createDiffTransport(config: DiffTransportConfig | undefined): DiffTransport | null {
  if (!config) {
    return null;
  }
  const webKitHandler = window.webkit?.messageHandlers?.cmuxDiff;
  if (config.kind === "webKit" && webKitHandler) {
    return new WebKitDiffTransport(webKitHandler, config.protocolVersion);
  }
  if (config.kind === "webSocket") {
    return new WebSocketDiffTransport(config.endpoint, config.protocolVersion);
  }
  if (config.kind === "fetch") {
    if (!supportsFetchTransport(window.location.protocol)) {
      return null;
    }
    return new FetchDiffTransport(config.endpoint, config.protocolVersion);
  }
  return null;
}

export function supportsFetchTransport(protocol: string): boolean {
  return protocol === "http:" || protocol === "https:";
}

export class DiffTransportError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "DiffTransportError";
    this.code = code;
  }
}

function makeRequestId(): string {
  return typeof crypto.randomUUID === "function"
    ? crypto.randomUUID()
    : `diff-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}
