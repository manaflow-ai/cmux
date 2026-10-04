// A mock `cmux.settings` provider on a pane-protocol Session, for the browser dev loop and the
// tests. It behaves like the daemon's config owner as the page bridge relays it: one user
// layer, one managed fixture key, a revision counter, kind validation, a
// `cmux.settings.changed` event per write, idempotency keys required on writes, and error
// codes `cmux.settings.<code>`. Native ops are recorded in `log`.
//
// `createMockClient` connects a page client to it over the protocol's in-memory transport
// pair, so the page's calls cross the real envelope (call/ok/err/sub/ev).
import { createMockPair } from "../../protocol/adapters/mock";
import { ProtocolError, ProtocolErrorCode } from "../../protocol/errors";
import { Session, type EventSourceContext } from "../../protocol/session";
import {
  settingsPageActions,
  type Diagnostic,
  type Domains,
  type ListRow,
  type ManagedInfo,
  type MutationResult,
  type SettingsClient,
  type SnapshotResult,
} from "./ops";
import { rowsByKey, schema } from "./schema";
import { validate } from "./validate";

export type MockOptions = {
  managed?: Record<string, { value: unknown } & ManagedInfo>;
  values?: Record<string, unknown>;
  diagnostics?: Diagnostic[];
  /** `null`: the app published no domains (the daemon refuses publishes until it can attest the app). */
  domains?: Domains | null;
  connected?: boolean;
  /** Ops that fail with this code, to test read failures. */
  failing?: Partial<Record<string, string>>;
};

export const mockDomains: Domains = {
  themes: ["Catppuccin Mocha", "Dracula", "GitHub Light", "Gruvbox Dark", "Solarized Light", "Tokyo Night"],
  font_families: ["Berkeley Mono", "Iosevka", "JetBrains Mono", "Menlo", "SF Mono"],
  sounds: ["default", "Basso", "Funk", "Glass", "Ping", "Submarine", "none"],
};

/** The fixture managed key: a device profile pins remote localhost forwarding off. */
export const mockManagedKey = "browser.remoteLocalhost";

type Params = Record<string, unknown>;

export class MockSettingsProvider {
  readonly log: Array<{ op: string; params: unknown }> = [];
  revision = 1;
  diagnostics: Diagnostic[];
  readonly domains: Domains | null;
  private readonly failing: Partial<Record<string, string>>;
  private readonly values = new Map<string, unknown>();
  private readonly managed: Map<string, { value: unknown } & ManagedInfo>;
  private readonly changed = new Set<EventSourceContext>();
  private readonly connection = new Set<EventSourceContext>();
  private readonly commands = new Set<EventSourceContext>();
  private readonly usedKeys = new Map<string, string>();
  private connected: boolean;

  constructor(options: MockOptions = {}) {
    this.managed = new Map(
      Object.entries(
        options.managed ?? {
          [mockManagedKey]: { value: false, source: "profile", reason: "Set by your organization's profile" },
        },
      ),
    );
    for (const [key, value] of Object.entries(options.values ?? {})) this.values.set(key, value);
    this.diagnostics = options.diagnostics ?? [];
    this.domains = options.domains === undefined ? mockDomains : options.domains;
    this.failing = options.failing ?? {};
    this.connected = options.connected ?? true;
  }

  /** Registers every op and stream on `session` (the provider side). */
  serve(session: Session): void {
    const ops: Record<string, (params: Params) => unknown> = {
      "cmux.settings.list": (params) => this.list(params.section as string | undefined),
      "cmux.settings.snapshot": () => this.snapshot(),
      "cmux.settings.set": (params) => this.keyed(params, () => this.set(params.key as string, params.value)),
      "cmux.settings.reset": (params) => this.keyed(params, () => this.reset(params.key as string)),
      "cmux.settings.reset_all": (params) => this.keyed(params, () => this.resetAll()),
      "cmux.settings.preview": () => ({}),
      "cmux.settings.preview.end": () => ({}),
      "cmux.settings.sound.play": () => ({}),
      "cmux.app.action.run": (params) => {
        // The page bridge allows this page only its declared actions.
        if (!(settingsPageActions as readonly string[]).includes(params.action as string)) {
          throw new ProtocolError("cmux.page.action_refused", `action ${String(params.action)} is not allowed here`);
        }
        return {};
      },
    };
    const native = new Set([
      "cmux.settings.preview",
      "cmux.settings.preview.end",
      "cmux.settings.sound.play",
      "cmux.app.action.run",
    ]);
    for (const [op, handler] of Object.entries(ops)) {
      session.register(op, (params) => {
        this.log.push({ op, params });
        if (!native.has(op) && !this.connected) {
          throw new ProtocolError(ProtocolErrorCode.closed, "cmux is not connected", { retryable: true });
        }
        const failure = this.failing[op];
        if (failure) throw new ProtocolError(failure, `${op} failed`);
        return handler((params ?? {}) as Params);
      });
    }
    session.provide("cmux.settings.changed", (ctx) => this.track(this.changed, ctx));
    session.provide("cmux.page.connection", (ctx) => this.track(this.connection, ctx));
    session.provide("cmux.page.command", (ctx) => this.track(this.commands, ctx));
  }

