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

  /** Subscribes to the change stream and the page streams, then loads. Idempotent. */
  async start(): Promise<void> {
    if (!this.client || this.started) return;
    this.started = true;
    try {
      this.stops.push(
        await this.client.subscribe<ChangedEvent>(PasswordOps.changed, (event) => {
          if (event.profile === this.snapshot.profile) void this.reload();
        }),
      );
      this.stops.push(
        await subscribePageStreams(this.client, { onConnection: (connected) => this.onConnection(connected) }),
      );
    } catch (error) {
      this.set({ loading: false, ...failure(error) });
      return;
    }
    if (!this.started) {
      this.stop();
      return;
    }
    await this.reload();
  }

  stop(): void {
    this.started = false;
    for (const stop of this.stops) stop();
    this.stops = [];
  }

  private onConnection(connected: boolean): void {
    if (!connected) {
      this.set({ connection: "disconnected", loading: false });
    } else if (this.snapshot.connection === "disconnected") {
      this.set({ connection: "connecting" });
      void this.reload();
    }
  }

  /** Reads the capabilities and profiles, then every list the build can serve. */
  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    try {
      const state = await this.client.call<StateResult>(PasswordOps.state, {});
      if (generation !== this.generation) return;
      const known = state.profiles.some((profile) => profile.id === this.snapshot.profile);
      const profile = known ? this.snapshot.profile : state.profile;
      const sections = { ...state.sections };
      const [passwords, passkeys, exceptions] = await Promise.all([
        this.list<{ passwords: SavedPassword[] }>(sections, "passwords", PasswordOps.list, profile),
        this.list<{ passkeys: SavedPasskey[] }>(sections, "passkeys", PasswordOps.passkeysList, profile),
        this.list<{ exceptions: PasswordException[] }>(sections, "exceptions", PasswordOps.exceptionsList, profile),
      ]);
      if (generation !== this.generation) return;
      this.set({
        connection: "connected",
        loading: false,
        profiles: state.profiles,
        profile,
        sections,
        passwords: passwords?.passwords ?? [],
        passkeys: passkeys?.passkeys ?? [],
        exceptions: exceptions?.exceptions ?? [],
      });
    } catch (error) {
      if (generation !== this.generation) return;
      this.set({ loading: false, ...failure(error) });
    }
  }

  /** One list, or null when the section is not available (a refusal marks it unavailable). */
  private async list<R>(sections: Sections, name: keyof Sections, op: string, profile: string): Promise<R | null> {
    if (!sections[name] || !this.client) return null;
    try {
      return await this.client.call<R>(op, { profile });
    } catch (error) {
      if (isPageError(error) && error.code === PasswordCodes.unavailable) {
        sections[name] = false;
        return null;
      }
      throw error;
    }
  }

  // Query.

  setText(text: string): void {
    if (text !== this.snapshot.text) this.set({ text });
  }

  setSort(sort: SortMode): void {
    if (sort !== this.snapshot.sort) this.set({ sort });
  }

  /** The `reset` page command. */
  resetQuery(): void {
    this.set({ text: "", editing: undefined });
  }

  setProfile(profile: string): void {
    if (profile === this.snapshot.profile) return;
    this.set({ profile, editing: undefined, passwords: [], passkeys: [], exceptions: [], loading: true });
    void this.reload();
  }

  dismissNotice(): void {
    if (this.snapshot.notice) this.set({ notice: undefined });
  }

  // Inline username editor.

  editUsername(row: SavedPassword): void {
    this.set({ editing: row.id });
  }

  cancelEdit(): void {
    if (this.snapshot.editing) this.set({ editing: undefined });
  }

  async commitUsername(row: SavedPassword, text: string): Promise<void> {
    this.set({ editing: undefined });
    const username = text.trim();
    if (username === row.username) return;
    await this.write(PasswordOps.usernameSet, { id: row.id, username });
  }

  // Writes and native steps. Each asks the app; the app shows its own sheet.

  async removePassword(row: SavedPassword): Promise<void> {
    await this.write(PasswordOps.remove, { ids: [row.id] });
  }

  async removePasskey(row: SavedPasskey): Promise<void> {
    await this.write(PasswordOps.passkeyRemove, { id: row.id });
  }

  async removeException(row: PasswordException): Promise<void> {
    await this.write(PasswordOps.exceptionRemove, { id: row.id });
  }

  async reveal(row: SavedPassword): Promise<void> {
    await this.native(PasswordOps.reveal, { id: row.id });
  }

  async copy(row: SavedPassword): Promise<void> {
    if (await this.native(PasswordOps.copy, { id: row.id })) this.set({ notice: { kind: "copied" } });
  }

  async exportAll(): Promise<void> {
    if (await this.write(PasswordOps.export, {}, false)) this.set({ notice: { kind: "exported" } });
  }

  /** A native step that changes nothing (reveal, copy): no idempotency key, no reload. */
  private async native(op: string, params: Record<string, unknown>): Promise<boolean> {
    if (!this.client) return false;
    try {
      await this.client.call(op, { profile: this.snapshot.profile, ...params });
    } catch (error) {
      this.report(error);
      return false;
    }
    if (this.snapshot.notice?.kind === "failed") this.set({ notice: undefined });
    return true;
  }

  private async write(op: string, params: Record<string, unknown>, reload = true): Promise<boolean> {
    if (!this.client) return false;
    try {
      await this.client.call(op, { profile: this.snapshot.profile, ...params, idempotency_key: this.key() });
    } catch (error) {
      this.report(error);
      return false;
    }
    if (this.snapshot.notice?.kind === "failed") this.set({ notice: undefined });
    // The app also sends `cmux.passwords.changed`; re-reading keeps the page right when it is late.
    if (reload) await this.reload();
    return true;
  }

  /** A declined sheet is the person's answer, not a failure. */
  private report(error: unknown): void {
    if (isPageError(error) && error.code === PasswordCodes.cancelled) return;
    if (isPageError(error) && error.code === PasswordCodes.unavailable) {
      this.set({ notice: { kind: "failed", message: error.message } });
      void this.reload();
      return;
    }
    this.set(failure(error));
  }

  private key(): string {
    return this.options.newKey?.() ?? crypto.randomUUID();
  }

  private set(patch: Partial<PasswordsSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

function failure(error: unknown): Partial<PasswordsSnapshot> {
  if (isPageError(error) && error.code === LINK_CLOSED) return { connection: "disconnected" };
  return { notice: { kind: "failed", message: error instanceof Error ? error.message : String(error) } };
}
