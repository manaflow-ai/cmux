// term.* served from the cmux-next daemon: the phone sees the Mac's terminal
// tabs and types into them. Each phone attachment gets its own daemon
// connection with a bytes-mode attach (raw VT for the phone's Ghostty) whose
// view does not count toward sizing, so the phone never resizes the Mac's
// grid; the phone renders at the Mac's grid (term.updated carries it).

import { EventEmitter } from "node:events";
import { FrameKind, type Terminal } from "../protocol.ts";
import { RpcError, type ClientSession, type RpcServer, num, optStr, str } from "../rpc/index.ts";
import type { Logger } from "../util.ts";
import { DaemonConn } from "./daemonConn.ts";

interface TabInfo {
  surface: number;
  kind: string;
  name?: string | null;
  title?: string | null;
  size?: { cols: number; rows: number };
  cwd?: string | null;
  dead?: boolean;
}

/** All terminal (pty) tabs in a list-workspaces tree. */
export function ptyTabs(tree: unknown): TabInfo[] {
  const out: TabInfo[] = [];
  const seen = new Set<number>();
  const walk = (v: unknown) => {
    if (!v || typeof v !== "object") return;
    if (Array.isArray(v)) {
      for (const x of v) walk(x);
      return;
    }
    const o = v as Record<string, unknown>;
    if (typeof o.surface === "number" && typeof o.kind === "string") {
      if (o.kind === "pty" && !seen.has(o.surface)) {
        seen.add(o.surface);
        out.push(o as unknown as TabInfo);
      }
      return;
    }
    for (const x of Object.values(o)) walk(x);
  };
  walk(tree);
  return out;
}

export const terminalId = (surface: number) => `s${surface}`;

export function parseTerminalId(id: string): number {
  const m = /^s(\d{1,10})$/.exec(id);
  if (!m) throw new RpcError("not_found", `terminal ${id} not found`);
  return Number(m[1]);
}

export interface DaemonTerminalsEvents {
  event: [topic: string, payload: unknown];
}

const RIS = Buffer.from("\x1bc");

export class DaemonTerminals extends EventEmitter<DaemonTerminalsEvents> {
  private control: DaemonConn | null = null;
  private connecting: Promise<DaemonConn> | null = null;
  private readonly terminals = new Map<number, Terminal>();
  private refreshTimer: NodeJS.Timeout | null = null;
  private readonly log: Logger;

  constructor(
    private readonly socketPath: () => string | null,
    opts: { log?: Logger } = {},
  ) {
    super();
    this.log = opts.log ?? (() => {});
  }

  private async conn(): Promise<DaemonConn> {
    if (this.control && !this.control.isClosed) return this.control;
    if (!this.connecting) {
      this.connecting = (async () => {
        const path = this.socketPath();
        if (!path) throw new RpcError("unavailable", "the cmux-next app is not running on this Mac");
        const c = await DaemonConn.open(path);
        c.on("event", (name, p) => this.onEvent(name, p));
        c.on("close", (reason) => {
          this.log(`daemon control connection closed: ${reason}`);
          if (this.control === c) this.control = null;
        });
        await c.request("subscribe", { tree_events: "deltas" });
        this.control = c;
        await this.refresh();
        return c;
      })().finally(() => {
        this.connecting = null;
      });
    }
    return this.connecting;
  }

  shutdown(): void {
    this.control?.close();
  }

  private onEvent(name: string, _p: any): void {
    switch (name) {
      case "tab-added":
      case "tab-closed":
      case "tab-renamed":
      case "tab-changed":
      case "title-changed":
      case "surface-exited":
      case "surface-resized":
      case "tree-changed":
      case "workspace-changed":
        this.scheduleRefresh();
        break;
    }
  }

