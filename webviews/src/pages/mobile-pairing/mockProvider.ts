// An in-memory Mobile Pairing host for the browser dev loop (`/mobile-pairing/?mock`): signed out
// at first; Sign In, Allow Phone Access and Turn Off move it through the steps, and the iPhone host
// is online a moment after iPhone connections turn on, with its pairing code and one phone asking to
// connect.
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

// A sample pairing link and its code (one pixel per module, as PairingQRCode draws it); the token
// and key hash are made up.
const QR = {
  url: "cmux-next://pair?mac=mac-studio&team=team-1&name=Mac%20Studio&t=AbC-dEf_0123456789Xy&k=q1Zr4cY0bW8nT2fK7hJ3mP5sL9dG6aE1uV0xC4yB8oQ",
  image:
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADUAAAA1AQAAAADJnZ7dAAABp0lEQVR42mP4DwY/GGD0gYBG66UXJBjuB+gx1ojfYLgYIRx3aEoEw8UyG5XYLUA6zIhV60sEw/2iJ2Ury28wHAgFggAJhv8P35Xujv/BcIPtBkvuWwmGe7tWPAh0qGC4YFz4a8qFGwzfd7tYHY+MYHjr4OrjuhLI7/+4zUPhB8O11Hrf8xYzGL5N63UUYLNguFj8+bQvjwTDzaZnHGaTfjAcCzbwZD8pwfBvzbbnzrN2MHxRyLlTmT6D4eMDF7N0RwuGM+KdbIcbZzC8vfm89FJMBcNJ577QgyFA/j2GYu+YHww/pNrYvzRKMPy6unnRtscRDNfNthy7YhzB8PWhpDTLaQuGNwLKgYJHIxhOnnvn17biB8M/h+T1J5dEMPy90uH3xiWC4Zu3lYl28Q2Gy+uXm/lYSTBcCTi39ur+GwyH13CyclZYMLwzU565Vj2C4fGCN0ZmuysYjqusZ5rCAAyPM6dKU+5UMBwI3ht6Y8oNhvuBJwvMYmcwXAz6xlp4cAfDxWCel6J2wPDMmnj3wtMdDPcL4xzMr0swHIg8rigw+wYDWrwAAHFsz/5q78d0AAAAAElFTkSuQmCC",
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
    // The code lasts five minutes; the page asks again a minute before.
    return { state: "ready", connectedPhones: 1, host: HOST, qr: { ...QR, expiresAt: Date.now() + 240_000 } };
  }

  private update(change: Partial<MobilePairingStatus>) {
    this.status = { ...this.status, ...change };
    for (const listener of this.listeners) listener();
  }
}
