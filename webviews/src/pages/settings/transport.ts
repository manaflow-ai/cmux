// The one boundary between the Settings page and whoever owns settings (SETTINGS-PAGE-FIRST-
// PRINCIPLES, ownership note in design.md). Today the owner is the native host (the app relays
// each call to the daemon's v2 `settings.*` ops over the cmuxPage bridge); a later Rust config
// service shared by the app, the TUI, the CLI and remote clients replaces only this file's
// implementation. The query layer (queries.ts) and every component read and write through
// SettingsTransport and nothing else.
import {
  errorCode,
  newIdempotencyKey,
  revisionNumber,
  wireError,
  type MutationResult,
  type ListRow,
  type SettingsClient,
  type SnapshotResult,
  type WireError,
} from "./ops";

/** One read of a scope: the rows with their values and the snapshot (managed keys, problems). */
export type ScopeRead = { rows: ListRow[]; snapshot: SnapshotResult };

/** A change any writer made (this page, the CLI, a hand edit, an MDM profile). */
export type ChangeEvent = {
  keys: string[];
  origin?: string;
  /** The owner's revision once the change applied. */ revision?: number;
  /** Earlier change events were dropped while the page was hidden or frozen, so `keys` names
   * only the newest change: any key may have changed. */
  gap?: true;
};

/** The settings scopes the page reads; today only the user's file (cmux.json and its MDM overlay). */
export type SettingsScope = "user";

export interface SettingsTransport {
  /** Reads every row of a scope. Rejects with a WireError. */
  get(scope: SettingsScope): Promise<ScopeRead>;
  /** Writes one key; resolves to the owner's revision after it, when the owner says.
   * Rejects with a WireError (managed, invalid, revision conflict, unavailable). */
  set(key: string, value: unknown): Promise<number | void>;
  /** Returns one key to its default, or every key (`"all"`, except the ones reset all keeps);
   * resolves to the owner's revision after it, when the owner says. */
  reset(key: string | "all"): Promise<number | void>;
  /** Calls back on every change and on each loss or return of the owner; resolves to unsubscribe. */
  subscribe(listener: { changed(event: ChangeEvent): void; connection(connected: boolean): void }): Promise<() => void>;
}

/** Thrown for a WireError a call rejected with. */
export class TransportError extends Error {
  constructor(readonly wire: WireError) {
    super(wire.message);
  }
  get code(): string {
    return errorCode(this.wire);
  }
}

async function call<R>(client: SettingsClient, op: string, params: unknown): Promise<R> {
  try {
    return await client.call<R>(op, params);
  } catch (error) {
    throw new TransportError(wireError(error));
  }
}

/** The transport over the native host's page bridge (the owner today). */
export function pageTransport(client: SettingsClient): SettingsTransport {
  return {
    async get() {
      const [rows, snapshot] = await Promise.all([
        call<ListRow[]>(client, "cmux.settings.list", {}),
        call<SnapshotResult>(client, "cmux.settings.snapshot", {}),
      ]);
      return { rows, snapshot };
    },
    async set(key, value) {
      return replyRevision(
        await call<MutationResult>(client, "cmux.settings.set", { key, value, idempotency_key: newIdempotencyKey() }),
      );
    },
    async reset(key) {
      const reply =
        key === "all"
          ? await call<MutationResult>(client, "cmux.settings.reset_all", { idempotency_key: newIdempotencyKey() })
          : await call<MutationResult>(client, "cmux.settings.reset", { key, idempotency_key: newIdempotencyKey() });
      return replyRevision(reply);
    },
    async subscribe(listener) {
      const stops = await Promise.all([
        client
          .subscribe<ChangeEvent>("cmux.settings.changed", (event, _seq, meta) =>
            listener.changed(meta?.gap === true ? { ...event, gap: true } : event),
          )
          .catch(() => () => {}),
        client
          .subscribe<{ connected: boolean }>("cmux.page.connection", (event) => listener.connection(event.connected))
          .catch(() => () => {}),
      ]);
      return () => stops.forEach((stop) => stop());
    },
  };
}

/** The revision a mutation reply names, or undefined when it names none. */
function replyRevision(reply: MutationResult | undefined): number | undefined {
  const revision = revisionNumber(reply?.revision);
  return revision > 0 ? revision : undefined;
}
