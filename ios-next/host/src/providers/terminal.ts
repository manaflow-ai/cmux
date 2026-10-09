// Real PTYs for the phone (PROTOCOL.md §4 terminals). Each terminal keeps a
// 2 MiB scrollback ring that is replayed to every new attachment.

import { EventEmitter } from "node:events";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename } from "node:path";
import * as pty from "node-pty";
import { FrameKind, type Terminal } from "../protocol.ts";
import { RpcError, type ClientSession, type RpcServer, num, optStr, str } from "../rpc/index.ts";
import { childEnv, newId } from "../util.ts";

export const SCROLLBACK_BYTES = 2 * 1024 * 1024;

/** Byte ring buffer that drops the oldest output once full. */
export class ScrollbackRing {
  private chunks: Buffer[] = [];
  private size = 0;

  constructor(private readonly capacity = SCROLLBACK_BYTES) {}

  append(data: Buffer): void {
    if (data.byteLength >= this.capacity) {
      this.chunks = [Buffer.from(data.subarray(data.byteLength - this.capacity))];
      this.size = this.capacity;
      return;
    }
    this.chunks.push(data);
    this.size += data.byteLength;
    while (this.size > this.capacity) {
      const head = this.chunks[0]!;
      const over = this.size - this.capacity;
      if (head.byteLength <= over) {
        this.chunks.shift();
        this.size -= head.byteLength;
      } else {
        this.chunks[0] = head.subarray(over);
        this.size -= over;
      }
    }
  }

  snapshot(): Buffer {
    if (this.chunks.length > 1) this.chunks = [Buffer.concat(this.chunks)];
    return this.chunks[0] ?? Buffer.alloc(0);
  }

  get byteLength(): number {
    return this.size;
  }
}

interface Attachment {
  sink: (data: Uint8Array) => void;
}

export interface TerminalOptions {
  shell?: string;
  args?: string[];
  env?: Record<string, string>;
}

class TerminalInstance {
  readonly info: Terminal;
  readonly scrollback = new ScrollbackRing();
  readonly attachments = new Set<Attachment>();
  private proc: pty.IPty | null;
  exitCode: number | null = null;

  constructor(
    cols: number,
    rows: number,
    cwd: string,
    opts: TerminalOptions,
    onExit: (code: number) => void,
  ) {
    const shell = opts.shell ?? process.env.SHELL ?? "/bin/zsh";
    this.info = {
      id: newId("t"),
      title: basename(shell),
      cwd,
      cols,
      rows,
      running: true,
      createdAt: Date.now(),
    };
    const env = childEnv({
      TERM: "xterm-256color",
      COLORTERM: "truecolor",
      LANG: process.env.LANG ?? "en_US.UTF-8",
      TERM_PROGRAM: "cmux-next",
      ...opts.env,
    });
    delete env.CMUX_NEXT_TOKEN;
    this.proc = pty.spawn(shell, opts.args ?? ["-l"], {
      name: "xterm-256color",
      cols,
      rows,
      cwd,
      env: env as Record<string, string>,
      // Buffers, not strings, so multi-byte UTF-8 is never split or re-encoded.
      encoding: null as unknown as string,
    });
    this.proc.onData((data: string | Buffer) => {
      const buf = typeof data === "string" ? Buffer.from(data, "utf8") : data;
      this.scrollback.append(buf);
      for (const a of this.attachments) a.sink(buf);
    });
    this.proc.onExit(({ exitCode }) => {
      this.info.running = false;
      this.exitCode = exitCode;
      this.proc = null;
      onExit(exitCode);
    });
  }

  write(data: Uint8Array): void {
    this.proc?.write(Buffer.from(data.buffer, data.byteOffset, data.byteLength) as unknown as string);
  }

  resize(cols: number, rows: number): void {
    cols = Math.max(2, Math.min(1000, Math.floor(cols)));
    rows = Math.max(1, Math.min(1000, Math.floor(rows)));
    this.info.cols = cols;
    this.info.rows = rows;
    try {
      this.proc?.resize(cols, rows);
    } catch {}
  }

  kill(): void {
    try {
      this.proc?.kill();
    } catch {}
  }
}

