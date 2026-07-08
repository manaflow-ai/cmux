import { Buffer } from "node:buffer";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import {
  AttachEvent,
  ClientOptions,
  EmptyResult,
  IdentifyResult,
  JsonObject,
  NewBrowserTabOptions,
  NewScreenOptions,
  NewTabOptions,
  NewWorkspaceOptions,
  ReadScreenResult,
  SelectOptions,
  SelectTabOptions,
  SendOptions,
  SplitOptions,
  SubscribeEvent,
  SurfaceResult,
  Tree,
  VtStateResult,
} from "./types.js";
import { CmuxCommandError, CmuxConnectionError, CmuxProtocolError, CmuxTimeoutError } from "./errors.js";

type ResponseEnvelope = { id?: unknown; ok: true; data: unknown } | { id?: unknown; ok: false; error: string };
type EventObject = { event: string; [key: string]: unknown };

export function defaultSocketPath(session = "main"): string {
  const base = process.env.TMPDIR || os.tmpdir();
  return path.join(base, `cmux-mux-${process.getuid?.() ?? 0}`, `${session}.sock`);
}

class JsonLineConnection {
  private socket: net.Socket;
  private buffer = "";
  private lines: string[] = [];
  private waiters: Array<{
    active: boolean;
    resolve: (line: string) => void;
    reject: (error: Error) => void;
  }> = [];
  private closedError: Error | null = null;

  private constructor(socket: net.Socket) {
    this.socket = socket;
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => this.onData(chunk));
    socket.on("error", (err: Error) => this.closeWith(new CmuxConnectionError(`socket error: ${err.message}`)));
    socket.on("close", () => this.closeWith(new CmuxConnectionError("session socket closed")));
  }

  static connect(socketPath: string): Promise<JsonLineConnection> {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ path: socketPath });
      socket.once("connect", () => resolve(new JsonLineConnection(socket)));
      socket.once("error", (err: Error) => reject(new CmuxConnectionError(`cannot connect to session socket ${socketPath}: ${err.message}`)));
    });
  }

  send(value: JsonObject): Promise<void> {
    const line = `${JSON.stringify(value)}\n`;
    return new Promise((resolve, reject) => {
      this.socket.write(line, "utf8", (err?: Error | null) => {
        if (err) reject(new CmuxConnectionError(`socket write failed: ${err.message}`));
        else resolve();
      });
    });
  }

  async recv(timeoutMs: number): Promise<JsonObject> {
    const pending = this.nextLine();
    const line = await withTimeout(pending.promise, timeoutMs, "session did not respond", pending.cancel);
    try {
      const value = JSON.parse(line) as unknown;
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new CmuxProtocolError("server sent non-object JSON line");
      }
      return value as JsonObject;
    } catch (err) {
      if (err instanceof CmuxProtocolError) throw err;
      throw new CmuxProtocolError(`bad JSON from server: ${(err as Error).message}`);
    }
  }

  close(): void {
    this.socket.destroy();
  }

  private nextLine(): { promise: Promise<string>; cancel: () => void } {
    if (this.lines.length > 0) {
      return { promise: Promise.resolve(this.lines.shift()!), cancel: () => undefined };
    }
    if (this.closedError) {
      return { promise: Promise.reject(this.closedError), cancel: () => undefined };
    }
    const waiter: {
      active: boolean;
      resolve: (line: string) => void;
      reject: (error: Error) => void;
    } = {
      active: true,
      resolve: (_line: string) => {},
      reject: (_error: Error) => {},
    };
    const promise = new Promise<string>((resolve, reject) => {
      waiter.resolve = resolve;
      waiter.reject = reject;
    });
    this.waiters.push(waiter);
    return {
      promise,
      cancel: () => {
        waiter.active = false;
      },
    };
  }

  private onData(chunk: string): void {
    this.buffer += chunk;
    for (;;) {
      const index = this.buffer.indexOf("\n");
      if (index < 0) break;
      const line = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + 1);
      if (line.trim() === "") continue;
      let delivered = false;
      while (this.waiters.length > 0) {
        const waiter = this.waiters.shift()!;
        if (!waiter.active) continue;
        waiter.resolve(line);
        delivered = true;
        break;
      }
      if (!delivered) this.lines.push(line);
    }
  }

  private closeWith(error: Error): void {
    if (this.closedError) return;
    this.closedError = error;
    while (this.waiters.length > 0) {
      const waiter = this.waiters.shift()!;
      if (waiter.active) waiter.reject(error);
    }
  }
}

