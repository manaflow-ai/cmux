// l10n-allow-file: the browser dev loop's stand-in host, not shipped UI.
// An in-memory server card host for the browser dev loop (`/server-cards/?mock#/add-machine`): the server
// surfaces' ops (`#/server-panel`, `#/add-server`) go to MockServerOwner; `#/add-machine` runs on
// add-machine/mock.ts.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { MockAddMachineHost } from "./add-machine/mock";
import { AddMachineOps } from "./add-machine/types";
import { CardOps } from "./host";
import { MockServerOwner } from "./server/mockOwner";
import { ServerOps } from "./server/types";

export class MockServerCardsHost implements PageClient {
  private addMachineListeners = new Set<() => void>();
  /** `#/add-machine`'s stand-in (add-machine/mock.ts). */
  readonly addMachine = new MockAddMachineHost(() => {
    for (const listener of this.addMachineListeners) listener();
  });
  readonly server = new MockServerOwner();

  async call<R>(op: string, params: unknown): Promise<R> {
    if (op.startsWith("cmux.addMachine.")) return this.addMachine.call(op, params) as R;
    if (this.server.handles(op)) return (await this.server.call(op, params)) as R;
    switch (op) {
      case CardOps.resize:
      case CardOps.close:
        return null as R;
      default:
        throw pageError("cmux.op.unknown", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream === CardOps.commands) return () => {};
    if (stream === AddMachineOps.changes) {
      let seq = 0;
      const listener = () => onEvent({} as E, ++seq);
      this.addMachineListeners.add(listener);
      return () => void this.addMachineListeners.delete(listener);
    }
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
