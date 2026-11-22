// The bundle's side of the boot script's early requests (earlyOpen.ts `EarlyWire`): the socket that took
// the early open (bridgeSocket.ts) sends each of its requests through `outgoing` and hands each frame
// that comes in to `incoming`. A request of the bundle that is the same frame (method and params) as
// one the boot sent and that is still out is not sent again: the boot's answer is its answer, given
// with its own id, once. One with the same method and other params (another chat, the hold, another
// `visible`) goes out as before, and the boot's is dropped: its answer is never given. The early
// chat's live records (`_acpmux/event`) that come before the bundle sent its attach wait with that
// attach: given after its answer once the bundle sends it, as if the bundle had sent it then; dropped
// with it otherwise (the bundle's own attach reads the chat's newest page, which holds them, and
// takes over the one subscription acpmux keeps per chat and connection). A request still out past
// `EARLY_OPEN_FRESH_MS` from its send is dropped. Every other frame comes in as it did.
import { EARLY_OPEN_FRESH_MS, type EarlyAsk, type EarlyEvent, type EarlyWire } from "./earlyOpen";

/// `replied` once its answer came; `as` the bundle's id for it once taken.
type Ask = EarlyAsk & { state: "out" | "claimed" | "dropped"; as?: number | string; replied?: boolean };
/// A frame that waits on an early request: its answer, or a live record of the early attach's chat.
type Held = { frame: string; ask: Ask; reply?: Record<string, unknown> };

export class EarlyFrames {
  private readonly asks: Ask[];
  private held: Held[] = [];
  private pumpQueued = false;

  constructor(
    private readonly wire: EarlyWire,
    /// Gives a frame to the bundle (the socket's `onmessage`).
    private readonly deliver: (frame: string) => void,
  ) {
    this.asks = wire.asks.map((ask) => ({ ...ask, state: "out" }));
  }

  /// Nothing waits any more: every held frame was given or dropped, and every request answered (a taken
  /// one's answer still needs the bundle's id), or dropped and past the bound.
  get done(): boolean {
    if (this.held.length) return false;
    const now = this.wire.now();
    return this.asks.every((ask) => ask.replied || (ask.state !== "claimed" && now - ask.at > EARLY_OPEN_FRESH_MS));
  }

  /// The pushes that came before the bundle's socket opened, in order, once.
  takeInbox(): EarlyEvent[] {
    return this.wire.inbox.splice(0);
  }

  /// True when `text` is answered by the boot's request: the socket sends nothing.
  outgoing(text: string): boolean {
    this.expire();
    if (!this.asks.some((ask) => ask.state === "out")) return false;
    let message: { id?: unknown; method?: unknown; params?: unknown } | null;
    try {
      message = JSON.parse(text);
    } catch {
      return false;
    }
    const method = message?.method;
    const id = message?.id;
    if (typeof method !== "string") return false;
    const params = JSON.stringify(message?.params);
    let claimed = false;
    for (const ask of this.asks) {
      if (ask.state !== "out" || ask.method !== method) continue;
      if (!claimed && ask.params === params && (typeof id === "number" || typeof id === "string")) {
        ask.state = "claimed";
        ask.as = id;
        claimed = true;
      } else ask.state = "dropped";
    }
    // The bundle's detach of the early chat: its attach, if still out, is no longer wanted.
    if (
      method === "_acpmux/detach" &&
      (message?.params as { sessionId?: unknown } | undefined)?.sessionId === this.wire.session
    )
      for (const ask of this.asks) if (ask.method === "_acpmux/attach" && ask.state === "out") ask.state = "dropped";
    // After the bundle's request: its answer comes as the host's would, never inside its send.
    if (!this.pumpQueued) {
      this.pumpQueued = true;
      queueMicrotask(() => {
        this.pumpQueued = false;
        this.pump();
      });
    }
    return claimed;
  }

  /// A frame for the bundle: given now, or held until the request it waits on is taken.
  incoming(frame: string): void {
    this.expire();
    if (this.done) return this.deliver(frame);
    let message: { id?: unknown; method?: unknown; params?: { sessionId?: unknown } } | null;
    try {
      message = JSON.parse(frame);
    } catch {
      return this.deliver(frame);
    }
    const id = message?.id;
    if (message && message.method === undefined && typeof id === "number") {
      const ask = this.asks.find((one) => one.id === id);
      if (ask) {
        ask.replied = true;
        this.held.push({ frame, ask, reply: message as Record<string, unknown> });
        return this.pump();
      }
    }
    if (message?.method === "_acpmux/event" && this.wire.session && message.params?.sessionId === this.wire.session) {
      const attach = this.asks.find((one) => one.method === "_acpmux/attach");
      if (attach && (attach.state === "out" || this.held.some((held) => held.ask === attach))) {
        this.held.push({ frame, ask: attach });
        return this.pump();
      }
    }
    this.deliver(frame);
  }

  /// Gives the held frames of taken requests, in order, with the bundle's ids; drops those of dropped ones.
  private pump(): void {
    this.expire();
    const held = this.held;
    this.held = [];
    for (const one of held) {
      if (one.ask.state === "out") this.held.push(one);
      else if (one.ask.state === "claimed")
        this.deliver(one.reply ? JSON.stringify({ ...one.reply, id: one.ask.as }) : one.frame);
    }
  }

  private expire(): void {
    const now = this.wire.now();
    for (const ask of this.asks) if (ask.state === "out" && now - ask.at > EARLY_OPEN_FRESH_MS) ask.state = "dropped";
  }
}
