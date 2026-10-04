// The Passwords page's state owner on the page side: the profile, the three lists, the query and
// the intents. The lists are projections of the app's store (`cmux.passwords.*`); the page keeps
// no optimistic copy and never holds a password: reveal, copy and export happen in native sheets,
// and the page only learns that they finished. React reads it through `useSyncExternalStore`.
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
import type { SortMode } from "./model";
import {
  PasswordCodes,
  PasswordOps,
  type ChangedEvent,
  type PasswordException,
  type Profile,
  type SavedPasskey,
  type SavedPassword,
  type Sections,
  type StateResult,
} from "./types";

export type Connection = "connecting" | "connected" | "disconnected";

export type Notice = { kind: "failed"; message: string } | { kind: "copied" } | { kind: "exported" };

export interface PasswordsSnapshot {
  connection: Connection;
  /** True until the first lists arrive. */
  loading: boolean;
  profiles: Profile[];
  profile: string;
  sections: Sections;
  passwords: SavedPassword[];
  passkeys: SavedPasskey[];
  exceptions: PasswordException[];
  text: string;
  sort: SortMode;
  /** The sign-in whose username is in the inline editor. */
  editing?: string;
  notice?: Notice;
}

export interface PasswordsStoreOptions {
  newKey?: () => string;
}

const NO_SECTIONS: Sections = { passwords: false, passkeys: false, exceptions: false, export: false };

export class PasswordsStore {
  private snapshot: PasswordsSnapshot;
  private readonly listeners = new Set<() => void>();
  private generation = 0;
  private stops: Array<() => void> = [];
  private started = false;

  constructor(
    private readonly client: PageClient | null,
    private readonly options: PasswordsStoreOptions = {},
  ) {
    this.snapshot = {
      connection: client ? "connecting" : "disconnected",
      loading: client !== null,
      profiles: [],
      profile: "default",
      sections: NO_SECTIONS,
      passwords: [],
      passkeys: [],
      exceptions: [],
      text: "",
      sort: "site",
    };
  }

  getSnapshot = (): PasswordsSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Not built yet: the page stays empty. */
  async start(): Promise<void> {}

  stop(): void {}

  async reload(): Promise<void> {}

  setText(_text: string): void {}

  setSort(_sort: SortMode): void {}

  resetQuery(): void {}

  setProfile(_profile: string): void {}

  dismissNotice(): void {}

  editUsername(_row: SavedPassword): void {}

  cancelEdit(): void {}

  async commitUsername(_row: SavedPassword, _text: string): Promise<void> {}

  async removePassword(_row: SavedPassword): Promise<void> {}

  async removePasskey(_row: SavedPasskey): Promise<void> {}

  async removeException(_row: PasswordException): Promise<void> {}

  async reveal(_row: SavedPassword): Promise<void> {}

  async copy(_row: SavedPassword): Promise<void> {}

  async exportAll(): Promise<void> {}

  private set(patch: Partial<PasswordsSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

function failure(error: unknown): Partial<PasswordsSnapshot> {
  if (isPageError(error) && error.code === LINK_CLOSED) return { connection: "disconnected" };
  return { notice: { kind: "failed", message: error instanceof Error ? error.message : String(error) } };
}
