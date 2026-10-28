// A mock `cmux.settings` provider on a pane-protocol Session, for the browser dev loop and the
// tests. It behaves like the daemon's config owner as the page bridge relays it: one user
// layer, one managed fixture key, a revision counter, kind validation, a
// `cmux.settings.changed` event per write, idempotency keys required on writes, and error
// codes `cmux.settings.<code>`. Native ops are recorded in `log`.
//
// `createMockClient` connects a page client to it over the protocol's in-memory transport
// pair, so the page's calls cross the real envelope (call/ok/err/sub/ev).
import { createMockPair } from "../../protocol/adapters/mock";
import { updatable } from "./harnesses";
import { recentAfterPick } from "./fontPickerModel";
import { ProtocolError, ProtocolErrorCode } from "../../protocol/errors";
import { Session, type EventSourceContext } from "../../protocol/session";
import {
  settingsPageActions,
  type BrowserProfile,
  type HostLists,
  type AccountsCmux,
  type AccountsRow,
  type AccountsRun,
  type AgentsRun,
  type AgentsState,
  type ChannelSwitch,
  type ChannelsState,
  type AccountsState,
  type DevicesRelay,
  type CloudEnvironmentsRun,
  type CloudEnvironmentsState,
  type DevicesRun,
  type DevicesRunResult,
  type DevicesState,
  type HarnessesRun,
  type HarnessesState,
  type IntegrationsRun,
  type IntegrationsState,
  type Diagnostic,
  type Domains,
  type ListRow,
  type ManagedInfo,
  type MuseumArtResult,
  type MutationResult,
  type SettingsClient,
  type SnapshotResult,
  type ThemeOverride,
  type WorkspaceBackground,
} from "./ops";
import { rowsByKey, schema } from "./schema";
import { withEdits, type ThemeEditMap } from "../../theme/themeEdits";
import { validate } from "./validate";
import { MockAgents } from "./mockAgents";
import { mockChannels } from "./mockChannels";
import { mockThemeColors } from "./mockThemes";
import type { GhosttyTheme } from "../../theme/ghosttyTheme";

export type MockOptions = {
  chatFolders?: ListRow["folders"];
  managed?: Record<string, { value: unknown } & ManagedInfo>;
  values?: Record<string, unknown>;
  diagnostics?: Diagnostic[];
  /** `null`: the app published no domains (the daemon refuses publishes until it can attest the app). */
  domains?: Domains | null;
  connected?: boolean;
  /** Ops that fail with this code, to test read failures. */
  failing?: Partial<Record<string, string>>;
  /** The loaded settings file's path (the host lists' `settings_file`). */
  settingsFile?: string;
  /** The theme file the mock picker returns for `cmux.settings.theme.import`. */
  importable?: GhosttyTheme;
  /** What `cmux.settings.art.search` finds (Browse More Art). */
  museumArt?: MuseumArtResult[];
  /** Workspaces with a background of their own, or following the app's (`value` null). */
  workspaceBackgrounds?: WorkspaceBackground[];
  /** Colors the Ghostty config sets itself (the host lists' `theme_overrides`). */
  themeOverrides?: ThemeOverride[];
};

export const mockDomains: Domains = {
  themes: [
    "Apple System Colors",
    "Apple System Colors Light",
    "Catppuccin Mocha",
    "Dracula",
    "GitHub Light",
    "Gruvbox Dark",
    "Solarized Light",
    "Tokyo Night",
  ],
  font_families: ["Berkeley Mono", "Iosevka", "JetBrains Mono", "Menlo", "SF Mono"],
  sounds: ["default", "Basso", "Funk", "Glass", "Ping", "Submarine", "none"],
  recent_fonts: ["JetBrains Mono"],
};

/** The fixture managed key: a device profile pins remote localhost forwarding off. */
export const mockManagedKey = "browser.remoteLocalhost";

type Params = Record<string, unknown>;

const cmuxButton = (id: string, title: string, destructive = false) => ({
  id,
  title,
  disabled: false,
  help: null,
  destructive,
});

/** cmux's own row as the app serves it: signed in, signed out, and a sign-in in progress. */
export const mockCmuxAccount: Record<"signedIn" | "signedOut" | "signingIn", AccountsCmux> = {
  signedIn: {
    title: "cmux Account",
    detail: "s…@e…",
    status: "Signed in",
    statusKind: "success",
    busy: false,
    buttons: [cmuxButton("cmux.switchAccount", "Switch Account…"), cmuxButton("cmux.signOut", "Sign Out", true)],
    note: null,
    error: null,
  },
  signedOut: {
    title: "cmux Account",
    detail: null,
    status: "Signed out",
    statusKind: "quiet",
    busy: false,
    buttons: [cmuxButton("cmux.signIn", "Sign In to cmux")],
    note: null,
    error: null,
  },
  signingIn: {
    title: "cmux Account",
    detail: null,
    status: "Signing in…",
    statusKind: "neutral",
    busy: true,
    buttons: [cmuxButton("cmux.continueInBrowser", "Open in Browser"), cmuxButton("cmux.cancelSignIn", "Cancel")],
    note: "Finish signing in in your browser. If no page opened, choose Open in Browser.",
    error: null,
  },
};

export class MockSettingsProvider {
  readonly log: Array<{ op: string; params: unknown }> = [];
  /** The colors `cmux.settings.theme.colors` answers (the gallery installs every bundled theme). */
  themeColors: GhosttyTheme[] = mockThemeColors;
  revision = 1;
  /** What `cmux.app.clipboard.write` last wrote. */
  clipboard: string | null = null;
  diagnostics: Diagnostic[];
  domains: Domains | null;
  /** The theme file the mock picker returns for `cmux.settings.theme.import`; null: the person left it. */
  importable: GhosttyTheme | null = null;
  private readonly importTokens = new Map<string, GhosttyTheme>();
  private readonly chatFolders: ListRow["folders"];
  private readonly failing: Partial<Record<string, string>>;
  private readonly values = new Map<string, unknown>();
  private readonly managed: Map<string, { value: unknown } & ManagedInfo>;
  private readonly changed = new Set<EventSourceContext>();
  private readonly connection = new Set<EventSourceContext>();
  private readonly commands = new Set<EventSourceContext>();
  private readonly usedKeys = new Map<string, string>();
  private connected: boolean;
  private museumArt: MuseumArtResult[];
  readonly workspaceBackgrounds = new Map<string, WorkspaceBackground>();

