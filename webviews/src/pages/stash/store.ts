// The Stashed Tabs page's state owner on the page side: the daemon's stashes (`stash.list`), the
// search text, the inline OneTab paste box, and the intents. The page keeps no optimistic copy: a
// change re-reads after its owner confirms, and every stash change anywhere (`stash-changed`)
// re-reads. Only a delete hides its members at once, while the app's Undo toast is up.
import { isPageError, type PageClient } from "../shared/pageClient";
import { subscribePageStreams } from "../shared/pageStreams";
import { memberKey, normalized, parseOneTab, visibleGroups } from "./model";
import {
  StashOps,
  type StashDeleted,
  type StashGroup,
  type StashImported,
  type StashMember,
  type StashRecord,
} from "./types";

export type Connection = "connecting" | "connected" | "disconnected";

/** What the notice line under the header says; the view words it. */
export type StashNotice =
  | { kind: "error"; message: string }
  | { kind: "nothingToImport" }
  | { kind: "imported"; imported: number; skipped: number };

export interface StashSnapshot {
  /** Every stash, newest first, without members whose delete waits on its Undo toast. */
  groups: StashGroup[];
  query: string;
  importOpen: boolean;
  importText: string;
  /** True while a restore or an import is in flight: the page's controls are off. */
  busy: boolean;
  /** True until the first read answers. */
  loading: boolean;
  connection: Connection;
  notice?: StashNotice;
}

export class StashStore {
  private snapshot: StashSnapshot;
  private loaded: StashGroup[] = [];
  private readonly hidden = new Set<string>();
  private readonly listeners = new Set<() => void>();
  private generation = 0;
  private lifetime = 0;
  private stops: Array<() => void> = [];
  private starting = false;
  /** Whether the notice is a failed read's, which the next good read clears. */
  private noticeIsRead = false;

  constructor(
    private readonly client: PageClient | null,
    options: { importOpen?: boolean } = {},
  ) {
    this.snapshot = {
      groups: [],
      query: "",
      importOpen: options.importOpen ?? false,
      importText: "",
      busy: false,
      loading: client !== null,
      connection: client ? "connecting" : "disconnected",
    };
  }

  getSnapshot = (): StashSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Follows stash changes and the owner link, then reads the stashes. Idempotent. */
  async start(): Promise<void> {
    if (!this.client || this.starting || this.stops.length) return;
    const lifetime = ++this.lifetime;
    const alive = () => lifetime === this.lifetime;
    this.starting = true;
    try {
      const keep = (stop: () => void) => (alive() ? this.stops.push(stop) : stop());
      try {
        keep(await this.client.subscribe(StashOps.changed, () => alive() && void this.reload()));
      } catch (error) {
        if (!alive()) return;
        // An owner without the change stream still answers reads.
        if (!(isPageError(error) && error.code === "cmux.protocol.unknown_op")) {
          this.set({ connection: "disconnected", loading: false });
          return;
        }
      }
      try {
        keep(
          await subscribePageStreams(this.client, {
            onConnection: (connected) => alive() && this.onConnection(connected),
            onCommand: ({ command, text }) => {
              if (!alive()) return;
              if (command === "open" && text === "import") this.openImport();
              if (command === "reset") this.setQuery("");
              if (command === "find" || command === "focusSearch") {
                if (typeof text === "string") this.setQuery(text);
                document.querySelector<HTMLInputElement>(".stash-search")?.focus();
              }
            },
          }),
        );
      } catch (error) {
        if (alive()) this.fail(error);
      }
      if (alive()) await this.reload();
    } finally {
      if (alive()) this.starting = false;
    }
  }

  stop(): void {
    ++this.lifetime;
    ++this.generation;
    this.starting = false;
    for (const stop of this.stops.splice(0)) stop();
  }

  private onConnection(connected: boolean): void {
    if (!connected) this.set({ connection: "disconnected", loading: false });
    else if (this.snapshot.connection === "disconnected") {
      this.set({ connection: "connecting" });
      void this.reload();
    }
  }

