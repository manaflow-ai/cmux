// Minimal phone-side client over a Link, used by the probe, the loopback
// self-test and tests. Mirrors what the Swift HostClient does.

import { FrameKind, PROTOCOL_VERSION } from "./protocol.ts";
import { RpcPeer } from "./rpc/peer.ts";
import type { Link } from "./transport/link.ts";

export class HostClient {
  readonly peer: RpcPeer;
  private readonly streamListeners = new Map<number, (payload: Uint8Array) => void>();
  private readonly early = new Map<number, Uint8Array[]>();

  constructor(link: Link) {
    this.peer = new RpcPeer(link);
    this.peer.on("frame", (_kind, streamId, payload) => {
      const l = this.streamListeners.get(streamId);
      if (l) l(payload);
      else {
        // Frames can beat the attach response (separate lanes); buffer them.
        const list = this.early.get(streamId) ?? [];
        list.push(Uint8Array.from(payload));
        this.early.set(streamId, list);
      }
    });
  }

  hello(name = "cmux-next-probe") {
    return this.peer.request("host.hello", {
      client: { name, version: "0.1.0", platform: process.platform },
      protocol: PROTOCOL_VERSION,
    });
  }

  request<T = any>(method: string, params: unknown = {}, timeoutMs?: number): Promise<T> {
    return this.peer.request<T>(method, params, timeoutMs);
  }

  onStream(streamId: number, listener: (payload: Uint8Array) => void): () => void {
    this.streamListeners.set(streamId, listener);
    for (const p of this.early.get(streamId) ?? []) listener(p);
    this.early.delete(streamId);
    return () => this.streamListeners.delete(streamId);
  }

  sendInput(streamId: number, data: string | Uint8Array): void {
    this.peer.sendFrame(FrameKind.termInput, streamId, typeof data === "string" ? new TextEncoder().encode(data) : data);
  }

  /** Creates a terminal, attaches, runs a command and waits for marker output. */
  async terminalEcho(timeoutMs = 15_000): Promise<{ terminalId: string; marker: string; ms: number }> {
    const { terminal } = await this.request("term.create", { cols: 100, rows: 30 });
    const { streamId } = await this.request("term.attach", { terminalId: terminal.id, cols: 100, rows: 30 });
    const marker = `cmux-probe-${Math.random().toString(36).slice(2, 8)}`;
    const started = Date.now();
    let out = "";
    const decoder = new TextDecoder();
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no echo within ${timeoutMs}ms; got ${JSON.stringify(out.slice(-200))}`)), timeoutMs);
      this.onStream(streamId, (p) => {
        out += decoder.decode(p, { stream: true });
        // The marker appears once in the typed command and once in output.
        if (out.split(marker).length >= 3) {
          clearTimeout(timer);
          resolve();
        }
      });
      this.sendInput(streamId, `echo ${marker}\r`);
    });
    const ms = Date.now() - started;
    await this.request("term.close", { terminalId: terminal.id });
    return { terminalId: terminal.id, marker, ms };
  }
}