  constructor(options: MockOptions = {}) {
    this.chatFolders = options.chatFolders;
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
    if (options.settingsFile !== undefined) this.host = { ...this.host, settings_file: options.settingsFile };
    if (options.themeOverrides) this.host = { ...this.host, theme_overrides: options.themeOverrides };
    this.importable = options.importable ?? null;
    this.museumArt = options.museumArt ?? [];
    for (const background of options.workspaceBackgrounds ?? [])
      this.workspaceBackgrounds.set(background.workspace, background);
  }

  /** The ops and streams `serve` registered: a host that bridges this mock (the gallery stage) forwards
   * exactly these, so an op added here reaches the page without a second list to keep in step. */
  served: { ops: string[]; streams: string[] } = { ops: [], streams: [] };

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
      "cmux.settings.server.restart": () => ({}),
      "cmux.settings.server.pair": () => ({}),
      "cmux.settings.mobile.allow_again": () => {
        const iphone = this.host.iphone;
        if (iphone) this.setHost({ ...this.host, iphone: { ...iphone, phase: "connecting" } });
        return {};
      },
      "cmux.settings.mobile.answer_pair": (params) => {
        const iphone = this.host.iphone;
        if (iphone)
          this.setHost({
            ...this.host,
            iphone: { ...iphone, pending: (iphone.pending ?? []).filter((p) => p.id !== params.id) },
          });
        return {};
      },
      "cmux.settings.devices.remove": (params) => {
        const devices = this.host.devices;
        if (devices)
          this.setHost({ ...this.host, devices: { ...devices, rows: devices.rows.filter((r) => r.id !== params.id) } });
        return {};
      },
      "cmux.settings.devices.full_access": (params) => {
        const devices = this.host.devices;
        if (devices)
          this.setHost({
            ...this.host,
            devices: {
              ...devices,
              rows: devices.rows.map((r) =>
                r.id === params.id && r.full_access !== undefined ? { ...r, full_access: params.on === true } : r,
              ),
            },
          });
        return {};
      },
      "cmux.settings.machines.vm_host": (params) => {
        this.setHost({
          ...this.host,
          machines: this.host.machines.map((r) =>
            r.id === params.id && r.vm_host
              ? { ...r, vm_host: { ...r.vm_host, on: params.on === true, error: null } }
              : r,
          ),
        });
        return {};
      },
      "cmux.settings.mobile.remove_phone": (params) => {
        const iphone = this.host.iphone;
        if (iphone)
          this.setHost({
            ...this.host,
            iphone: { ...iphone, phones: iphone.phones.filter((p) => p.id !== params.id) },
          });
        return {};
      },
      // The fixture's way back is Nightly's whatever channel the card asks about, as a late
      // reply for an earlier pick would be: the card shows it only on the Nightly row.
      "cmux.settings.channels.state": () => {
        if (!this.channels) throw new ProtocolError("cmux.page.unavailable", "no updater");
        return { ...this.channels, switch: this.channelSwitch };
      },
      "cmux.settings.channels.go_back": (params) => {
        this.wentBack = params.build as string;
        return {};
      },
      "cmux.settings.channels.update_machine": (params) => {
        this.updatedMachines.push(params.id as string);
        return {};
      },
      "cmux.settings.agents.state": () => this.agents.state,
      "cmux.settings.agents.run": (params) => this.agents.run(params as unknown as AgentsRun),
      "cmux.settings.voice_input.set": (params) => {
        if (this.host.voice_input) this.setHost({ ...this.host, voice_input: { on: params.on === true } });
        return {};
      },
      // Agents > Chiefs (ChiefsCard): the host's page relay to the Chief owner and harness center.
      "cmux.chief.profile.list": () => ({ chiefs: this.chiefs }),
      "cmux.chief.profile.avatar.get": (params) => ({ avatar: this.chiefAvatars.get(params.chief as string) ?? null }),
      "cmux.chief.profile.history": (params) => ({
        chief: params.chief,
        revisions: this.chiefs
          .filter((chief) => chief.id === params.chief)
          .map((chief) => ({
            rev: chief.rev,
            at: "2026-10-10T09:00:00Z",
            actor: "",
            operation: "chief.profile.create",
            record: chief,
          })),
      }),
      "cmux.chief.profile.update": (params) => {
        const index = this.chiefs.findIndex((chief) => chief.id === params.chief);
        const { chief: _id, machine: _m, session: _s, idempotency_key: _k, harness, model, effort, ...fields } = params;
        const old = this.chiefs[index]!;
        const engine = {
          ...(old.engine as Params),
          ...(harness !== undefined ? { harness } : {}),
          ...(model !== undefined ? { model } : {}),
          ...(effort !== undefined ? { effort } : {}),
        };
        this.chiefs[index] = { ...old, ...fields, engine, rev: Number(old.rev) + 1 };
        return { value: this.chiefs[index] };
      },
      "cmux.chief.profile.create": (params) => {
        const made = {
          ...this.chiefs[0]!,
          id: `agent_new${this.chiefs.length}`,
          display_name: params.display_name,
          role: params.role ?? "",
          is_default: false,
          rev: 1,
          locked: params.locked === true,
        };
        this.chiefs.push(made);
        return { value: made };
      },
      "cmux.chief.backend.list": () => ({
        harnesses: {
          defaultHarness: "claude",
          harnesses: { claude: { displayName: "Claude Code" }, codex: { displayName: "Codex" } },
        },
        // Codex's probed models, named as acpmux names them; Claude's are not probed (read off the id).
        models: {
          harnesses: [
            {
              harness: "codex",
              models: [
                { id: "gpt-6-astra", name: "GPT-6 Astra", efforts: ["low", "medium", "high"] },
                { id: "gpt-6-astra-mini", name: "GPT-6 Astra Mini", efforts: ["low", "medium"] },
              ],
            },
          ],
        },
      }),
      "cmux.chief.backend.doctor": () => ({ ok: true, steps: [{ name: "prompt", ok: true }] }),
      "cmux.settings.theme.set": (params) => {
        const { level, spec } = params as { level: string; spec: string | null };
        const theme = this.host.theme!;
        this.setHost({ ...this.host, theme: { ...theme, current: { ...theme.current, [level]: spec } } });
        return {};
      },
      "cmux.settings.theme.colors": () => ({ themes: this.themeColors }),
      "cmux.settings.theme.save": (params) => {
        const { name, base, replace } = params as { name: string; base: string; replace: boolean };
        const colors = this.themeColors.find((theme) => theme.name === base);
        if (!colors) throw new ProtocolError("cmux.settings.theme.unknown_base", "the theme has no file");
        return this.addTheme(
          { ...withEdits(colors, this.values.get("appearance.themeEdits") as ThemeEditMap), name },
          replace,
        );
      },
      "cmux.settings.theme.import": (params) => {
        const { token, replace } = params as { token?: string; replace?: boolean };
        const file = token === undefined ? this.importable : this.importTokens.get(token);
        if (!file) return {};
        try {
          return this.addTheme(file, replace ?? false);
        } catch (error) {
          if (!(error instanceof ProtocolError) || error.code !== "cmux.settings.theme.exists") throw error;
          const retry = `token-${this.importTokens.size + 1}`;
          this.importTokens.set(retry, file);
          throw new ProtocolError(error.code, error.message, { details: { token: retry, name: file.name } });
        }
      },
      "cmux.settings.theme.accepts": (params) => ({ accepts: String((params as { text: string }).text).includes(":") }),
      "cmux.settings.theme.overrides.release": () => {
        const files = new Set((this.host.theme_overrides ?? []).map((override) => override.file)).size;
        this.setHost({ ...this.host, theme_overrides: [] });
        return { files };
      },
      "cmux.settings.theme.overrides.open": () => ({}),
      "cmux.settings.file.reveal": () => ({}),
      // The registry buttons SettingsSchema.actions(in:) lists for these sections.
      "cmux.settings.section.actions": (params) =>
        ({
          general: [{ id: "palette.makeDefaultTerminal", title: "Make cmux the Default Terminal", enabled: true }],
          advanced: [{ id: "reloadConfiguration", title: "Reload Configuration", enabled: true }],
        })[String((params as { section: string }).section)] ?? [],
      "cmux.settings.backdrop.choose_image": () => ({ id: null }),
      "cmux.settings.backdrop.wallpaper_settings": () => ({}),
      "cmux.settings.backdrop.image.link": (params) => {
        const url = String((params as { url: string }).url);
        if (!url.startsWith("https://"))
          throw new ProtocolError("cmux.settings.backdrop.not_https", "not an https link");
        if (url.endsWith(".txt")) throw new ProtocolError("cmux.settings.backdrop.not_media", "not an image or movie");
        const id = `file:/backgrounds/${url.split("/").pop()}`;
        const title = url.split("/").pop() ?? id;
        const own = { id, title, attribution: title, collection: "yours", collection_title: "Your images" };
        this.host = { ...this.host, backdrops: [own, ...(this.host.backdrops ?? [])] };
        this.values.set("appearance.background", id);
        return { id };
      },
      "cmux.settings.backdrop.image.remove": (params) => {
        const id = String((params as { id: string }).id);
        this.host = { ...this.host, backdrops: (this.host.backdrops ?? []).filter((row) => row.id !== id) };
        return { bytes: (this.host.backdrops ?? []).filter((row) => row.collection === "yours").length * 1_000_000 };
      },
      "cmux.settings.backdrop.image.reveal": () => ({}),
      "cmux.settings.backdrop.image.usage": () => ({
        bytes: (this.host.backdrops ?? []).filter((row) => row.collection === "yours").length * 1_000_000,
        folder: "/Users/me/Library/Application Support/cmux/Backgrounds",
      }),
      "cmux.settings.backdrop.image.folder": () => ({ id: null }),
      "cmux.settings.backdrop.workspace": (params) => this.workspaceBackground(String(params.workspace)),
      "cmux.settings.backdrop.workspace.set": (params) => {
        const workspace = this.workspaceBackground(String(params.workspace));
        const change =
          "opacity" in params
            ? { opacity: (params.opacity as number | null) ?? null }
            : { value: (params.value as string | null) ?? null };
        this.workspaceBackgrounds.set(workspace.workspace, { ...workspace, ...change });
        return {};
      },
      "cmux.settings.backdrop.workspace.preview": () => ({}),
      "cmux.settings.art.search": () => ({ results: this.museumArt }),
      "cmux.settings.art.use": () => ({ id: "" }),
      "cmux.settings.web_updates.check": () => ({}),
      "cmux.settings.web_updates.rollback": () => ({}),
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
      "cmux.settings.devices.state": () => this.devices,
      "cmux.settings.devices.run": (params) => this.runDevices(params as unknown as DevicesRun),
      "cmux.settings.environments.state": () => this.environments,
      "cmux.settings.environments.run": (params) => this.runEnvironments(params as unknown as CloudEnvironmentsRun),
      "cmux.settings.harnesses.state": () => this.harnesses,
      "cmux.settings.harnesses.run": (params) => {
        const run = params as HarnessesRun;
        if (
          (run.action === "signIn" || run.action === "check" || run.action === "autoUpdate") &&
          !this.harnesses.harnesses.some((h) => h.id === run.id)
        ) {
          throw new ProtocolError("cmux.settings.invalid", "id must be a listed harness");
        }
        // Like the host: only an outdated harness that needs no sudo updates.
        const canUpdate = updatable(this.harnesses);
        if (
          (run.action === "update" && !canUpdate.some((h) => h.id === run.id)) ||
          (run.action === "updateAll" && canUpdate.length === 0)
        ) {
          throw new ProtocolError("cmux.settings.invalid", "no harness can be updated here");
        }
        this.harnessRuns.push(run);
        return {};
      },
      "cmux.settings.integrations.state": () => this.integrations,
      "cmux.settings.integrations.run": (params) => {
        const run = params as IntegrationsRun;
        if (run.action === "refresh") return {};
        const row = this.integrations.providers.find((entry) => entry.id === run.id);
        // Like the host: only a listed provider, and never an install over a conflict.
        if (!row) throw new ProtocolError("cmux.settings.invalid", "id must be a listed provider");
        if (run.action !== "remove" && (row.state === "conflict" || row.state === "unavailable")) {
          throw new ProtocolError("cmux.settings.invalid", `${row.id} has a file cmux did not create in the way`);
        }
        this.integrationRuns.push(run);
        const state = run.action === "remove" ? "absent" : "installed";
        this.integrations = {
          ...this.integrations,
          providers: this.integrations.providers.map((entry) =>
            entry.id === row.id ? { ...entry, state, error: null } : entry,
          ),
        };
        return {};
      },
      "cmux.app.clipboard.write": (params) => {
        this.clipboard = String(params.text);
        return {};
      },
      "cmux.app.action.run": (params) => {
        // The page bridge allows this page only its declared actions.
        if (
          !(settingsPageActions as readonly string[]).includes(params.action as string) &&
          params.action !== "palette.makeDefaultTerminal"
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
      "cmux.settings.devices.remove",
      "cmux.settings.devices.full_access",
      "cmux.settings.machines.vm_host",
      "cmux.settings.accounts.state",
      "cmux.settings.accounts.run",
      "cmux.settings.channels.state",
      "cmux.settings.channels.go_back",
      "cmux.settings.channels.update_machine",
      "cmux.settings.agents.state",
      "cmux.settings.agents.run",
      "cmux.chief.profile.list",
      "cmux.chief.profile.avatar.get",
      "cmux.chief.profile.history",
      "cmux.chief.profile.update",
      "cmux.chief.profile.create",
      "cmux.chief.backend.list",
      "cmux.chief.backend.doctor",
      "cmux.settings.harnesses.state",
      "cmux.settings.harnesses.run",
      "cmux.settings.devices.state",
      "cmux.settings.devices.run",
      "cmux.settings.environments.state",
      "cmux.settings.environments.run",
      "cmux.settings.integrations.state",
      "cmux.settings.integrations.run",
      "cmux.settings.theme.set",
      "cmux.settings.theme.colors",
      "cmux.settings.theme.accepts",
      "cmux.settings.file.reveal",
      "cmux.settings.folders.add",
      "cmux.settings.backdrop.choose_image",
      "cmux.settings.backdrop.wallpaper_settings",
      "cmux.settings.backdrop.image.link",
      "cmux.settings.backdrop.image.remove",
      "cmux.settings.backdrop.image.reveal",
      "cmux.settings.backdrop.image.usage",
      "cmux.settings.backdrop.image.folder",
      "cmux.settings.backdrop.workspace",
      "cmux.settings.backdrop.workspace.set",
      "cmux.settings.backdrop.workspace.preview",
      "cmux.settings.art.search",
      "cmux.settings.art.use",
      "cmux.settings.web_updates.check",
      "cmux.settings.web_updates.rollback",
      "cmux.settings.server.restart",
      "cmux.settings.server.pair",
      "cmux.settings.section.actions",
      "cmux.app.action.run",
      "cmux.app.clipboard.write",
    ]);
    this.served = { ops: Object.keys(ops), streams: [] };
    const provide: Session["provide"] = (stream, source) => {
      this.served.streams.push(stream);
      return session.provide(stream, source);
    };
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
    provide("cmux.settings.changed", (ctx) => this.track(this.changed, ctx));
    provide("cmux.page.connection", (ctx) => this.track(this.connection, ctx));
    provide("cmux.page.command", (ctx) => this.track(this.commands, ctx));
    provide("cmux.settings.host.changed", (ctx) => this.track(this.hostChanged, ctx));
    provide("cmux.settings.accounts.changed", (ctx) => this.track(this.accountsChanged, ctx));
    provide("cmux.settings.agents.changed", (ctx) => {
      const listener = (state: AgentsState) => ctx.emit(state);
      this.agents.listeners.add(listener);
      ctx.signal.addEventListener("abort", () => this.agents.listeners.delete(listener));
    });
    provide("cmux.settings.harnesses.changed", (ctx) => this.track(this.harnessesChanged, ctx));
    provide("cmux.settings.devices.changed", (ctx) => this.track(this.devicesChanged, ctx));
    provide("cmux.settings.channels.machines.changed", (ctx) => this.track(this.machinesChanged, ctx));
  }

  /** Settings > Devices as the app serves it (texts already localized). */
  devices: DevicesState = mockDevicesState();
  /** Devices gestures the page sent (relay secrets included, so tests can check what was sent). */
  readonly deviceRuns: DevicesRun[] = [];
  private readonly devicesChanged = new Set<EventSourceContext>();

  /** Replaces the Devices part and tells the page, like the app's observation push. */
  setDevices(devices: DevicesState): void {
    this.devices = devices;
    for (const ctx of this.devicesChanged) ctx.emit(devices);
  }

  /** Settings > Accounts > Cloud Environments as the app's model serves it. */
  environments: CloudEnvironmentsState = {
    available: true,
    loading: false,
    error: null,
    environments: [
      {
        id: "env_00000000000000000001",
        name: "web",
        repo: "manaflow-ai/cmux@feat-cmux-next",
        setup_script: "cd web && bun install",
        status: "ready",
        error: null,
        log_tail: null,
      },
      {
        id: "env_00000000000000000002",
        name: "api",
        repo: "octo/api",
        setup_script: "make deps",
        status: "failed",
        error: "setup exited 3",
        log_tail: "lockfile mismatch",
      },
    ],
  };
  /** Every Cloud Environments gesture the page sent, in order (tests). */
  environmentRuns: CloudEnvironmentsRun[] = [];

  private runEnvironments(run: CloudEnvironmentsRun): { error?: string | null } {
    this.environmentRuns.push(run);
    const rows = this.environments.environments;
    switch (run.action) {
      case "refresh":
        return {};
      case "save":
        if (!run.name.trim()) return { error: "Name must be 1-80 characters." };
        this.environments = {
          ...this.environments,
          environments: [
            ...rows,
            {
              id: `env_${String(rows.length + 1).padStart(20, "0")}`,
              name: run.name,
              repo: run.repo || null,
              setup_script: run.setup_script ?? "",
              status: "unbuilt",
              error: null,
              log_tail: null,
            },
          ],
        };
        return {};
      case "build":
        this.environments = {
          ...this.environments,
          environments: rows.map((row) =>
            row.id === run.id ? { ...row, status: "building", error: null, log_tail: null } : row,
          ),
        };
        return {};
      case "delete":
        this.environments = { ...this.environments, environments: rows.filter((row) => row.id !== run.id) };
        return {};
    }
  }

  /** What the app's devices model does to the state (enough for the page and the gallery). A
   * relay's secret is never part of the state: only `hasSecret` says this Mac holds one. */
  private runDevices(run: DevicesRun): DevicesRunResult {
    this.deviceRuns.push(run);
    const state = this.devices;
    const device = (id: string) => [state.thisDevice, ...state.others].find((row) => row?.id === id);
    const result: DevicesRunResult = { ok: true };
    switch (run.action) {
      case "refresh":
      case "openPermission":
        return result;
      case "signIn":
        this.setDevices({ ...state, signIn: null, status: { text: "Connecting…", tone: "attention" } });
        return result;
      case "rename": {
        if (!device(run.id)) return { error: "That device is no longer on your account." };
        const rename = <T extends { id: string; name: string }>(row: T): T =>
          row.id === run.id ? { ...row, name: run.name } : row;
        this.setDevices({
          ...state,
          thisDevice: state.thisDevice && rename(state.thisDevice),
          others: state.others.map(rename),
        });
        return result;
      }
      case "remove":
        if (state.thisDevice?.id === run.id) {
          this.setDevices({
            ...state,
            thisDevice: null,
            sharing: null,
            signIn: "Sign In Again",
            status: { text: "Not signed in", tone: "neutral" },
          });
        } else this.setDevices({ ...state, others: state.others.filter((row) => row.id !== run.id) });
        return result;
      case "setAccess":
        this.setDevices({
          ...state,
          others: state.others.map((row) => (row.id === run.id ? { ...row, access: run.scope } : row)),
        });
        return result;
      case "setSharing":
        if (state.sharing) this.setDevices({ ...state, sharing: { ...state.sharing, on: run.on } });
        return result;
      case "saveRelay": {
        const draft = run.relay;
        if (draft.urls.length === 0) return { error: "Add at least one relay URL." };
        const hasSecret = Boolean(draft.secret || (draft.username && draft.password));
        const modeText = draft.mode === "static" ? "Username and password" : "Shared secret";
        const existing = state.relays.find((relay) => relay.id === draft.id);
        if (!existing && !hasSecret) return { error: "Enter the relay's secret." };
        const saved = {
          id: draft.id ?? `relay-${state.relays.length + 1}`,
          name: draft.name,
          urls: draft.urls,
          mode: draft.mode,
          modeText,
          enabled: draft.enabled,
          priority: draft.priority,
          hasSecret: hasSecret || (existing?.hasSecret ?? false),
          checking: false,
          check: existing?.check ?? null,
        };
        this.setDevices({
          ...state,
          relays: existing
            ? state.relays.map((relay) => (relay.id === saved.id ? saved : relay))
            : [...state.relays, saved],
        });
        return result;
      }
      case "checkRelay": {
        const relay = state.relays.find((row) => row.id === run.id);
        const urls = run.relay?.urls ?? relay?.urls ?? [];
        const text = `Reached ${urls[0] ?? "the relay"} in 38 ms (TURN allocation succeeded).`;
        if (relay)
          this.setDevices({
            ...state,
            relays: state.relays.map((row): DevicesRelay =>
              row.id === relay.id ? { ...row, check: { tone: "success", text } } : row,
            ),
          });
        return { ok: true, text };
      }
      case "deleteRelay":
        this.setDevices({ ...state, relays: state.relays.filter((relay) => relay.id !== run.id) });
        return result;
    }
  }

  /** Settings > Updates' channels; null: the host has no updater. */
  channels: ChannelsState | null = mockChannels;
  private readonly machinesChanged = new Set<EventSourceContext>();

  /** Replaces the Channels card's row of other machines and tells the page, like the app's push. */
  setMachines(machines: ChannelsState["machines"]): void {
    if (this.channels) this.channels = { ...this.channels, machines };
    for (const ctx of this.machinesChanged) ctx.emit(machines ?? null);
  }
  /** The way back the host answers with (Nightly's: the fixture runs a Dev build). */
  channelSwitch: ChannelSwitch | null = null;
  /** The build the card's Go Back asked for. */
  wentBack: string | null = null;
  /** The machines the card's Update buttons asked for, in order. */
  updatedMachines: string[] = [];
  /** Custom Chief pictures by Chief id (`chief.profile.avatar.get`); a Chief without one reads null. */
  chiefAvatars = new Map<string, Params>();

  /** The Chief records the host's page relay lists (`chief.profile.list`). */
  chiefs: Params[] = [
    {
      id: "agent_chief",
      display_name: "Chief",
      role: "Runs the team's agents",
      personality: "",
      instructions: "",
      tools: ["chiefs", "spawn", "tell", "workspaces"],
      harnesses: [],
      self_edit: ["avatar"],
      is_default: true,
      rev: 2,
      created_at: "2026-10-10T09:00:00Z",
      avatar: null,
      engine: {},
      locked: false,
    },
    {
      id: "agent_release",
      display_name: "Release Chief",
      role: "Ships the release",
      personality: "",
      instructions: "",
      tools: ["spawn", "tell"],
      harnesses: [],
      self_edit: ["avatar"],
      is_default: false,
      rev: 5,
      created_at: "2026-10-11T09:00:00Z",
      avatar: null,
      engine: { harness: "codex", model: "gpt-6-astra", effort: "high" },
      locked: true,
    },
  ];

  /** acpmux's harnesses as the app serves them (`SettingsHarnesses.state`). */
  harnesses: HarnessesState = {
    loading: false,
    problem: null,
    harnesses: [
      {
        id: "claude",
        name: null,
        kind: "claude-stdio",
        source: "path",
        problem: null,
        version: "2.0.5",
        latest: "2.0.9",
        outdated: true,
        auth: "signedIn",
        update: { command: "sudo npm install -g @anthropic-ai/claude-code@latest", elevated: true },
      },
      {
        id: "codex",
        name: null,
        kind: "acp",
        source: "path",
        problem: null,
        version: "0.3.1",
        latest: "0.4.0",
        outdated: true,
        auth: "signedOut",
        update: { command: "npm install -g @openai/codex@latest", elevated: false },
        ownerUpdate: true,
      },
      { id: "github-copilot-cli", name: "GitHub Copilot", kind: "acp", source: "user-file", problem: null },
      { id: "aider", name: "Aider", kind: "terminal", source: "user-file", problem: null },
    ],
  };
  /** `cmux agent hook status` as the app serves it (`SettingsAgentIntegrations.state`). */
  integrations: IntegrationsState = {
    loading: false,
    problem: null,
    command: "cmux agent hook install",
    providers: [
      { id: "claude", path: "~/.claude/settings.json", state: "installed", reason: null, detail: null, error: null },
      { id: "codex", path: "~/.codex/hooks.json", state: "partial", reason: null, detail: null, error: null },
      {
        id: "amp",
        path: "~/.config/amp/plugins/cmux-tui-journal.ts",
        state: "conflict",
        reason: "not_owned",
        detail: "~/.config/amp/plugins/cmux-tui-journal.ts exists and is not owned by cmux-tui",
        error: null,
      },
      { id: "gemini", path: "~/.gemini/settings.json", state: "absent", reason: null, detail: null, error: null },
    ],
  };
  /** Agent integrations gestures the page sent (install, repair, remove). */
  readonly integrationRuns: IntegrationsRun[] = [];

  /** Harnesses gestures the page sent. */
  readonly harnessRuns: HarnessesRun[] = [];
  private readonly harnessesChanged = new Set<EventSourceContext>();

  /** Replaces the Harnesses part and tells the page, like the app's observation push. */
  setHarnesses(harnesses: HarnessesState): void {
    this.harnesses = harnesses;
    for (const ctx of this.harnessesChanged) ctx.emit(harnesses);
  }

  /** What the cmux picker returns for Add Folder… (tests set it). */
  pickedFolders: string[] = ["~/src"];

  /** The app's live lists (spaces, machines, browser profiles) as the host serves them. */
  host: HostLists = {
    // The mock stands in for a DEV build (gallery, tests): the Development category shows.
    dev_build: true,
    rooms: [
      { id: "default", title: "Default", subtitle: null, active: true },
      { id: "work", title: "Work", subtitle: null, active: false },
    ],
    machines: [
      {
        id: "ssh:build",
        title: "build-mac",
        subtitle: "cmux@build-mac",
        active: true,
        color: "#7F5FA8",
        color_key: "build-mac",
      },
    ],
    devices: {
      title: "Devices",
      help: "Computers and phones linked to this one.",
      empty: "No other device can reach this computer yet.",
      add_title: "Add Device…",
      remove_title: "Remove",
      remove_confirm_title: "Remove for Good",
      remove_help: "It stops working with this computer at once. To use it again, add it again.",
      full_access_title: "Full access",
      activity_title: "Recent activity",
      error: null,
      rows: [
        {
          id: "peer:mini-7",
          title: "mini-7",
          subtitle: "Runs your agents · Connected",
          detail: null,
          state: "connected",
          removable: true,
        },
        {
          id: "paired:dv_leo",
          title: "leo-mbp",
          subtitle: "Uses this computer · Offline",
          detail: null,
          state: "offline",
          removable: true,
          full_access: false,
          full_access_help: "Its chats edit files and run commands here without asking",
        },
        {
          id: "phone:p1",
          title: "Lawrence's iPhone",
          subtitle: "Phone: approvals and terminals · Offline",
          detail: null,
          state: "offline",
          removable: true,
          // A phone paired with this Mac has its own acpmux record (role phone), so the same switch.
          full_access: false,
          full_access_help: "Its chats edit files and run commands here without asking",
        },
      ],
      activity: [{ time: "2026-10-22T07:12:00Z", what: "Added", subject: "mini-7" }],
    },
    // A DEV build: the home.voiceInput tunable exists, on as Leo set it.
    voice_input: { on: true },
    browser_profiles: [
      { id: "p-default", name: "Default", color: null, icon: null, is_default: true, source: null },
      { id: "p-work", name: "Work", color: "green", icon: null, is_default: false, source: "Google Chrome · Work" },
    ],
    profile_colors: [
      { name: "grey", swatch: "#8E8E93", fill: "#C7C7CC" },
      { name: "green", swatch: "#5E9A6A", fill: "#B5D6BB" },
      { name: "orange", swatch: "#B07A45", fill: "#E0C3A3" },
    ],
    theme: {
      levels: ["room", "workspace", "terminal"],
      current: { room: null, workspace: "Dracula", terminal: null },
      config: { ...mockThemeColors.find((theme) => theme.name === "Apple System Colors")!, name: "" },
    },
    terminal: { ghostty_config: "~/.config/ghostty/config", shell_integration: "zsh" },
    ghostty_diagnostics: [],
    computer_use: { phase: "ready", accessibility: true, screen_recording: false, helper: "cmux Computer Use" },
    settings_file: "/Users/me/.config/cmux/cmux-next.json",
    backdrops: [
      { id: "starryNight", title: "The Starry Night", attribution: "Van Gogh, 1889" },
      {
        id: "system:/System/Library/Desktop Pictures/.wallpapers/Sonoma/Sonoma Graphic Light Landscape.mov",
        title: "Sonoma Graphic",
        attribution: "macOS system wallpaper · Sonoma Graphic",
        collection: "video",
        collection_title: "Moving wallpapers",
        video: true,
      },
    ],
  };
  private readonly hostChanged = new Set<EventSourceContext>();
  private readonly accountsChanged = new Set<EventSourceContext>();
  /** Settings > Agents (cmux.settings.agents.*); tests set `agents.state.manages` and rows. */
  readonly agents = new MockAgents();

  /** The Accounts part as the app serves it (texts already localized). */
  accounts: AccountsState = {
    teams: {
      title: "Active Team",
      help: "Cloud machines, CodeRouter and phone access use this team.",
      options: [
        { id: "team-personal", name: "Personal", active: true },
        { id: "team-acme", name: "Acme", active: false },
      ],
      disabled: false,
      note: null,
      error: null,
    },
    refresh: "Refresh",
    refreshing: false,
    cmux: mockCmuxAccount.signedIn,
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
    } else if (run.action === "selectTeam" && this.accounts.teams) {
      const teams = this.accounts.teams;
      this.accounts = {
        ...this.accounts,
        teams: { ...teams, options: teams.options.map((team) => ({ ...team, active: team.id === run.team })) },
      };
    } else if (run.action === "remove") {
      this.accounts = rows((row) => ({ ...row, linked: row.linked.filter((account) => account.id !== run.account) }));
    } else if (run.action === "cmux.signOut" || run.action === "cmux.cancelSignIn") {
      this.accounts = { ...this.accounts, cmux: mockCmuxAccount.signedOut };
    } else if (run.action === "cmux.signIn") {
      this.accounts = { ...this.accounts, cmux: mockCmuxAccount.signingIn };
    }
    for (const ctx of this.accountsChanged) ctx.emit(this.accounts);
    return error ? { error } : {};
  }

  /** Replaces the host lists and sends `cmux.settings.host.changed`. */
  /** A theme file landing in the user's themes: listed and colored, like the catalog's reload. */
  private addTheme(theme: GhosttyTheme, replace: boolean): { name: string } {
    if (!theme.name || /[/=#"]/.test(theme.name) || theme.name.startsWith(".")) {
      throw new ProtocolError("cmux.settings.theme.invalid_name", "not a theme name");
    }
    if (mockThemeColors.some((shipped) => shipped.name === theme.name)) {
      throw new ProtocolError("cmux.settings.theme.shipped_name", "a theme that ships with cmux has this name");
    }
    if (!replace && this.themeColors.some((known) => known.name === theme.name)) {
      throw new ProtocolError("cmux.settings.theme.exists", "a theme with this name exists", {
        details: { name: theme.name },
      });
    }
    this.themeColors = [...this.themeColors.filter((known) => known.name !== theme.name), theme];
    if (this.domains && !this.domains.themes.includes(theme.name)) {
      this.domains = { ...this.domains, themes: [...this.domains.themes, theme.name].sort() };
    }
    return { name: theme.name };
  }

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

  private workspaceBackground(workspace: string): WorkspaceBackground {
    const background = this.workspaceBackgrounds.get(workspace);
    if (!background) throw new ProtocolError(ProtocolErrorCode.invalidParams, `no workspace ${workspace}`);
    return background;
  }

  private list(section: string | undefined): ListRow[] {
    return schema.rows.filter((row) => !section || row.section === section).map((row) => this.row(row.key));
  }

  private snapshot(): SnapshotResult {
    return {
      revision: this.revision,
      schema_hash: "", // the owner hashes the rows it loads; the export commits no hash (#21946)
      effective: this.effective(),
      managed: Object.fromEntries(
        [...this.managed].map(([key, { source, reason, team }]) => [key, { source, reason, team: team ?? null }]),
      ),
      diagnostics: this.diagnostics,
      domains: this.domains ?? { themes: null, font_families: null, sounds: null, recent_fonts: null },
    };
  }

  private row(key: string): ListRow {
    const row = rowsByKey.get(key)!;
    const managed = this.managed.get(key);
    return {
      key,
      ...(key === "agents.chats.roots"
        ? { folders: this.chatFolders, user_roots: this.values.get(key) as string[] | undefined }
        : {}),
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
    // The host keeps the fonts written lately (RecentFonts.swift).
    if (this.domains && rowsByKey.get(key)?.kind === "font_family" && typeof value === "string")
      this.domains = { ...this.domains, recent_fonts: recentAfterPick(this.domains.recent_fonts, value) };
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

/** Settings > Devices with this Mac, an iPhone and a second Mac, two relays and a short history. */
export function mockDevicesState(): DevicesState {
  const removeConfirm = (name: string) => ({
    title: `Remove ${name}?`,
    body: `${name} signs out of your devices and can no longer reach Mac Screen on this Mac.`,
    confirm: "Remove",
  });
  return {
    available: true,
    status: { text: "Connected", tone: "success" },
    signIn: null,
    error: null,
    labels: {
      thisDeviceSection: "This Mac",
      thisDeviceBadge: "This Mac",
      othersSection: "Other Devices",
      noOthers: "No other devices yet. Sign in to cmux on another device to see it here.",
      fingerprint: "Fingerprint",
      rename: "Rename…",
      renameTitle: "Rename Device",
      nameField: "Name",
      save: "Save",
      cancel: "Cancel",
      remove: "Remove…",
      access: "Mac Screen access",
      accessOptions: [
        { value: "none", title: "No access" },
        { value: "ask", title: "Ask each time" },
        { value: "view", title: "View only" },
        { value: "full", title: "Full control" },
      ],
      sharingSection: "Mac Screen on This Mac",
      sharingToggle: "Allow Mac Screen on this Mac",
      sharingDetail: "Your devices can see or control this Mac.",
      openSettings: "Open System Settings",
      allowed: "Allowed",
      relaysSection: "Relays",
      relaysEmpty: "No relays. Devices connect directly when they can.",
      relaysHelp: "Used when your devices cannot connect directly.",
      addRelay: "Add Relay…",
      editRelay: "Edit…",
      deleteRelay: "Delete",
      deleteRelayTitle: "Delete this relay?",
      deleteRelayBody: "Your devices stop using it. Its secret is removed from this Mac.",
      checkRelay: "Check Relay",
      relayOff: "Off",
      relayName: "Name",
      relayURLs: "URLs",
      relayURLsHelp: "One per line, or separated by commas (turn: or turns:).",
      relayMode: "Credentials",
      modeOptions: [
        { value: "shared_secret", title: "Shared secret" },
        { value: "static", title: "Username and password" },
      ],
      relaySecret: "Shared secret",
      relaySecretKeep: "Leave empty to keep the saved secret",
      relayUsername: "Username",
      relayPassword: "Password",
      relayEnabled: "Use this relay",
      relayPriority: "Priority",
      relayPriorityHelp: "Lower numbers are tried first.",
      historySection: "History",
      historyEmpty: "No Mac Screen activity yet.",
      historyColumns: {
        time: "Time",
        event: "Event",
        device: "Device",
        host: "Host",
        scope: "Access",
        detail: "Detail",
        duration: "Duration",
      },
      refresh: "Refresh",
      copy: "Copy",
    },
    thisDevice: {
      id: "dev-mac-studio",
      name: "Studio Mac",
      platform: "Mac",
      fingerprint: "1A2B 3C4D 5E6F 7081 92A3 B4C5",
      fingerprintFull: "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809",
      online: true,
      presence: "Online",
      thisDevice: true,
      sharesText: "Shares Mac Screen",
      access: null,
      removeConfirm: {
        title: "Remove this Mac?",
        body: "This Mac leaves your devices. You can sign in again later.",
        confirm: "Remove",
      },
    },
    others: [
      {
        id: "dev-iphone",
        name: "Aziz's iPhone",
        platform: "iPhone",
        fingerprint: "9F8E 7D6C 5B4A 3928 1706 F5E4",
        fingerprintFull: "9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0",
        online: true,
        presence: "Online",
        thisDevice: false,
        sharesText: null,
        access: "full",
        removeConfirm: removeConfirm("Aziz's iPhone"),
      },
      {
        id: "dev-macbook",
        name: "MacBook Pro",
        platform: "Mac",
        fingerprint: null,
        fingerprintFull: null,
        online: false,
        presence: "Offline · seen 5 minutes ago",
        thisDevice: false,
        sharesText: "Shares Mac Screen",
        access: "ask",
        removeConfirm: removeConfirm("MacBook Pro"),
      },
    ],
    sharing: {
      on: true,
      busy: false,
      permissions: [
        {
          id: "screenRecording",
          title: "Screen Recording",
          detail: "Lets your devices see this Mac's screen.",
          granted: true,
        },
        {
          id: "accessibility",
          title: "Accessibility",
          detail: "Lets Full control use the mouse and keyboard.",
          granted: false,
        },
      ],
    },
    relays: [
      {
        id: "relay-1",
        name: "cmux TURN",
        urls: ["turns:turn.example.com:443?transport=tcp", "turn:turn.example.com:3478"],
        mode: "shared_secret",
        modeText: "Shared secret",
        enabled: true,
        priority: 0,
        hasSecret: true,
        checking: false,
        check: { tone: "success", text: "Reached in 41 ms" },
      },
      {
        id: "relay-2",
        name: "Office coturn",
        urls: ["turn:10.0.4.2:3478"],
        mode: "static",
        modeText: "Username and password",
        enabled: false,
        priority: 10,
        hasSecret: false,
        checking: false,
        check: null,
      },
    ],
    history: [
      {
        id: "h3",
        time: "Oct 19, 2026 at 4:12 PM",
        event: "ended",
        eventText: "Ended",
        tone: "neutral",
        device: "Aziz's iPhone",
        host: "Studio Mac",
        scope: "Full control",
        detail: "",
        duration: "22m 27s",
      },
      {
        id: "h2",
        time: "Oct 19, 2026 at 3:50 PM",
        event: "started",
        eventText: "Started",
        tone: "success",
        device: "Aziz's iPhone",
        host: "Studio Mac",
        scope: "Full control",
        detail: "Through cmux TURN",
        duration: "",
      },
      {
        id: "h1",
        time: "Oct 18, 2026 at 9:03 AM",
        event: "denied",
        eventText: "Denied",
        tone: "danger",
        device: "MacBook Pro",
        host: "Studio Mac",
        scope: "View only",
        detail: "Declined on this Mac",
        duration: "",
      },
    ],
  };
}