export interface TerminalProviderEvents {
  event: [topic: string, payload: unknown];
}

export class TerminalProvider extends EventEmitter<TerminalProviderEvents> {
  private readonly terminals = new Map<string, TerminalInstance>();

  constructor(private readonly opts: TerminalOptions = {}) {
    super();
  }

  list(): Terminal[] {
    return [...this.terminals.values()].map((t) => ({ ...t.info }));
  }

  create(cols: number, rows: number, cwd?: string): Terminal {
    const dir = cwd && existsSync(cwd) ? cwd : homedir();
    const t: TerminalInstance = new TerminalInstance(cols, rows, dir, this.opts, (code) => {
      this.emit("event", "term.exited", { terminalId: t.info.id, code });
      this.emit("event", "term.updated", { terminal: { ...t.info } });
    });
    this.terminals.set(t.info.id, t);
    this.emit("event", "term.updated", { terminal: { ...t.info } });
    return { ...t.info };
  }

  get(id: string): TerminalInstance {
    const t = this.terminals.get(id);
    if (!t) throw new RpcError("not_found", `terminal ${id} not found`);
    return t;
  }

  /** Replays scrollback then streams live output to sink. Returns detach. */
  attach(id: string, cols: number, rows: number, sink: (data: Uint8Array) => void): () => void {
    const t = this.get(id);
    const replay = t.scrollback.snapshot();
    if (replay.byteLength > 0) sink(replay);
    const a: Attachment = { sink };
    t.attachments.add(a);
    if (cols > 0 && rows > 0 && (cols !== t.info.cols || rows !== t.info.rows)) {
      t.resize(cols, rows);
      this.emit("event", "term.updated", { terminal: { ...t.info } });
    }
    return () => t.attachments.delete(a);
  }

  write(id: string, data: Uint8Array): void {
    this.get(id).write(data);
  }

  resize(id: string, cols: number, rows: number): void {
    const t = this.get(id);
    t.resize(cols, rows);
    this.emit("event", "term.updated", { terminal: { ...t.info } });
  }

  rename(id: string, title: string): void {
    const t = this.get(id);
    t.info.title = title;
    this.emit("event", "term.updated", { terminal: { ...t.info } });
  }

  close(id: string): void {
    const t = this.get(id);
    t.kill();
    this.terminals.delete(id);
    t.attachments.clear();
  }

  closeAll(): void {
    for (const id of [...this.terminals.keys()]) this.close(id);
  }

  register(server: RpcServer): void {
    this.on("event", (topic, payload) => server.broadcast(topic, payload));
    server.register("term.list", () => ({ terminals: this.list() }));
    server.register("term.create", (p) => ({
      terminal: this.create(num(p, "cols", 80), num(p, "rows", 24), optStr(p, "cwd")),
    }));
    server.register("term.attach", (p, session: ClientSession) => {
      const terminalId = str(p, "terminalId");
      const t = this.get(terminalId);
      let detach: () => void = () => {};
      const streamId = session.addStream({
        kind: "term",
        target: terminalId,
        onInput: (data) => t.write(data),
        dispose: () => detach(),
      });
      // Reply first so the client knows the streamId before replay frames
      // arrive; the control and interactive lanes are independent, so the
      // client must also buffer frames for unknown stream ids briefly.
      setImmediate(() => {
        if (!session.streams.has(streamId)) return;
        detach = this.attach(terminalId, num(p, "cols", 0), num(p, "rows", 0), (data) =>
          session.sendFrame(FrameKind.termOutput, streamId, data),
        );
      });
      return { streamId, terminal: { ...t.info } };
    });
    server.register("term.detach", (p, session) => {
      const streamId = num(p, "streamId");
      session.removeStream(streamId);
      return {};
    });
    server.register("term.resize", (p) => {
      this.resize(str(p, "terminalId"), num(p, "cols"), num(p, "rows"));
      return {};
    });
    server.register("term.close", (p) => {
      const id = str(p, "terminalId");
      this.close(id);
      for (const s of server.sessions) s.removeStreamsFor("term", id);
      return {};
    });
    server.register("term.rename", (p) => {
      this.rename(str(p, "terminalId"), str(p, "title"));
      return {};
    });
  }
}
