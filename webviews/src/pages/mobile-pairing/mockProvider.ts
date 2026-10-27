// An in-memory Mobile Pairing host for the browser dev loop (`/mobile-pairing/?mock`): signed out
// at first; Sign In, Allow Phone Access and Turn Off move it through the steps, and the iPhone host
// is online a moment after iPhone connections turn on, with one phone asking to connect.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { ACTION_RUN, MobilePairingOps, PairingActions, type MobilePairingStatus, type PairingHost } from "./types";

const HOST: PairingHost = {
  status: "Online · 1 phone connected",
  how: "Install cmux on your iPhone and sign in with the same account as this Mac. This Mac then appears under Workspaces.",
  phonesTitle: "Phones",
  phones: [{ id: "phone-1", title: "iPhone 17 Pro", subtitle: "WireGuard · direct", connected: true }],
  phonesEmpty: "No phones yet.",
  pendingTitle: "Waiting for You",
  pending: [{ id: "phone-2", title: "iPhone Air", subtitle: "Signed in as you@example.com · Key 3F2A 91C0" }],
  allowTitle: "Allow",
  denyTitle: "Don't Allow",
  blocked: null,
};

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
        this.update({ allowed: on, state: on ? "preparing" : "accessOff", host: undefined });
        if (on) setTimeout(() => this.update(this.ready()), 600);
        return {} as R;
      }
      case MobilePairingOps.answerPair: {
        const id = (params as { id?: string }).id;
        const host = this.status.host;
        if (host) this.update({ host: { ...host, pending: host.pending.filter((request) => request.id !== id) } });
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
    return { state: "ready", connectedPhones: 1, host: HOST };
  }

  private update(change: Partial<MobilePairingStatus>) {
    this.status = { ...this.status, ...change };
    for (const listener of this.listeners) listener();
  }
}
