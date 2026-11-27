// File transfers (`cloud.file.push`, `cloud.file.pull`, R71 C10). The host's native action answers
// at once with `{transfer, state: running}`; the copy runs on in the server, and its end is the event
// `cmux.cloud.file.transfer.changed` (`done` with `bytes`, `failed` with a typed error, or `cancelled`
// when `cloud.file.transfer.cancel` stopped it, from the CLI for example). The page
// subscribes before it starts its first transfer, so an end cannot be missed, and keeps the
// subscription for the session. No polling and no timers: a running row changes only on its event.
import type { PageClient } from "../shared/pageClient";
import { CloudOps, isUnsupported, type TransferChanged } from "./ops";

export interface FileTransfer {
  transfer: string;
  machine: string;
  direction: "push" | "pull";
  /** The machine's path: the file a push wrote, or the file a pull reads. */
  path: string;
  state: "running" | "done" | "failed" | "cancelled";
  bytes?: number;
  /** The typed error's message of a failed transfer. */
  error?: string;
}

export interface TransferHost {
  get(): FileTransfer[];
  set(transfers: FileTransfer[]): void;
  /** One transfer of this page ended (after the row changed). */
  ended(event: TransferChanged): void;
  unsupported(op: string): void;
}

const ENDED = new Set<string>(["done", "failed", "cancelled"]);

/** Ended rows kept for the session; running rows are always kept. */
const KEEP_ENDED = 20;

function settle(row: FileTransfer, event: TransferChanged): FileTransfer {
  if (event.state === "done") return { ...row, state: "done", bytes: event.bytes, error: undefined };
  if (event.state === "cancelled") return { ...row, state: "cancelled", error: undefined };
  return { ...row, state: "failed", error: event.error?.message ?? event.error?.code };
}

function trim(rows: FileTransfer[]): FileTransfer[] {
  let extra = rows.filter((row) => row.state !== "running").length - KEEP_ENDED;
  return extra <= 0 ? rows : rows.filter((row) => row.state === "running" || extra-- <= 0);
}

export class TransferWatch {
  private unsubscribe?: () => void;
  private subscribing?: Promise<boolean>;
  /** Bumped by `stop`: a subscription or event of an older session is dropped. */
  private session = 0;
  /** Actions of this page that have not answered yet. */
  private inFlight = 0;
  /** Ends that came before their action answered; kept only while an action is in flight. */
  private readonly early = new Map<string, TransferChanged>();

  constructor(
    private readonly client: PageClient | null,
    private readonly host: TransferHost,
  ) {}

  /** Subscribes once per session. Answers false when the host does not deliver the events. */
  watch(): Promise<boolean> {
    if (this.unsubscribe) return Promise.resolve(true);
    if (!this.client) return Promise.resolve(false);
    this.subscribing ??= this.subscribe(this.client);
    return this.subscribing;
  }

  /**
   * Call before the action runs, and `end` with the answer after it answered (or failed). The answer
   * is the session: an action that answers after `stop` neither adds a row nor clears early ends.
   */
  begin(): number {
    this.inFlight += 1;
    return this.session;
  }

  end(session: number): void {
    if (session !== this.session) return;
    this.inFlight = Math.max(0, this.inFlight - 1);
    // An end no action of this page claimed belongs to another client (the CLI, another page).
    if (this.inFlight === 0) this.early.clear();
  }

  /**
   * The action answered `running`: the row shows until its event (or ends now, if the event came
   * first). Dropped when the session changed: no subscription would ever end that row.
   */
  started(session: number, row: Omit<FileTransfer, "state">): void {
    if (session !== this.session) return;
    const early = this.early.get(row.transfer);
    this.early.delete(row.transfer);
    const running: FileTransfer = { ...row, state: "running" };
    const others = this.host.get().filter((t) => t.transfer !== row.transfer);
    this.host.set(trim([...others, early ? settle(running, early) : running]));
    if (early) this.host.ended(early);
  }

  stop(): void {
    this.session += 1;
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    this.subscribing = undefined;
    this.inFlight = 0;
    this.early.clear();
  }

  private async subscribe(client: PageClient): Promise<boolean> {
    const session = this.session;
    try {
      const unsubscribe = await client.subscribe<TransferChanged>(CloudOps.fileTransferChanged, (event) => {
        if (session === this.session) this.onEvent(event);
      });
      if (session !== this.session) {
        unsubscribe();
        return false;
      }
      this.unsubscribe = unsubscribe;
      return true;
    } catch (error) {
      if (session === this.session) {
        // A later transfer tries again.
        this.subscribing = undefined;
        if (isUnsupported(error)) this.host.unsupported(CloudOps.fileTransferChanged);
      }
      return false;
    }
  }

  private onEvent(event: TransferChanged): void {
    if (!event?.transfer || !ENDED.has(event.state)) return;
    const rows = this.host.get();
    const row = rows.find((t) => t.transfer === event.transfer);
    if (!row) {
      if (this.inFlight > 0) this.early.set(event.transfer, event);
      return;
    }
    if (row.state !== "running") return;
    this.host.set(trim(rows.map((t) => (t === row ? settle(t, event) : t))));
    this.host.ended(event);
  }
}
