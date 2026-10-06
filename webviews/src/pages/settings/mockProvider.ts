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
  type BrowserProfile,
  type HostLists,
  type AccountsRow,
  type AccountsRun,
  type AccountsState,
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
      "cmux.settings.host.lists": () => this.host,
      "cmux.settings.accounts.state": () => this.accounts,
      "cmux.settings.theme.set": (params) => {
        const { level, spec } = params as { level: string; spec: string | null };
        const theme = this.host.theme!;
        this.setHost({ ...this.host, theme: { ...theme, current: { ...theme.current, [level]: spec } } });
        return {};
      },
      "cmux.settings.theme.accepts": (params) => ({ accepts: String((params as { text: string }).text).includes(":") }),
      "cmux.settings.file.reveal": () => ({}),
      "cmux.settings.section.actions": (params) =>
        String((params as { section: string }).section) === "general"
          ? [{ id: "palette.welcomeChecklist", title: "Welcome Checklist", enabled: true }]
          : [],
      "cmux.settings.folders.add": (params) => {
        const key = String((params as { key: string }).key);
        const current = Array.isArray(this.values.get(key)) ? (this.values.get(key) as string[]) : [];
        const added = this.pickedFolders.filter((folder) => !current.includes(folder));
        if (added.length > 0) {
          this.values.set(key, [...current, ...added]);
          this.commit([key], "user");
        }
        return { added };
      },
      "cmux.settings.accounts.run": (params) => this.runAccounts(params as AccountsRun),
      "cmux.app.action.run": (params) => {
        // The page bridge allows this page only its declared actions.
        if (
          !(settingsPageActions as readonly string[]).includes(params.action as string) &&
          params.action !== "palette.welcomeChecklist"
        ) {
          throw new ProtocolError("cmux.page.action_refused", `action ${String(params.action)} is not allowed here`);
        }
        this.runProfileAction(
          params.action as string,
          (params.args ?? {}) as Params,
          params.target as string | undefined,
        );
        return {};
      },
    };
    const native = new Set([
      "cmux.settings.preview",
      "cmux.settings.preview.end",
      "cmux.settings.sound.play",
      "cmux.settings.host.lists",
      "cmux.settings.accounts.state",
      "cmux.settings.accounts.run",
      "cmux.settings.theme.set",
      "cmux.settings.theme.accepts",
      "cmux.settings.file.reveal",
      "cmux.settings.folders.add",
      "cmux.settings.section.actions",
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
    session.provide("cmux.settings.host.changed", (ctx) => this.track(this.hostChanged, ctx));
    session.provide("cmux.settings.accounts.changed", (ctx) => this.track(this.accountsChanged, ctx));
  }

  /** What the cmux picker returns for Add Folder… (tests set it). */
  pickedFolders: string[] = ["~/src"];

  /** The app's live lists (spaces, machines, browser profiles) as the host serves them. */
  host: HostLists = {
    rooms: [
      { id: "default", title: "Default", subtitle: null, active: true },
      { id: "work", title: "Work", subtitle: null, active: false },
    ],
    machines: [{ id: "ssh:build", title: "build-mac", subtitle: "cmux@build-mac", active: true }],
    browser_profiles: [
      { id: "p-default", name: "Default", color: null, icon: null, is_default: true, source: null },
      { id: "p-work", name: "Work", color: "green", icon: null, is_default: false, source: "Google Chrome · Work" },
    ],
    profile_colors: [
      { name: "grey", swatch: "#8E8E93", fill: "#C7C7CC" },
      { name: "green", swatch: "#5E9A6A", fill: "#B5D6BB" },
      { name: "orange", swatch: "#B07A45", fill: "#E0C3A3" },
    ],
    theme: { levels: ["room", "workspace", "terminal"], current: { room: null, workspace: "Dracula", terminal: null } },
    terminal: { ghostty_config: "~/.config/ghostty/config", shell_integration: "zsh" },
    ghostty_diagnostics: [],
    settings_file: "/Users/me/.config/cmux/cmux-next.json",
    backdrops: [{ id: "starryNight", title: "The Starry Night", attribution: "Van Gogh, 1889" }],
  };
  private readonly hostChanged = new Set<EventSourceContext>();
  private readonly accountsChanged = new Set<EventSourceContext>();

  /** The Accounts part as the app serves it (texts already localized). */
  accounts: AccountsState = {
    intro: "cmux checks this Mac for sign-ins and keys.",
    refresh: "Refresh",
    refreshing: false,
    signIn: null,
    problem: null,
    removeTitle: "Remove from CodeRouter",
    groups: [
      {
        id: "chatGPT",
        title: "ChatGPT and Codex",
        rows: [
          {
            provider: "codex",
            name: "Codex",
            detail: "pro · From ~/.codex/auth.json",
            status: "Signed in",
            statusKind: "success",
            busy: false,
            buttons: [
              { id: "reauth", title: "Re-authenticate", disabled: false, help: null, destructive: false },
              { id: "connect", title: "Connect to CodeRouter", disabled: false, help: null, destructive: false },
            ],
            unsupported: null,
            linked: [{ id: "acct-1", label: "s…@e…", state: "healthy", healthy: true, busy: false }],
            note: null,
            outcome: null,
            confirm: null,
            paste: null,
          },
        ],
      },
      {
        id: "other",
        title: "Other Providers",
        rows: [
          {
            provider: "openrouter",
            name: "OpenRouter",
            detail: null,
            status: "Not found",
            statusKind: "quiet",
            busy: false,
            buttons: [{ id: "addKey", title: "Add Key…", disabled: false, help: null, destructive: false }],
            unsupported: null,
            linked: [],
            note: null,
            outcome: null,
            confirm: null,
            paste: null,
          },
        ],
      },
    ],
  };
  /** Accounts gestures the page sent (secrets included, so tests can check they were sent once). */
  readonly accountRuns: AccountsRun[] = [];

  /** What the app's AccountsModel does to the state (enough for the page's tests). */
  private runAccounts(run: AccountsRun): { error?: string } {
    this.accountRuns.push(run);
    const rows = (edit: (row: AccountsRow) => AccountsRow) => ({
      ...this.accounts,
      groups: this.accounts.groups.map((group) => ({ ...group, rows: group.rows.map(edit) })),
    });
    const paste = {
      title: "Add a key",
      body: "Paste the key.",
      placeholder: "Paste here",
      buttons: [
        { id: "saveKeychain", title: "Save to Keychain", disabled: false, help: null, destructive: false },
        { id: "cancelPaste", title: "Cancel", disabled: false, help: null, destructive: false },
      ],
    };
    let error: string | undefined;
    if (run.action === "addKey") {
      this.accounts = rows((row) => (row.provider === run.provider ? { ...row, paste } : row));
    } else if (run.action === "cancelPaste") {
      this.accounts = rows((row) => ({ ...row, paste: null }));
    } else if (run.action === "saveKeychain") {
      if (run.secret === "bad") error = "That is not a valid key or token for this provider.";
      else
        this.accounts = rows((row) =>
          row.provider === run.provider ? { ...row, paste: null, status: "Key found", statusKind: "success" } : row,
        );
    } else if (run.action === "remove") {
      this.accounts = rows((row) => ({ ...row, linked: row.linked.filter((account) => account.id !== run.account) }));
    }
    for (const ctx of this.accountsChanged) ctx.emit(this.accounts);
    return error ? { error } : {};
  }

  /** Replaces the host lists and sends `cmux.settings.host.changed`. */
  setHost(host: HostLists): void {
    this.host = host;
    for (const ctx of this.hostChanged) ctx.emit(host);
  }

  /** What the app's `browserProfile.*` actions do to the lists (enough for the page's tests). */
  private runProfileAction(action: string, args: Params, target: string | undefined): void {
    const id = target?.startsWith("browser-profile:") ? target.slice("browser-profile:".length) : null;
    const profiles = this.host.browser_profiles;
    const edit = (patch: Partial<BrowserProfile>) =>
      profiles.map((profile) => (profile.id === id ? { ...profile, ...patch } : profile));
    let next = profiles;
    if (action === "browserProfile.new") {
      next = [
        ...profiles,
        {
          id: `p-${profiles.length + 1}`,
          name: `Profile ${profiles.length + 1}`,
          color: null,
          icon: null,
          is_default: false,
          source: null,
        },
      ];
    } else if (action === "browserProfile.rename") next = edit({ name: String(args.name) });
    else if (action === "browserProfile.setColor") next = edit({ color: String(args.color) });
    else if (action === "browserProfile.clearColor") next = edit({ color: null });
    else if (action === "browserProfile.setIcon") next = edit({ icon: String(args.icon) });
    else if (action === "browserProfile.clearIcon") next = edit({ icon: null });
    else if (action === "browserProfile.delete") next = profiles.filter((profile) => profile.id !== id);
    else return;
    this.setHost({ ...this.host, browser_profiles: next });
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
