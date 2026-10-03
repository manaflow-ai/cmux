// In-memory transport for the dev server and the tests. It behaves like the daemon's config
// actor: one user layer seeded empty, one managed fixture key, a revision counter, kind
// validation, and a `settings.changed` event per write. Page-local ops are recorded in `log`.
import { rowsByKey, schema } from "./schema";
import { validate } from "./validate";
import type {
  Diagnostic,
  Domains,
  ErrorReply,
  ListRow,
  ManagedInfo,
  OpName,
  Ops,
  ReadyReply,
  SettingsEvent,
  SettingsTransport,
} from "./wire";

export type FakeOptions = {
  managed?: Record<string, { value: unknown } & ManagedInfo>;
  values?: Record<string, unknown>;
  diagnostics?: Diagnostic[];
  domains?: Domains;
  locale?: string;
  initialRoute?: string | null;
  connected?: boolean;
};

export const fakeDomains: Domains = {
  themes: ["Catppuccin Mocha", "Dracula", "GitHub Light", "Gruvbox Dark", "Solarized Light", "Tokyo Night"],
  font_families: ["Berkeley Mono", "Iosevka", "JetBrains Mono", "Menlo", "SF Mono"],
  sounds: ["default", "Basso", "Funk", "Glass", "Ping", "Submarine", "none"],
};

/** The fixture managed key: a device profile pins remote localhost forwarding off. */
export const fakeManagedKey = "browser.remoteLocalhost";

export class FakeTransport implements SettingsTransport {
  readonly log: Array<{ op: OpName; params: unknown }> = [];
  revision = 1;
  private readonly values = new Map<string, unknown>();
  private readonly managed: Map<string, { value: unknown } & ManagedInfo>;
  private readonly listeners = new Set<(event: SettingsEvent) => void>();
  private connected: boolean;
  diagnostics: Diagnostic[];
  readonly domains: Domains;
  private readonly locale: string;
  private readonly initialRoute: string | null;

  constructor(options: FakeOptions = {}) {
    this.managed = new Map(
      Object.entries(
        options.managed ?? {
          [fakeManagedKey]: { value: false, source: "profile", reason: "Set by your organization's profile" },
        },
      ),
    );
    for (const [key, value] of Object.entries(options.values ?? {})) this.values.set(key, value);
    this.diagnostics = options.diagnostics ?? [];
    this.domains = options.domains ?? fakeDomains;
    this.locale = options.locale ?? "en";
    this.initialRoute = options.initialRoute ?? null;
    this.connected = options.connected ?? true;
  }

  subscribe(listener: (event: SettingsEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** Simulates the daemon going away or coming back. */
  setConnected(connected: boolean): void {
    this.connected = connected;
    this.emit({ type: "connection", connected });
  }

  request<K extends OpName>(op: K, params: Ops[K][0]): Promise<Ops[K][1] | ErrorReply> {
    this.log.push({ op, params });
    return Promise.resolve(this.handle(op, params as Record<string, unknown>) as Ops[K][1] | ErrorReply);
  }

  private handle(op: OpName, params: Record<string, unknown>): unknown {
    switch (op) {
      case "ready":
        return {
          locale: this.locale,
          theme: null,
          domains: this.domains,
          initialRoute: this.initialRoute,
        } satisfies ReadyReply;
      case "preview":
      case "preview.end":
      case "native.open":
      case "sound.play":
        return {};
    }
    if (!this.connected) return failure("unavailable", "cmux is not connected");
    switch (op) {
      case "settings.list": {
        const section = params.section as string | undefined;
        return {
          revision: this.revision,
          rows: schema.rows.filter((row) => !section || row.section === section).map((row) => this.row(row.key)),
        };
      }
      case "settings.snapshot":
        return {
          revision: this.revision,
          effective: this.effective(),
          managed: Object.fromEntries(
            [...this.managed].map(([key, { source, reason }]) => [key, { source, reason }] as const),
          ),
          diagnostics: this.diagnostics,
          schema_hash: schema.schema_hash,
        };
      case "settings.set":
        return this.set(params.key as string, params.value);
      case "settings.reset":
        return this.reset(params.key as string);
      case "settings.reset_all": {
        const keys = [...this.values.keys()].filter((key) => !rowsByKey.get(key)?.kept_on_reset_all);
        for (const key of keys) this.values.delete(key);
        return this.commit(keys);
      }
    }
    return failure("invalid_params", `unknown op ${String(op)}`);
  }

  private row(key: string): ListRow {
    const row = rowsByKey.get(key)!;
    const managed = this.managed.get(key);
    return {
      key,
      value: managed ? managed.value : this.values.has(key) ? this.values.get(key) : row.default,
      default: row.default,
      customized: this.values.has(key),
      managed: managed ? { source: managed.source, reason: managed.reason } : null,
    };
  }

  private effective(): Record<string, unknown> {
    const root: Record<string, unknown> = {};
    for (const row of schema.rows) {
      const value = this.row(row.key).value;
      if (value === null || value === undefined) continue;
      let node = root;
      for (const part of row.path.slice(0, -1)) node = (node[part] ??= {}) as Record<string, unknown>;
      node[row.path.at(-1)!] = value;
    }
    return root;
  }

  private guard(key: string): ErrorReply | null {
    if (!rowsByKey.has(key)) return failure("invalid_params", `unknown setting ${key}`);
    const managed = this.managed.get(key);
    return managed ? failure("managed", managed.reason, { source: managed.source, reason: managed.reason }) : null;
  }

  private set(key: string, value: unknown): unknown {
    const refused = this.guard(key);
    if (refused) return refused;
    const reason = validate(rowsByKey.get(key)!, value, this.domains);
    if (reason) return failure("invalid_params", `${key}: ${reason}`, { key, value });
    this.values.set(key, value);
    return this.commit([key]);
  }

  private reset(key: string): unknown {
    const refused = this.guard(key);
    if (refused) return refused;
    this.values.delete(key);
    return this.commit([key]);
  }

  private commit(keys: string[]): { revision: number } {
    this.revision += 1;
    const revision = this.revision;
    // The daemon emits after the reply; a microtask keeps that order.
    queueMicrotask(() => this.emit({ type: "settings.changed", revision, keys }));
    return { revision };
  }

  private emit(event: SettingsEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}

function failure(code: string, message: string, details?: unknown): ErrorReply {
  return { error: { code, message, details } };
}
