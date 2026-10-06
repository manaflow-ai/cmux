// An in-memory icon picker host for the browser dev loop (`?mock`), the tests and the bench:
// prefs in memory, assets get a fake content id, and every finish is recorded.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { IconPickerOps, type PickerSession } from "./host";

export const MOCK_SYMBOLS = [
  "star",
  "star.fill",
  "heart",
  "heart.fill",
  "folder",
  "folder.fill",
  "terminal",
  "terminal.fill",
  "globe",
  "house",
  "gearshape",
  "bolt",
  "flame",
  "leaf",
  "hammer",
  "wrench.and.screwdriver",
  "person.crop.circle",
  "bubble.left.and.bubble.right",
  "cloud",
  "server.rack",
];

export class MockIconPickerHost implements PageClient {
  readonly calls: { op: string; params: unknown }[] = [];
  prefs: unknown = null;
  private sessionListener?: (data: PickerSession, seq: number) => void;
  private seq = 0;

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    switch (op) {
      case IconPickerOps.prefsLoad:
        return this.prefs as R;
      case IconPickerOps.prefsSave:
        this.prefs = (params as { prefs: unknown }).prefs;
        return undefined as R;
      case IconPickerOps.assetPut:
      case IconPickerOps.assetFromURL: {
        const kind = (params as { kind: string }).kind;
        return { icon: `${kind}:sha256-${"0".repeat(63)}${this.calls.length % 10}` } as R;
      }
      case IconPickerOps.finish:
        return undefined as R;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== IconPickerOps.session) throw pageError("cmux.protocol.unknown_op", stream);
    this.sessionListener = onEvent as (data: PickerSession, seq: number) => void;
    return () => (this.sessionListener = undefined);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  /** What the native host does on each open. */
  open(session: PickerSession) {
    this.sessionListener?.(session, ++this.seq);
  }

  finishes() {
    return this.calls.filter((call) => call.op === IconPickerOps.finish).map((call) => call.params);
  }
}
