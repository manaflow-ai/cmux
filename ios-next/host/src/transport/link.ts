// Transport-agnostic Link (PROTOCOL.md §1): three ordered, reliable lanes that
// carry whole byte messages. Everything above this file never sees WebRTC.

import { EventEmitter } from "node:events";
import { encodeMessage, Reassembler } from "./laneCodec.ts";

export type Lane = "ctl" | "int" | "blk";
export const LANES: readonly Lane[] = ["ctl", "int", "blk"] as const;
export const LANE_IDS: Record<Lane, number> = { ctl: 0, int: 1, blk: 2 };

export type LinkState = "connecting" | "open" | "closed";

export interface LinkEvents {
  message: [lane: Lane, data: Uint8Array];
  state: [state: LinkState];
}

export interface Link {
  readonly state: LinkState;
  /** Human readable transport description, e.g. "webrtc relay/udp". */
  describe(): string;
  send(lane: Lane, data: Uint8Array | string): void;
  /** Bytes accepted by send() on `lane` but not yet handed to the network. */
  bufferedAmount(lane: Lane): number;
  close(reason?: string): void;
  on<K extends keyof LinkEvents>(event: K, listener: (...args: LinkEvents[K]) => void): this;
  off<K extends keyof LinkEvents>(event: K, listener: (...args: LinkEvents[K]) => void): this;
  once<K extends keyof LinkEvents>(event: K, listener: (...args: LinkEvents[K]) => void): this;
}

const textEncoder = new TextEncoder();

export function toBytes(data: Uint8Array | string): Uint8Array {
  return typeof data === "string" ? textEncoder.encode(data) : data;
}

/**
 * Base class for transports that move lane chunks. Subclasses implement
 * sendChunk and call receiveChunk; the base class owns the LaneCodec.
 */
export abstract class ChunkLink extends EventEmitter implements Link {
  private _state: LinkState = "connecting";
  private readonly reassemblers: Record<Lane, Reassembler> = {
    ctl: new Reassembler(),
    int: new Reassembler(),
    blk: new Reassembler(),
  };

  get state(): LinkState {
    return this._state;
  }

  abstract describe(): string;
  bufferedAmount(_lane: Lane): number {
    return 0;
  }
  protected abstract sendChunk(lane: Lane, chunk: Uint8Array): void;
  protected abstract closeTransport(reason?: string): void;

  send(lane: Lane, data: Uint8Array | string): void {
    if (this._state !== "open") throw new Error(`link is ${this._state}`);
    for (const chunk of encodeMessage(toBytes(data))) this.sendChunk(lane, chunk);
  }

  private closing = false;
  /** Reason the link closed, if known. */
  closeReason: string | undefined;

  close(reason?: string): void {
    if (this._state === "closed" || this.closing) return;
    this.closing = true;
    this.closeReason = reason;
    try {
      this.closeTransport(reason);
    } finally {
      this.setState("closed");
    }
  }

  protected receiveChunk(lane: Lane, chunk: Uint8Array): void {
    let msg: Uint8Array | null;
    try {
      msg = this.reassemblers[lane].push(chunk);
    } catch (err) {
      this.close(`codec error: ${(err as Error).message}`);
      return;
    }
    if (msg) this.emit("message", lane, msg);
  }

  protected setState(state: LinkState): void {
    if (this._state === state || this._state === "closed") return;
    this._state = state;
    this.emit("state", state);
  }
}
