// l10n-allow-file: the browser dev loop's stand-in host, not shipped UI.
// An in-memory server card host for the browser dev loop (`/server-cards/?mock#/server-panel`): the server
// surfaces' ops (`#/server-panel`, `#/server-health`, `#/server-pairing`) go to MockServerOwner.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { CardOps } from "./host";
import { MockServerOwner } from "./server/mockOwner";
import { ServerOps } from "./server/types";

export class MockServerCardsHost implements PageClient {
  readonly server = new MockServerOwner();

  async call<R>(op: string, params: unknown): Promise<R> {
    if (this.server.handles(op)) return (await this.server.call(op, params)) as R;
    switch (op) {
      case CardOps.resize:
        return null as R;
      default:
        throw pageError("cmux.op.unknown", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream === ServerOps.changes) {
      let seq = 0;
      return this.server.onChange(() => onEvent({} as E, ++seq));
    }
    throw pageError("cmux.op.unknown", stream);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}