  private scheduleRefresh(): void {
    if (this.refreshTimer) return;
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = null;
      void this.refresh().catch((err) => this.log(`terminal refresh failed: ${(err as Error).message}`));
    }, 80);
    this.refreshTimer.unref?.();
  }

  /** Re-reads the tree and emits term.updated / term.exited for changes. */
  async refresh(): Promise<void> {
    const c = this.control;
    if (!c) return;
    const tree = await c.request("list-workspaces");
    const seen = new Set<number>();
    for (const tab of ptyTabs(tree)) {
      seen.add(tab.surface);
      const prev = this.terminals.get(tab.surface);
      const next: Terminal = {
        id: terminalId(tab.surface),
        title: tab.name || tab.title || "Terminal",
        cwd: tab.cwd ?? "",
        cols: tab.size?.cols ?? prev?.cols ?? 80,
        rows: tab.size?.rows ?? prev?.rows ?? 24,
        running: !tab.dead,
        createdAt: prev?.createdAt ?? Date.now(),
      };
      this.terminals.set(tab.surface, next);
      if (!prev || JSON.stringify(prev) !== JSON.stringify(next)) this.emit("event", "term.updated", { terminal: { ...next } });
      if (prev?.running && !next.running) this.emit("event", "term.exited", { terminalId: next.id, code: 0 });
    }
    for (const [surface, t] of this.terminals) {
      if (seen.has(surface)) continue;
      this.terminals.delete(surface);
      if (t.running) this.emit("event", "term.exited", { terminalId: t.id, code: 0 });
    }
  }

  async list(): Promise<Terminal[]> {
    await this.conn();
    await this.refresh();
    return [...this.terminals.values()].map((t) => ({ ...t }));
  }

  private async known(id: string): Promise<{ surface: number; t: Terminal }> {
    const surface = parseTerminalId(id);
    await this.conn();
    if (!this.terminals.has(surface)) await this.refresh();
    const t = this.terminals.get(surface);
    if (!t) throw new RpcError("not_found", `terminal ${id} not found`);
    return { surface, t };
  }

  async create(): Promise<Terminal> {
    const c = await this.conn();
    const res = await c.request<{ surface: number }>("new-tab", {});
    await this.refresh();
    const t = this.terminals.get(res.surface);
    if (!t) throw new RpcError("internal", "the new terminal did not appear");
    return { ...t };
  }

  async close(id: string): Promise<void> {
    const { surface } = await this.known(id);
    await (await this.conn()).request("close-surface", { surface });
  }

  async rename(id: string, title: string): Promise<void> {
    const { surface } = await this.known(id);
    await (await this.conn()).request("rename-surface", { surface, name: title });
  }

  /**
   * Opens a dedicated daemon connection streaming one terminal to `sink`.
   * Returns the input writer and a disposer (closing the connection drops
   * the daemon lease).
   */
  async attach(id: string, sink: (data: Uint8Array) => void): Promise<{ terminal: Terminal; write: (data: Uint8Array) => void; dispose: () => void }> {
    const { surface, t } = await this.known(id);
    const path = this.socketPath();
    if (!path) throw new RpcError("unavailable", "the cmux-next app is not running on this Mac");
    const stream = await DaemonConn.open(path);
    let disposed = false;
    const onGrid = (cols: number, rows: number) => {
      const cur = this.terminals.get(surface);
      if (!cur || (cur.cols === cols && cur.rows === rows)) return;
      cur.cols = cols;
      cur.rows = rows;
      this.emit("event", "term.updated", { terminal: { ...cur } });
    };
    stream.on("event", (name, p) => {
      if (disposed || p.surface !== surface) return;
      switch (name) {
        case "vt-state":
          if (typeof p.cols === "number" && typeof p.rows === "number") onGrid(p.cols, p.rows);
          if (typeof p.data === "string") sink(Buffer.from(p.data, "base64"));
          break;
        case "output":
          if (typeof p.data === "string") sink(Buffer.from(p.data, "base64"));
          break;
        case "resized": {
          // A full replacement replay: reset the phone's screen first.
          if (typeof p.cols === "number" && typeof p.rows === "number") onGrid(p.cols, p.rows);
          const replay = typeof p.replay === "string" ? p.replay : typeof p.data === "string" ? p.data : null;
          if (replay) {
            sink(RIS);
            sink(Buffer.from(replay, "base64"));
          }
          break;
        }
        case "size-state":
          if (p.state && typeof p.state.cols === "number") onGrid(p.state.cols, p.state.rows);
          break;
        case "detached":
          stream.close();
          break;
      }
    });
    let lease: string | undefined;
    try {
      const res = await stream.request<{ lease?: string }>("attach-surface", { surface, mode: "bytes" });
      lease = res.lease;
      // The phone types into the Mac's terminal but never takes its grid.
      await stream.request("set-size-counts", { surface, counts: false });
    } catch (err) {
      stream.close();
      throw err instanceof RpcError ? err : new RpcError("unavailable", (err as Error).message);
    }
    return {
      terminal: { ...(this.terminals.get(surface) ?? t) },
      write: (data) => {
        if (disposed) return;
        stream.request("send", { surface, bytes: Buffer.from(data).toString("base64") }).catch((err) => this.log(`send to ${id} failed: ${(err as Error).message}`));
      },
      dispose: () => {
        if (disposed) return;
        disposed = true;
        if (lease) void stream.request("detach-attached-view", { surface, lease }, 2_000).catch(() => {}).finally(() => stream.close());
        else stream.close();
      },
    };
  }

  register(server: RpcServer): void {
    this.on("event", (topic, payload) => server.broadcast(topic, payload));
    server.register("term.list", async () => ({ terminals: await this.list() }));
    server.register("term.create", async (p) => {
      // Never let the phone choose where or what a Mac terminal runs.
      if (optStr(p, "cwd") !== undefined) throw new RpcError("unsupported", "a working directory cannot be chosen from the phone; the Mac picks it");
      return { terminal: await this.create() };
    });
    server.register("term.attach", async (p, session: ClientSession) => {
      const terminalIdParam = str(p, "terminalId");
      let streamId = 0;
      const early: Uint8Array[] = [];
      let ready = false;
      const att = await this.attach(terminalIdParam, (data) => {
        if (!ready) early.push(Uint8Array.from(data));
        else session.sendFrame(FrameKind.termOutput, streamId, data);
      });
      streamId = session.addStream({ kind: "term", target: terminalIdParam, onInput: (d) => att.write(d), dispose: () => att.dispose() });
      // Replay after the response so the phone knows the stream id first.
      setImmediate(() => {
        ready = true;
        for (const d of early) session.sendFrame(FrameKind.termOutput, streamId, d);
        early.length = 0;
      });
      return { streamId, terminal: att.terminal };
    });
    server.register("term.detach", (p, session) => {
      session.removeStream(num(p, "streamId"));
      return {};
    });
    // The Mac owns the grid; the phone renders at it (term.updated reports it).
    server.register("term.resize", async (p) => {
      const { t } = await this.known(str(p, "terminalId"));
      this.emit("event", "term.updated", { terminal: { ...t } });
      return {};
    });
    server.register("term.close", async (p) => {
      const id = str(p, "terminalId");
      await this.close(id);
      for (const s of server.sessions) s.removeStreamsFor("term", id);
      return {};
    });
    server.register("term.rename", async (p) => {
      await this.rename(str(p, "terminalId"), str(p, "title"));
      return {};
    });
  }
}