export class CmuxStream<T extends EventObject> implements AsyncIterable<T> {
  private readonly buffered: T[] = [];
  private closed = false;

  private constructor(
    private readonly conn: JsonLineConnection,
    private readonly timeoutMs: number,
    buffered: T[],
  ) {
    this.buffered = buffered;
  }

  static async open<T extends EventObject>(
    socketPath: string,
    timeoutMs: number,
    request: JsonObject,
  ): Promise<CmuxStream<T>> {
    const conn = await JsonLineConnection.connect(socketPath);
    await conn.send(request);
    const requestId = request.id;
    const buffered: T[] = [];
    for (;;) {
      const value = await conn.recv(timeoutMs);
      if (typeof value.event === "string") {
        buffered.push(value as T);
        continue;
      }
      if (value.id !== requestId) continue;
      const response = value as ResponseEnvelope;
      if (response.ok === true) return new CmuxStream(conn, timeoutMs, buffered);
      throw new CmuxCommandError(response.error || "unknown error", response.id, response);
    }
  }

  async next(timeoutMs = this.timeoutMs): Promise<T> {
    if (this.closed) throw new CmuxConnectionError("stream is closed");
    if (this.buffered.length > 0) return this.buffered.shift()!;
    for (;;) {
      const value = await this.conn.recv(timeoutMs);
      if (typeof value.event !== "string") continue;
      const event = value as T;
      if (event.event === "detached") this.close();
      return event;
    }
  }

  close(): void {
    if (!this.closed) {
      this.closed = true;
      this.conn.close();
    }
  }

  async *[Symbol.asyncIterator](): AsyncIterator<T> {
    while (!this.closed) {
      yield await this.next();
    }
  }
}

export class CmuxClient {
  readonly socketPath: string;
  readonly timeoutMs: number;
  readonly allowProtocolV6Attach: boolean;
  private connPromise: Promise<JsonLineConnection>;
  private nextRequestId = 1;
  private protocol: number | null = null;

  constructor(options: ClientOptions = {}) {
    this.socketPath = options.socketPath ?? defaultSocketPath(options.session ?? "main");
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.allowProtocolV6Attach = options.allowProtocolV6Attach ?? true;
    this.connPromise = JsonLineConnection.connect(this.socketPath);
  }

  async close(): Promise<void> {
    const conn = await this.connPromise;
    conn.close();
  }

  async sendRaw(obj: JsonObject): Promise<ResponseEnvelope> {
    const payload = { ...obj };
    if (!("id" in payload)) payload.id = this.nextId();
    const requestId = payload.id;
    const conn = await this.connPromise;
    await conn.send(payload);
    for (;;) {
      const response = await conn.recv(this.timeoutMs);
      if (typeof response.event === "string") continue;
      if (response.id !== requestId && response.id !== undefined) continue;
      return response as ResponseEnvelope;
    }
  }

  async request(cmd: string, params: JsonObject = {}): Promise<unknown> {
    const response = await this.sendRaw({ id: this.nextId(), cmd, ...dropUndefined(params) });
    if (response.ok === true) return response.data;
    throw new CmuxCommandError(response.error || "unknown error", response.id, response);
  }

  async identify(): Promise<IdentifyResult> {
    const result = await this.request("identify") as IdentifyResult;
    this.protocol = result.protocol;
    return result;
  }

