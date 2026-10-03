// The page's view of the daemon's settings. One immutable state object, replaced on each
// change and read with useSyncExternalStore. Writes go straight to the transport; while the
// daemon is unreachable they are refused here and nothing queues.
import { rowsByKey } from "./schema";
import type { Diagnostic, Domains, ListRow, ManagedInfo, NativeTarget, SettingsTransport, WireError } from "./wire";
import { isErrorReply } from "./wire";

export type RowError = { code: string; message: string };

export type SettingsState = {
  loaded: boolean;
  connected: boolean;
  revision: number;
  rows: ReadonlyMap<string, ListRow>;
  diagnostics: ReadonlyMap<string, string[]>;
  managed: ReadonlyMap<string, ManagedInfo>;
  errors: ReadonlyMap<string, RowError>;
  domains: Domains;
};

export type WriteResult = { ok: true } | { ok: false; error: WireError };

const emptyDomains: Domains = { themes: [], font_families: [], sounds: [] };

export class SettingsStore {
  private state: SettingsState = {
    loaded: false,
    connected: true,
    revision: 0,
    rows: new Map(),
    diagnostics: new Map(),
    managed: new Map(),
    errors: new Map(),
    domains: emptyDomains,
  };
  private readonly listeners = new Set<() => void>();
  private refreshSequence = 0;
  private readonly unsubscribe: () => void;

  constructor(private readonly transport: SettingsTransport) {
    this.unsubscribe = transport.subscribe((event) => {
      if (event.type === "connection") {
        this.update({ connected: event.connected });
        if (event.connected) void this.refresh();
      } else if (event.type === "settings.changed" && event.revision > this.state.revision) {
        void this.refresh();
      }
    });
  }

  dispose(): void {
    this.unsubscribe();
    this.listeners.clear();
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): SettingsState => this.state;

  setDomains(domains: Partial<Domains> | null | undefined): void {
    this.update({ domains: { ...emptyDomains, ...domains } });
  }

  /** Fetches rows and the snapshot; an older response never replaces a newer one. */
  async refresh(): Promise<void> {
    const sequence = ++this.refreshSequence;
    const [list, snapshot] = await Promise.all([
      this.transport.request("settings.list", {}),
      this.transport.request("settings.snapshot", {}),
    ]);
    if (sequence !== this.refreshSequence) return;
    if (isErrorReply(list) || isErrorReply(snapshot)) {
      const error = isErrorReply(list) ? list.error : isErrorReply(snapshot) ? snapshot.error : null;
      this.update({ loaded: true, connected: error?.code === "unavailable" ? false : this.state.connected });
      return;
    }
    this.update({
      loaded: true,
      connected: true,
      revision: Math.max(list.revision, snapshot.revision),
      rows: new Map(list.rows.map((row) => [row.key, row])),
      managed: new Map(Object.entries(snapshot.managed ?? {})),
      diagnostics: diagnosticsByKey(snapshot.diagnostics ?? []),
    });
  }

  async set(key: string, value: unknown): Promise<WriteResult> {
    return this.write(key, () => this.transport.request("settings.set", { key, value }));
  }

  async reset(key: string): Promise<WriteResult> {
    return this.write(key, () => this.transport.request("settings.reset", { key }));
  }

  async resetAll(): Promise<WriteResult> {
    return this.write(null, () => this.transport.request("settings.reset_all", {}));
  }

  preview(key: string, value: unknown): void {
    if (this.state.connected) void this.transport.request("preview", { key, value });
  }

  previewEnd(key: string): void {
    void this.transport.request("preview.end", { key });
  }

  openNative(target: NativeTarget, section?: string): void {
    void this.transport.request("native.open", section ? { target, section } : { target });
  }

  playSound(name: string): void {
    void this.transport.request("sound.play", { name });
  }

  private async write(key: string | null, send: () => Promise<unknown>): Promise<WriteResult> {
    if (!this.state.connected) {
      return { ok: false, error: { code: "unavailable", message: "cmux is not connected" } };
    }
    const reply = await send();
    if (isErrorReply(reply)) {
      const { error } = reply;
      if (error.code === "unavailable") this.update({ connected: false });
      if (error.code === "revision_conflict") void this.refresh();
      else if (key) this.setError(key, { code: error.code, message: errorText(error) });
      return { ok: false, error };
    }
    if (key) this.setError(key, null);
    await this.refresh();
    return { ok: true };
  }

  private setError(key: string, error: RowError | null): void {
    if (!error && !this.state.errors.has(key)) return;
    const errors = new Map(this.state.errors);
    if (error) errors.set(key, error);
    else errors.delete(key);
    this.update({ errors });
  }

  private update(patch: Partial<SettingsState>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }
}

function errorText(error: WireError): string {
  const details = error.details as { reason?: unknown } | undefined;
  return error.code === "managed" && typeof details?.reason === "string" ? details.reason : error.message;
}

/** Diagnostics keyed by schema row: the row whose key equals the path or is its prefix. */
function diagnosticsByKey(diagnostics: Diagnostic[]): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const diagnostic of diagnostics) {
    const path = Array.isArray(diagnostic.path) ? diagnostic.path.join(".") : diagnostic.path;
    let key = path;
    while (key && !rowsByKey.has(key)) key = key.includes(".") ? key.slice(0, key.lastIndexOf(".")) : "";
    if (!key) continue;
    out.set(key, [...(out.get(key) ?? []), diagnostic.message]);
  }
  return out;
}

/** The managed info of a row, from settings.list or the snapshot. */
export function managedOf(state: SettingsState, key: string): ManagedInfo | null {
  return state.rows.get(key)?.managed ?? state.managed.get(key) ?? null;
}

/** The current value of a row, falling back to the schema default before the first list. */
export function valueOf(state: SettingsState, key: string): unknown {
  const row = state.rows.get(key);
  return row ? row.value : rowsByKey.get(key)?.default;
}
