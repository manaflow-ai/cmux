// An in-memory Mobile Pairing host for the browser dev loop (`/mobile-pairing/?mock`): signed out
// at first; Sign In, Allow Phone Access and Turn Off move it through the steps, and the listener is
// ready a moment after phone access turns on.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { ACTION_RUN, MobilePairingOps, PairingActions, type MobilePairingStatus } from "./types";

/** A 1x1 white PNG stands in for the host's QR code. */
const BLANK_PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAG7buVgAAAABJRU5ErkJggg==";

export class MockMobilePairingProvider implements PageClient {
  private status: MobilePairingStatus = {
    state: "signedOut",
    macName: "Mac Studio",
    allowed: false,
    connectedPhones: 0,
  };
  private listeners = new Set<() => void>();

  constructor(initial?: Partial<MobilePairingStatus>) {
    this.status = { ...this.status, ...initial };
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    switch (op) {
      case MobilePairingOps.status:
        return this.status as R;
      case MobilePairingOps.setAllowed: {
        const on = (params as { on?: boolean }).on === true;
        this.update({ allowed: on, state: on ? "preparing" : "accessOff", qr: undefined });
        if (on) setTimeout(() => this.update(this.ready()), 600);
        return {} as R;
      }
      case ACTION_RUN: {
        const action = (params as { action?: string }).action;
        if (action === PairingActions.signIn) {
          this.update({ account: "you@example.com", state: this.status.allowed ? "ready" : "accessOff" });
        }
        return { ran: true } as R;
      }
      default:
        throw pageError("cmux.op.unknown", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== MobilePairingOps.changes) throw pageError("cmux.op.unknown", stream);
    let seq = 0;
    const listener = () => onEvent({} as E, ++seq);
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }

  private ready(): Partial<MobilePairingStatus> {
    return {
      state: "ready",
      qr: { url: "cmux://attach?mock", image: BLANK_PNG, expiresAt: Date.now() + 600_000 },
    };
  }

  private update(change: Partial<MobilePairingStatus>) {
    this.status = { ...this.status, ...change };
    for (const listener of this.listeners) listener();
  }
}
