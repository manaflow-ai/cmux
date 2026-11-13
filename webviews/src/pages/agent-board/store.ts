// The Agent Board page's state owner: whether the board is on and every ledger, folded. It reads
// once on open and again on each change in the ledger folder (`cmux.agentBoard.changes`, FSEvents in
// the host): no polling. A change while a read is on its way reads once more after it.
import { isPageError, type PageClient } from "../shared/pageClient";
import { OWNER_SENTENCE, userMessage } from "../shared/userMessage";
import { foldLedger, type Board } from "./ledger";
import { AgentBoardOps, type BoardState, type EvidenceImage, type LedgerFile } from "./types";

export interface AgentLedger {
  file: string;
  modifiedMs: number;
  truncated: boolean;
  board: Board;
}

export interface AgentBoardSnapshot {
  loading: boolean;
  /** The first read has answered. */
  loaded: boolean;
  enabled: boolean;
  folder: string;
  agents: AgentLedger[];
  /** When the ledgers were last read: the board's "now" for ages and the live dot. */
  readAtMs: number;
  /** Why the ledgers did not load (the host's own words when it gave them). */
  failed?: { message?: string };
  /** No host to ask (opened outside cmux). */
  unavailable?: boolean;
}

export class AgentBoardStore {
  private snapshot: AgentBoardSnapshot = {
    loading: false,
    loaded: false,
    enabled: false,
    folder: "",
    agents: [],
    readAtMs: 0,
  };
  private listeners = new Set<() => void>();
  private again = false;
  private images = new Map<string, Promise<EvidenceImage>>();
  private unsubscribe?: () => void;

  constructor(private readonly client: PageClient | null) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  async start(): Promise<void> {
    if (!this.client) return this.set({ ...this.snapshot, loaded: true, unavailable: true });
    try {
      this.unsubscribe = await this.client.subscribe(AgentBoardOps.changes, () => void this.refresh());
    } catch {
      // Without the stream the page still reads on open and when the tab is shown again.
    }
    await this.refresh();
  }

  stop() {
    this.unsubscribe?.();
  }

  /** Reads the ledgers again; a change during a read reads once more after it. */
  async refresh(): Promise<void> {
    if (!this.client) return;
    if (this.snapshot.loading) {
      this.again = true;
      return;
    }
    this.set({ ...this.snapshot, loading: true });
    try {
      const state = await this.client.call<BoardState>(AgentBoardOps.state, {});
      // A ledger may name a new image at the same path: drop the cache with the new read.
      this.images.clear();
      this.set({
        loading: false,
        loaded: true,
        enabled: state.enabled,
        folder: state.folder,
        agents: state.ledgers.map(fold),
        readAtMs: Date.now(),
      });
    } catch (error) {
      const owner = isPageError(error) && error.code.startsWith("cmux.agentBoard.");
      this.set({
        ...this.snapshot,
        loading: false,
        loaded: true,
        failed: { message: owner ? userMessage(error, { [error.code]: OWNER_SENTENCE }) : undefined },
      });
    }
    if (this.again) {
      this.again = false;
      await this.refresh();
    }
  }

  /** Turns the board on or off: the host writes `agents.board.enabled` as the person. */
  async setEnabled(on: boolean): Promise<void> {
    if (!this.client) return;
    await this.client.call(AgentBoardOps.setEnabled, { on });
    this.set({ ...this.snapshot, enabled: on });
    await this.refresh();
  }

  /** An image a ledger names, once per read. */
  image(path: string): Promise<EvidenceImage> {
    if (!this.client) return Promise.reject(new Error("unavailable"));
    let image = this.images.get(path);
    if (!image) {
      image = this.client.call<EvidenceImage>(AgentBoardOps.evidence, { path });
      this.images.set(path, image);
      image.catch(() => this.images.delete(path));
    }
    return image;
  }

  /** Opens a file or link a ledger names (the person's click). */
  open(target: { path?: string; url?: string }): Promise<unknown> {
    if (!this.client) return Promise.resolve();
    return this.client.call(AgentBoardOps.open, target);
  }

  private set(snapshot: AgentBoardSnapshot) {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}

/** The words to show for a failed call: the host's own sentence for the board's errors, else none
 * (the page says it failed in its own words). */
export function failureMessage(error: unknown): string | undefined {
  return isPageError(error) && error.code.startsWith("cmux.agentBoard.")
    ? userMessage(error, { [error.code]: OWNER_SENTENCE })
    : undefined;
}

function fold(ledger: LedgerFile): AgentLedger {
  return {
    file: ledger.file,
    modifiedMs: ledger.modifiedMs,
    truncated: ledger.truncated,
    board: foldLedger(ledger.text),
  };
}