  /** Simulates the daemon going away or coming back. */
  setConnected(connected: boolean): void {
    this.connected = connected;
    for (const ctx of this.connection) ctx.emit({ connected });
  }

  /** Simulates the app's key dispatcher sending a page command. */
  sendCommand(command: "find" | "focusSearch" | "back" | "forward" | "reset"): void {
    for (const ctx of this.commands) ctx.emit({ command });
  }

  /** Simulates a write from another client (the CLI, a hand edit). */
  externalSet(key: string, value: unknown): void {
    this.values.set(key, value);
    this.commit([key], "cli");
  }

  private track(set: Set<EventSourceContext>, ctx: EventSourceContext): void {
    set.add(ctx);
    ctx.signal.addEventListener("abort", () => set.delete(ctx));
  }

  private list(section: string | undefined): ListRow[] {
    return schema.rows.filter((row) => !section || row.section === section).map((row) => this.row(row.key));
  }

  private snapshot(): SnapshotResult {
    return {
      revision: this.revision,
      schema_hash: schema.schema_hash,
      effective: this.effective(),
      managed: Object.fromEntries(
        [...this.managed].map(([key, { source, reason, team }]) => [key, { source, reason, team: team ?? null }]),
      ),
      diagnostics: this.diagnostics,
      domains: this.domains ?? { themes: null, font_families: null, sounds: null },
    };
  }

  private row(key: string): ListRow {
    const row = rowsByKey.get(key)!;
    const managed = this.managed.get(key);
    return {
      key,
      value: managed ? managed.value : this.values.has(key) ? this.values.get(key) : row.default,
      default: row.default,
      customized: this.values.has(key),
      managed: managed ? { source: managed.source, reason: managed.reason, team: managed.team ?? null } : null,
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

  /** Writes need an idempotency key; a retried key replays, a reused key with other params is refused. */
  private keyed(params: Params, write: () => MutationResult): MutationResult {
    const key = params.idempotency_key;
    if (typeof key !== "string" || key.length === 0) {
      throw new ProtocolError(ProtocolErrorCode.invalidParams, "idempotency_key is required");
    }
    const print = JSON.stringify({ ...params, idempotency_key: undefined });
    const used = this.usedKeys.get(key);
    if (used !== undefined && used !== print) {
      throw new ProtocolError("cmux.idempotency.conflict", `idempotency key ${key} was used for another request`);
    }
    this.usedKeys.set(key, print);
    return write();
  }

  private guard(key: string): void {
    if (!rowsByKey.has(key)) throw new ProtocolError("cmux.settings.invalid", `unknown setting ${key}`);
    const managed = this.managed.get(key);
    if (managed) {
      throw new ProtocolError("cmux.settings.managed", managed.reason, {
        details: { key, source: managed.source, reason: managed.reason },
      });
    }
  }

  private set(key: string, value: unknown): MutationResult {
    this.guard(key);
    const reason = validate(rowsByKey.get(key)!, value, this.domains ?? undefined);
    if (reason) throw new ProtocolError("cmux.settings.invalid", `${key}: ${reason}`, { details: { key, value } });
    this.values.set(key, value);
    return this.commit([key], "user");
  }

  private reset(key: string): MutationResult {
    this.guard(key);
    this.values.delete(key);
    return this.commit([key], "user");
  }

  private resetAll(): MutationResult {
    const keys = [...this.values.keys()].filter((key) => !rowsByKey.get(key)?.kept_on_reset_all);
    for (const key of keys) this.values.delete(key);
    return this.commit(keys, "user");
  }

  private commit(keys: string[], origin: string): MutationResult {
    this.revision += 1;
    const revision = this.revision;
    // The daemon emits after the reply; a microtask keeps that order.
    queueMicrotask(() => {
      for (const ctx of this.changed) ctx.emit({ revision, keys, origin });
    });
    return { value: { keys }, revision: String(revision), replayed: false };
  }
}

/** A page client over a pane-protocol Session (the shape pageClient.ts exposes). */
export function sessionClient(session: Session): SettingsClient {
  return {
    call: <R>(op: string, params: unknown, opts?: { signal?: AbortSignal }) =>
      session.call(op, params, opts) as Promise<R>,
    async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      const subscription = await session.subscribe<E>(stream, { onEvent });
      return () => subscription.unsubscribe();
    },
  };
}

/** A page client connected to a fresh mock provider over the in-memory transport pair. */
export function createMockClient(options: MockOptions = {}): {
  client: SettingsClient;
  provider: MockSettingsProvider;
  close(): void;
} {
  const [pageSide, providerSide] = createMockPair();
  const page = new Session(pageSide, { role: "client" });
  const providerSession = new Session(providerSide, { role: "server" });
  const provider = new MockSettingsProvider(options);
  provider.serve(providerSession);
  return {
    client: sessionClient(page),
    provider,
    close() {
      page.close();
      providerSession.close();
    },
  };
}
