// An in-memory group editor host for the browser dev loop (`/group-editor/?mock`), the gallery and
// the tests: it opens a fixture group, applies color picks and Sort's value as the native host does
// (a refresh with the next revision), records every call, and opens the group again after a close.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { fixtureColors, fixtureSession } from "./fixtures";
import { GroupEditorOps, type GroupEditorSession } from "./host";

export class MockGroupEditorHost implements PageClient {
  readonly calls: { op: string; params: Record<string, unknown> }[] = [];
  session: GroupEditorSession;
  private listener?: (data: GroupEditorSession, seq: number) => void;
  private seq = 0;
  private opens = 0;

  constructor(session: GroupEditorSession = fixtureSession()) {
    this.session = session;
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    const body = (params ?? {}) as Record<string, unknown>;
    this.calls.push({ op, params: body });
    if (!Object.values(GroupEditorOps).includes(op as never) || op === GroupEditorOps.session)
      throw pageError("cmux.protocol.unknown_op", op);
    if (body.session !== this.session.id) throw pageError("cmux.protocol.invalid_params", `${op}: unknown session`);
    switch (op) {
      case GroupEditorOps.draft:
        this.session = { ...this.session, name: String(body.name ?? "") };
        break;
      case GroupEditorOps.color:
        this.refresh({ colors: fixtureColors(String(body.color)), custom: { css: null, chosen: false } });
        break;
      case GroupEditorOps.item:
      case GroupEditorOps.customColor:
      case GroupEditorOps.close:
        // The bubble closes; in the browser loop it opens again so there is always something to try.
        this.emit({ ...this.session, id: "", revision: this.session.revision + 1 });
        setTimeout(() => this.open(), 400);
        break;
    }
    return undefined as R;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== GroupEditorOps.session) throw pageError("cmux.protocol.unknown_op", stream);
    this.listener = onEvent as (data: GroupEditorSession, seq: number) => void;
    queueMicrotask(() => this.emit(this.session));
    return () => (this.listener = undefined);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  /** A new open of the same fixture group (a new id). */
  open(session?: GroupEditorSession) {
    this.opens += 1;
    this.session = session ?? { ...this.session, id: `mock-open-${this.opens}`, revision: this.session.revision + 1 };
    this.emit(this.session);
  }

  /** The group changed while the editor is open: same id, next revision. */
  refresh(change: Partial<GroupEditorSession>) {
    this.session = { ...this.session, ...change, revision: this.session.revision + 1 };
    this.emit(this.session);
  }

  callsOf(op: string) {
    return this.calls.filter((call) => call.op === op).map((call) => call.params);
  }

  private emit(session: GroupEditorSession) {
    this.listener?.(session, ++this.seq);
  }
}