  async listWorkspaces(): Promise<Tree> { return this.request("list-workspaces") as Promise<Tree>; }
  async send(surface: number, options: SendOptions = {}): Promise<EmptyResult> {
    const bytes = options.bytes instanceof Uint8Array ? Buffer.from(options.bytes).toString("base64") : options.bytes;
    await this.request("send", dropUndefined({ surface, text: options.text, bytes }));
    return {};
  }
  async readScreen(surface: number): Promise<ReadScreenResult> { return this.request("read-screen", { surface }) as Promise<ReadScreenResult>; }
  async vtState(surface: number): Promise<VtStateResult> { return this.request("vt-state", { surface }) as Promise<VtStateResult>; }
  async newTab(options: NewTabOptions = {}): Promise<SurfaceResult> { return this.request("new-tab", options as JsonObject) as Promise<SurfaceResult>; }
  async newBrowserTab(url: string, options: NewBrowserTabOptions = {}): Promise<SurfaceResult> { return this.request("new-browser-tab", dropUndefined({ url, ...options })) as Promise<SurfaceResult>; }
  async newWorkspace(options: NewWorkspaceOptions = {}): Promise<SurfaceResult> { return this.request("new-workspace", options as JsonObject) as Promise<SurfaceResult>; }
  async newScreen(options: NewScreenOptions = {}): Promise<SurfaceResult> { return this.request("new-screen", options as JsonObject) as Promise<SurfaceResult>; }
  async split(pane: number, dir: "right" | "down", options: SplitOptions = {}): Promise<SurfaceResult> { return this.request("split", dropUndefined({ pane, dir, ...options })) as Promise<SurfaceResult>; }
  async setRatio(pane: number, dir: "right" | "down", ratio: number): Promise<EmptyResult> { await this.request("set-ratio", { pane, dir, ratio }); return {}; }
  async setDefaultColors(fg?: string, bg?: string): Promise<EmptyResult> { await this.request("set-default-colors", dropUndefined({ fg, bg })); return {}; }
  async closeSurface(surface: number): Promise<EmptyResult> { await this.request("close-surface", { surface }); return {}; }
  async closePane(pane: number): Promise<EmptyResult> { await this.request("close-pane", { pane }); return {}; }
  async closeScreen(screen: number): Promise<EmptyResult> { await this.request("close-screen", { screen }); return {}; }
  async closeWorkspace(workspace: number): Promise<EmptyResult> { await this.request("close-workspace", { workspace }); return {}; }
  async renamePane(pane: number, name: string): Promise<EmptyResult> { await this.request("rename-pane", { pane, name }); return {}; }
  async renameSurface(surface: number, name: string): Promise<EmptyResult> { await this.request("rename-surface", { surface, name }); return {}; }
  async renameScreen(screen: number, name: string): Promise<EmptyResult> { await this.request("rename-screen", { screen, name }); return {}; }
  async renameWorkspace(workspace: number, name: string): Promise<EmptyResult> { await this.request("rename-workspace", { workspace, name }); return {}; }
  async resizeSurface(surface: number, cols: number, rows: number): Promise<EmptyResult> { await this.request("resize-surface", { surface, cols, rows }); return {}; }
  async focusPane(pane: number): Promise<EmptyResult> { await this.request("focus-pane", { pane }); return {}; }
  async selectTab(options: SelectTabOptions = {}): Promise<EmptyResult> { await this.request("select-tab", options as JsonObject); return {}; }
  async selectScreen(options: SelectOptions = {}): Promise<EmptyResult> { await this.request("select-screen", options as JsonObject); return {}; }
  async selectWorkspace(options: SelectOptions = {}): Promise<EmptyResult> { await this.request("select-workspace", options as JsonObject); return {}; }
  async moveTab(surface: number, pane: number, index: number): Promise<EmptyResult> { await this.request("move-tab", { surface, pane, index }); return {}; }
  async moveWorkspace(workspace: number, index: number): Promise<EmptyResult> { await this.request("move-workspace", { workspace, index }); return {}; }
  async scrollSurface(surface: number, delta: number): Promise<EmptyResult> { await this.request("scroll-surface", { surface, delta }); return {}; }

  async subscribe(): Promise<CmuxStream<SubscribeEvent>> {
    return CmuxStream.open<SubscribeEvent>(this.socketPath, this.timeoutMs, { id: this.nextId(), cmd: "subscribe" });
  }

  async attachSurface(surface: number): Promise<CmuxStream<AttachEvent>> {
    const protocol = this.protocol ?? (await this.identify()).protocol;
    if (protocol > 6 || (protocol > 5 && !this.allowProtocolV6Attach)) {
      throw new CmuxProtocolError(`unsupported attach protocol ${protocol}`);
    }
    return CmuxStream.open<AttachEvent>(this.socketPath, this.timeoutMs, { id: this.nextId(), cmd: "attach-surface", surface });
  }

  private nextId(): number {
    return this.nextRequestId++;
  }
}

function dropUndefined(value: Record<string, unknown>): JsonObject {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as JsonObject;
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string, onTimeout?: () => void): Promise<T> {
  let timer: NodeJS.Timeout;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      onTimeout?.();
      reject(new CmuxTimeoutError(message));
    }, timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer!));
}
