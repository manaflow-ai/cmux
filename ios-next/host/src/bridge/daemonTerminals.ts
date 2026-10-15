// term.* served from the cmux-next daemon: the phone sees the Mac's terminal
// tabs and types into them. Each phone attachment gets its own daemon
// connection with a bytes-mode attach (raw VT for the phone's Ghostty). For a
// terminal opened on the Mac that view does not count toward sizing, so the
// phone never resizes it; the phone renders at the Mac's grid (term.updated
// carries it). A terminal the phone created is sized by the phone: the tab
// opens at the phone's grid and the phone's view counts (the daemon's
// `latest` policy: whichever side was active last sets the grid).

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

/** Daemon errors meaning the surface or terminal is gone. */
export function isGoneError(message: string): boolean {
  return /unknown (surface|terminal|tab)|(surface|terminal|tab) .*(not found|does not exist|disappeared|is dead)|no such (surface|terminal)/i.test(message);
}

export function parseTerminalId(id: string): number {
  const m = /^s(\d{1,10})$/.exec(id);
  if (!m) throw new RpcError("not_found", `terminal ${id} not found`);
  return Number(m[1]);
}

export interface DaemonTerminalsEvents {
  event: [topic: string, payload: unknown];
}

const RIS = Buffer.from("\x1bc");

/** term.create params a mirrored terminal accepts (cwd is refused above). */
const TERM_CREATE_PARAMS = new Set(["cols", "rows", "cwd"]);

/** A phone grid, or undefined when absent or out of range. */
export function phoneGrid(cols: unknown, rows: unknown): { cols: number; rows: number } | undefined {
  const ok = (v: unknown) => typeof v === "number" && Number.isInteger(v) && v >= 2 && v <= 1000;
  return ok(cols) && ok(rows) ? { cols: cols as number, rows: rows as number } : undefined;
}

export class DaemonTerminals extends EventEmitter<DaemonTerminalsEvents> {
  private control: DaemonConn | null = null;
  private connecting: Promise<DaemonConn> | null = null;
  private readonly terminals = new Map<number, Terminal>();
  private refreshTimer: NodeJS.Timeout | null = null;
  /** Surfaces the phone created: the phone sizes these (in memory only). */
  private readonly phoneSized = new Set<number>();
  /** Live phone views of phone-sized terminals (connection and lease). */
  private readonly phoneViews = new Map<number, Set<{ stream: DaemonConn; lease: string }>>();
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

  async create(grid?: { cols: number; rows: number }): Promise<Terminal> {
    const c = await this.conn();
    const res = await c.request<{ surface: number }>("new-tab", grid ? { cols: grid.cols, rows: grid.rows } : {});
    this.phoneSized.add(res.surface);
    await this.refresh();
    const t = this.terminals.get(res.surface);
    if (!t) throw new RpcError("internal", "the new terminal did not appear");
    return { ...t };
  }

  /**
   * Closes the Mac tab and ends its shell. `close-surface` alone only removes
   * the tab and leaves the pty running until the daemon's reap grace (30 s
   * in cmux-next); `close-tabs` with end_terminals ends it right away.
   */
  async close(id: string): Promise<void> {
    const { surface } = await this.known(id);
    const res = await (await this.conn()).request<{ closed?: number[] }>("close-tabs", { surfaces: [surface], end_terminals: true }).catch((err) => {
      throw this.mapError(err, surface);
    });
    if (Array.isArray(res?.closed) && !res.closed.includes(surface)) {
      this.forget(surface);
      throw new RpcError("not_found", `terminal ${id} ended on the Mac`);
    }
    this.forget(surface);
    this.scheduleRefresh();
  }

  async rename(id: string, title: string): Promise<void> {
    const { surface } = await this.known(id);
    await (await this.conn()).request("rename-surface", { surface, name: title }).catch((err) => {
      throw this.mapError(err, surface);
    });
  }

  /**
   * A daemon error for a terminal that no longer exists on the Mac becomes
   * not_found (the phone shows "This terminal ended on the Mac"), and the
   * terminal leaves term.list right away. Other failures stay unavailable.
   */
  private mapError(err: unknown, surface: number): RpcError {
    if (err instanceof RpcError) return err;
    const message = (err as Error)?.message ?? String(err);
    if (isGoneError(message)) {
      this.forget(surface);
      this.scheduleRefresh();
      return new RpcError("not_found", `terminal ${terminalId(surface)} ended on the Mac`);
    }
    return new RpcError("unavailable", message);
  }

  /** Drops a terminal the daemon no longer knows (term.exited for the phone). */
  private forget(surface: number): void {
    const t = this.terminals.get(surface);
    if (!t) return;
    this.terminals.delete(surface);
    this.emit("event", "term.exited", { terminalId: t.id, code: 0 });
  }

