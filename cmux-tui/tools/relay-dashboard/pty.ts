// Opens a PTY on a remote cmux-tui daemon through the headless relay client's
// local mux socket and streams raw bytes both ways. The socket speaks the
// session's newline-delimited JSON protocol (spec/commands.md): one workspace
// per browser tab, `attach-surface` for output, `send` for input,
// `resize-surface` + `set-client-sizing` for geometry authority.
import { connect, type Socket } from "node:net";

export type PtyHandle = {
  write(bytes: Uint8Array): void;
  resize(cols: number, rows: number): void;
  close(): void;
};

export type OpenPtyOptions = {
  tui: string;
  socket: string;
  cols: number;
  rows: number;
  onOutput: (bytes: Uint8Array) => void;
  onExit: (why: string) => void;
};

type Pending = { resolve: (data: any) => void; reject: (error: Error) => void };

class MuxSocket {
  private sock: Socket;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, Pending>();
  onEvent: (event: any) => void = () => {};
  onClose: (why: string) => void = () => {};

  constructor(path: string) {
    this.sock = connect(path);
    this.sock.setNoDelay(true);
    this.sock.on("data", (chunk) => this.feed(chunk.toString("utf8")));
    this.sock.on("error", (error) => this.fail(`socket error: ${error.message}`));
    this.sock.on("close", () => this.fail("socket closed"));
  }

  ready(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.sock.once("connect", () => resolve());
      this.sock.once("error", (error) => reject(error));
    });
  }

  request(cmd: string, params: Record<string, unknown> = {}): Promise<any> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.sock.write(JSON.stringify({ id, cmd, ...params }) + "\n");
    });
  }

  private feed(text: string) {
    this.buffer += text;
    let index: number;
    while ((index = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + 1);
      if (!line.trim()) continue;
      let msg: any;
      try { msg = JSON.parse(line); } catch { continue; }
      if (typeof msg.id === "number" && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id)!;
        this.pending.delete(msg.id);
        if (msg.ok) p.resolve(msg.data);
        else p.reject(new Error(typeof msg.error === "string" ? msg.error : JSON.stringify(msg.error ?? msg)));
      } else if (msg.event) {
        this.onEvent(msg);
      }
    }
  }

  private fail(why: string) {
    for (const p of this.pending.values()) p.reject(new Error(why));
    this.pending.clear();
    this.onClose(why);
  }

  end() { this.sock.end(); this.sock.destroy(); }
}

export async function openPty(options: OpenPtyOptions): Promise<PtyHandle> {
  const mux = new MuxSocket(options.socket);
  await mux.ready();
  let surface: number | null = null;
  let closed = false;

  mux.onEvent = (event) => {
    if (surface !== null && event.surface !== surface) return;
    switch (event.event) {
      case "vt-state":
      case "output":
        if (typeof event.data === "string" && event.data.length) options.onOutput(Buffer.from(event.data, "base64"));
        break;
      case "resized":
        // v6 attach contract: a resized event carries a fresh replay; the
        // browser terminal is resized by the same client, so just replay.
        if (typeof event.data === "string" && event.data.length) options.onOutput(Buffer.from(event.data, "base64"));
        break;
      case "detached":
        finish("surface detached");
        break;
      default:
        break;
    }
  };
  mux.onClose = (why) => finish(why);

  function finish(why: string) {
    if (closed) return;
    closed = true;
    options.onExit(why);
    mux.end();
  }

  try {
    const identify = await mux.request("identify").catch(() => null);
    const capabilities: string[] = identify?.capabilities ?? [];
    const created = await mux.request("new-workspace", {
      name: `dashboard ${new Date().toISOString().slice(11, 19)}`,
      cols: options.cols,
      rows: options.rows,
    });
    surface = created.surface;
    const attachParams: Record<string, unknown> = { surface };
    if (capabilities.includes("attach-initial-size")) { attachParams.cols = options.cols; attachParams.rows = options.rows; }
    await mux.request("attach-surface", attachParams);
    await mux.request("resize-surface", { surface, cols: options.cols, rows: options.rows });
    await mux.request("set-client-sizing", { surface, enabled: true, exclusive: true }).catch((error) => {
      console.log(`[pty] geometry authority not granted: ${error.message}`);
    });
  } catch (error) {
    finish(`setup failed: ${(error as Error).message}`);
    throw error;
  }

  return {
    write(bytes) {
      if (closed || surface === null) return;
      mux.request("send", { surface, bytes: Buffer.from(bytes).toString("base64") }).catch((error) => finish(`send failed: ${error.message}`));
    },
    resize(cols, rows) {
      if (closed || surface === null) return;
      mux.request("resize-surface", { surface, cols, rows }).catch(() => { /* passive report */ });
    },
    close() {
      if (closed) return;
      const id = surface;
      if (id !== null) mux.request("close-surface", { surface: id }).catch(() => { /* already gone */ }).finally(() => finish("closed by browser"));
      else finish("closed by browser");
    },
  };
}