  /** Reads the stashes again; a slower older reply never replaces a newer one. */
  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    try {
      const records = await this.client.call<StashRecord[]>(StashOps.list, {});
      if (generation !== this.generation) return;
      this.loaded = (records ?? []).map(normalized);
      const clearRead = this.noticeIsRead ? { notice: undefined } : {};
      this.noticeIsRead = false;
      this.set({ ...clearRead, groups: this.visible(), loading: false, connection: "connected" });
    } catch (error) {
      if (generation !== this.generation) return;
      this.fail(error);
      this.noticeIsRead = true;
      this.set({ loading: false });
    }
  }

  setQuery(query: string): void {
    if (query !== this.snapshot.query) this.set({ query });
  }

  openImport(): void {
    if (!this.snapshot.importOpen) this.set({ importOpen: true });
  }

  closeImport(): void {
    this.set({ importOpen: false, importText: "" });
  }

  setImportText(importText: string): void {
    this.set({ importText });
  }

  /** Imports the pasted OneTab text. The box closes once pages were imported; with none it stays
   * open with the notice. */
  async importPasted(): Promise<void> {
    const groups = parseOneTab(this.snapshot.importText);
    if (!groups.length) {
      this.set({ notice: { kind: "nothingToImport" } });
      return;
    }
    await this.run(async (client) => {
      const result = await client.call<StashImported>(StashOps.import, { source: "onetab", groups });
      const imported = Number(result?.imported_tabs ?? 0);
      const skipped = Number(result?.skipped_tabs ?? 0);
      this.set({ notice: { kind: "imported", imported, skipped } });
      if (imported > 0) this.closeImport();
    });
  }

  /** Restore All (`members` absent), a row's click, or Restore in New Workspace. */
  restore(group: StashGroup, members?: StashMember[], newWorkspace = false): Promise<void> {
    return this.run((client) =>
      client.call(StashOps.restore, {
        stash: group.id,
        ...(members ? { members: members.map((member) => member.id) } : {}),
        new_workspace: newWorkspace,
      }),
    );
  }

  /** Delete Group (`member` absent) or a row's ×: hidden at once while the app's Undo toast is
   * up; back when the person pressed Undo or the delete failed. */
  async delete(group: StashGroup, member?: StashMember): Promise<void> {
    if (!this.client) return;
    const lifetime = this.lifetime;
    const key = member ? memberKey(group.id, member.id) : group.id;
    this.hidden.add(key);
    this.set({ groups: this.visible() });
    try {
      const reply = await this.client.call<StashDeleted>(StashOps.delete, {
        stash: group.id,
        ...(member ? { members: [member.id] } : {}),
      });
      if (lifetime !== this.lifetime) return;
      this.hidden.delete(key);
      if (reply?.deleted) await this.reload();
      else this.set({ groups: this.visible() });
    } catch (error) {
      if (lifetime !== this.lifetime) return;
      this.hidden.delete(key);
      this.fail(error);
      this.set({ groups: this.visible() });
    }
  }

  private visible(): StashGroup[] {
    return visibleGroups(this.loaded, this.hidden);
  }

  /** Runs one op with the page's controls off, then reads the stashes again. */
  private async run(op: (client: PageClient) => Promise<unknown>): Promise<void> {
    if (!this.client || this.snapshot.busy) return;
    const lifetime = this.lifetime;
    this.set({ busy: true, ...(this.snapshot.notice?.kind === "error" ? { notice: undefined } : {}) });
    try {
      await op(this.client);
    } catch (error) {
      if (lifetime === this.lifetime) this.fail(error);
    }
    if (lifetime !== this.lifetime) return;
    await this.reload();
    this.set({ busy: false });
  }

  private fail(error: unknown): void {
    const message = error instanceof Error ? error.message : String(error);
    this.noticeIsRead = false;
    this.set({ notice: { kind: "error", message } });
  }

  private set(patch: Partial<StashSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}