  /**
   * Opens a dedicated daemon connection streaming one terminal to `sink`.
   * Returns the input writer and a disposer (closing the connection drops
   * the daemon lease).
   */
  async attach(id: string, sink: (data: Uint8Array) => void, grid?: { cols: number; rows: number }): Promise<{ terminal: Terminal; write: (data: Uint8Array) => void; dispose: () => void }> {
    const { surface, t } = await this.known(id);
    const phoneSized = this.phoneSized.has(surface);
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
    let view: { stream: DaemonConn; lease: string } | undefined;
    try {
      // A phone-sized terminal claims the phone's grid as it attaches (when
      // the daemon takes an initial size), else right after.
      const initial = phoneSized && grid && this.takesInitialSize(stream) ? { cols: grid.cols, rows: grid.rows } : {};
      const res = await stream.request<{ lease?: string }>("attach-surface", { surface, mode: "bytes", ...initial });
      lease = res.lease;
      if (!phoneSized) {
        // The phone types into the Mac's terminal but never takes its grid.
        await stream.request("set-size-counts", { surface, counts: false });
      } else if (lease) {
        view = { stream, lease };
        let views = this.phoneViews.get(surface);
        if (!views) this.phoneViews.set(surface, (views = new Set()));
        views.add(view);
        if (grid) await this.sizeView(surface, view, grid);
      }
    } catch (err) {
      stream.close();
      throw this.mapError(err, surface);
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
        if (view) this.phoneViews.get(surface)?.delete(view);
        if (lease) void stream.request("detach-attached-view", { surface, lease }, 2_000).catch(() => {}).finally(() => stream.close());
        else stream.close();
      },
    };
  }

  private takesInitialSize(stream: DaemonConn): boolean {
    const caps = (stream.identity as { capabilities?: unknown }).capabilities;
    return Array.isArray(caps) && caps.includes("attach-initial-size");
  }

  /** Reports the phone's grid for one view and marks it active (it takes the grid under `latest`). */
  private async sizeView(surface: number, view: { stream: DaemonConn; lease: string }, grid: { cols: number; rows: number }): Promise<void> {
    await view.stream.request("resize-attached-view", { surface, lease: view.lease, cols: grid.cols, rows: grid.rows });
    await view.stream.request("note-size-activity", { surface });
  }

  /**
   * term.resize: a phone-sized terminal takes the phone's grid through its
   * attached views; any other terminal keeps the Mac's grid, which the phone
   * gets back as term.updated.
   */
  async resize(id: string, grid: { cols: number; rows: number } | undefined): Promise<void> {
    const { surface, t } = await this.known(id);
    const views = this.phoneViews.get(surface);
    if (grid && this.phoneSized.has(surface) && views && views.size > 0) {
      for (const view of views) await this.sizeView(surface, view, grid).catch((err) => this.log(`resize ${id} failed: ${(err as Error).message}`));
      return;
    }
    this.emit("event", "term.updated", { terminal: { ...t } });
  }

  register(server: RpcServer): void {
    this.on("event", (topic, payload) => server.broadcast(topic, payload));
    server.register("term.list", async () => ({ terminals: await this.list() }));
    server.register("term.create", async (p) => {
      // Never let the phone choose where or what a Mac terminal runs: refuse
      // every option but the (ignored) grid instead of silently dropping it.
      if (optStr(p, "cwd") !== undefined) throw new RpcError("unsupported", "a working directory cannot be chosen from the phone; the Mac picks it");
      const extra = Object.keys(p).filter((k) => !TERM_CREATE_PARAMS.has(k) && p[k] !== null && p[k] !== undefined);
      if (extra.length > 0) throw new RpcError("unsupported", `term.create on the Mac takes no ${extra.join(", ")}: new terminals run the default shell`);
      return { terminal: await this.create(phoneGrid(p.cols, p.rows)) };
    });
    server.register("term.attach", async (p, session: ClientSession) => {
      const terminalIdParam = str(p, "terminalId");
      let streamId = 0;
      const early: Uint8Array[] = [];
      let ready = false;
      const att = await this.attach(
        terminalIdParam,
        (data) => {
          if (!ready) early.push(Uint8Array.from(data));
          else session.sendFrame(FrameKind.termOutput, streamId, data);
        },
        phoneGrid(p.cols, p.rows),
      );
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
    // The Mac owns a Mac terminal's grid (term.updated reports it); the
    // phone sizes the terminals it created.
    server.register("term.resize", async (p) => {
      await this.resize(str(p, "terminalId"), phoneGrid(p.cols, p.rows));
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
