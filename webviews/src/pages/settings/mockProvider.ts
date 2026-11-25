// A mock `cmux.settings` provider on a pane-protocol Session, for the browser dev loop and the
// tests. It behaves like the daemon's config owner as the page bridge relays it: one user
// layer, one managed fixture key, a revision counter, kind validation, a
// `cmux.settings.changed` event per write, idempotency keys required on writes, and error
// codes `cmux.settings.<code>`. Native ops are recorded in `log`.
//
// `createMockClient` connects a page client to it over the protocol's in-memory transport
// pair, so the page's calls cross the real envelope (call/ok/err/sub/ev).
import { runMockAgentKeys } from "./mockAgentKeys";
import { mockAutocloudState, runMockAutocloud } from "./mockAutocloud";
import { mockHubState, runMockHub } from "./mockHub";
import { mockConnectionsState, runMockConnections } from "./mockConnections";
import { mockModels, runMockModels } from "./mockModels";
import { mockAllotments, runMockAllotment } from "./mockAllotments";
import { createMockPair } from "../../protocol/adapters/mock";
import { updatable } from "./harnesses";
import { MockTeams } from "./mockTeams";
import { ACCOUNT_ACTIONS } from "../shared/signIn/accountSignIn";
import { MockAccountSignIn } from "../shared/signIn/mockSignIn";
import { mockContextMenus, setMockMenuLayout } from "./mockMenus";
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
  type ChannelsProgress,
  type ChannelSwitch,
  type ChannelsState,
  type AccountsState,
  type DevicesJoinState,
  type DevicesRelay,
  type CloudEnvironmentsRun,
  type CloudEnvironmentsState,
  type LibraryListing,
  type LibraryRun,
  type ChecklistFact,
  type SharesState,
  type TailnetState,
  type DevicesRun,
  type DevicesRunResult,
  type DevicesState,
  type MenuLayout,
  type HarnessesRun,
  type HarnessesState,
  type ProviderAccount,
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
  type CustomizeTryOn,
  type KeysState,
  type ModelsRun,
  type ModelsState,
  type ComputerUseApproval,
  type AgentToolsCardRun,
  type AgentToolsCardState,
  type McpServersRun,
  type McpServersState,
  type AgentSkillsRun,
  type AgentSkillsState,
  type AgentMcpRun,
  type AgentMcpState,
  type AgentHooksRun,
  type AgentHooksState,
  type AgentConfigAgent,
  type AgentConfigRun,
  type AgentConfigState,
  type AllotmentSet,
  type AllotmentView,
  type HubRun,
  type HubState,
  type AccountsRunReply,
  type DoctorReport,
  type DoctorRun,
  type LibraryAnswer,
  type AgentSkillRow,
  type AutocloudAction,
  type AutocloudState,
  type ConnectionsRun,
  type ConnectionsState,
  type ArchivedRun,
  type ArchivedState,
} from "./ops";
import { hostRowsByKey, rowsByKey, schema } from "./schema";
import { withEdits, type ThemeEditMap } from "../../theme/themeEdits";
import { validate } from "./validate";
import { MockAgents } from "./mockAgents";
import { mockChannels } from "./mockChannels";
import { mockThemeColors } from "./mockThemes";
import { mockChecklist } from "./mockChecklist";
import { mockLibrary, runLibrary } from "./mockLibrary";
import { mockEmptyDoctor, runDoctor } from "./mockDoctor";
import { mockAgentConfig, runAgentConfigMock } from "./mockAgentConfig";
import type { GhosttyTheme } from "../../theme/ghosttyTheme";
import type { WorktreeRecipe } from "../../worktreeRecipe";

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
  /** Whether the native action registry accepts an invocation. */
  actionRan?: boolean;
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
  /** This Mac joined to a team (the host lists' `devices_join`); absent: not joined. */
  devicesJoin?: DevicesJoinState;
  /** The customize library (`cmux customize library`); default a few entries with one conflict. */
  library?: LibraryListing;
  /** The CLI refuses every library change with this message (a preview is open). */
  libraryRefusal?: string;
  /** `cmux customize doctor`'s report; default no findings (no card, no notice). */
  doctor?: DoctorReport;
  /** The CLI refuses every doctor change with this message. */
  doctorRefusal?: string;
  /** A customization being tried on (`cmux customize try`); absent: none. */
  tryOn?: CustomizeTryOn;
  /** Writes of these keys the daemon refuses with this reason and details (a json row's
   * `accepted.problems`, as cmux-config's refusal carries them). */
  refusals?: Record<string, { message: string; details: Record<string, unknown> }>;
};

/** This Mac joined to a team with the one-line join, every consent switch off. */
export const mockDevicesJoin: DevicesJoinState = {
  title: "This Mac on Your Team",
  joined: "Joined to Example Team as studio",
  help: "Your team's machines reach this Mac through the mesh. They cannot see or control it until you allow it here.",
  error: null,
  busy: false,
  known: true,
  revoke_all: null,
  switches: [
    { surface: "screen", title: "Screen sharing", help: "Your team's machines can see this screen", on: false },
    {
      surface: "control",
      title: "Control",
      help: "Your team's machines can move the pointer and type here",
      on: false,
    },
    {
      surface: "signedInMachines",
      title: "Your other Macs",
      help: "Your other Macs signed in to this account can open workspaces and terminals here",
      on: false,
    },
  ],
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
  ui_font_families: [
    "Avenir Next",
    "Georgia",
    "Helvetica Neue",
    "Iosevka",
    "JetBrains Mono",
    "Menlo",
    "New York",
    "SF Pro",
  ],
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

/** Settings > Extensions: one app as `apps.settings.list` answers it, with the person's changes. */
export type MockExtensionApp = {
  app: string;
  name: string;
  enabled: boolean;
  schema: {
    type: "object";
    properties: Record<
      string,
      {
        type: string;
        title?: string;
        description?: string;
        enum?: string[];
        default?: unknown;
        minimum?: number;
        maximum?: number;
        maxLength?: number;
        "x-cmux-devOnly"?: boolean;
      }
    >;
  };
  stored: Record<string, unknown>;
};

/** A project of the mock session host: its repository's recipe files and the saved override. */
export type MockWorktreeProject = {
  path: string;
  name: string;
  repository: WorktreeRecipe;
  saved?: WorktreeRecipe;
  files: string[];
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
  private actionRan: boolean;
  private readonly failing: Partial<Record<string, string>>;
  private readonly refusals: NonNullable<MockOptions["refusals"]>;
  private readonly values = new Map<string, unknown>();
  private readonly managed: Map<string, { value: unknown } & ManagedInfo>;
  private readonly changed = new Set<EventSourceContext>();
  private readonly connection = new Set<EventSourceContext>();
  private readonly commands = new Set<EventSourceContext>();
  private readonly usedKeys = new Map<string, string>();
  private connected: boolean;
  private museumArt: MuseumArtResult[];
  readonly workspaceBackgrounds = new Map<string, WorkspaceBackground>();
  /** Holds `cmux.settings.host.lists` until it settles: a test's host that answers after the values. */
  holdHost: Promise<void> | null = null;

  /** Every catalog action the page ran, with its arguments, in order (tests). */
  readonly actionsRun: Array<{ action: string; args: Params }> = [];

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
    this.refusals = options.refusals ?? {};
    this.actionRan = options.actionRan ?? true;
    this.connected = options.connected ?? true;
    this.tryOn = options.tryOn ?? null;
    if (options.settingsFile !== undefined) this.host = { ...this.host, settings_file: options.settingsFile };
    if (options.themeOverrides) this.host = { ...this.host, theme_overrides: options.themeOverrides };
    if (options.devicesJoin) this.host = { ...this.host, devices_join: options.devicesJoin };
    if (options.library) this.library = options.library;
    if (options.libraryRefusal) this.libraryRefusal = options.libraryRefusal;
    if (options.doctor) this.doctor = options.doctor;
    if (options.doctorRefusal) this.doctorRefusal = options.doctorRefusal;
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
      "cmux.settings.host.lists": async () => {
        if (this.holdHost) await this.holdHost;
        return this.host;
      },
      "cmux.settings.accounts.state": () => this.accountsState(),
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
      "cmux.settings.devices.join_consent": (params) => {
        if (this.joinConsentRefusal) throw new ProtocolError("cmux.app.user_only", this.joinConsentRefusal);
        if (this.joinConsentReplyError) return { error: this.joinConsentReplyError };
        const join = this.host.devices_join;
        if (join)
          this.setHost({
            ...this.host,
            devices_join: {
              ...join,
              switches: join.switches.map((s) => (s.surface === params.surface ? { ...s, on: params.on === true } : s)),
            },
          });
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
      "cmux.settings.channels.go_back": async (params) => {
        this.wentBack = params.build as string;
        if (this.switchHold) await this.switchHold;
        return {};
      },
      "cmux.settings.channels.switch_build": async (params) => {
        this.switchedTo = params.build as string;
        if (this.switchHold) await this.switchHold;
        if (this.switchRefusal) throw new ProtocolError("cmux.page.refused", this.switchRefusal);
        return {};
      },
      "cmux.settings.channels.update_machine": (params) => {
        this.updatedMachines.push(params.id as string);
        return {};
      },
      "cmux.settings.agents.state": () => this.agents.state,
      "cmux.settings.agents.run": async (params) => {
        if ((params as { action?: string }).action === "remove") await this.agents.endpoint.holdRemove;
        return this.agents.run(params as unknown as AgentsRun);
      },
      "cmux.settings.context_menus.set": (params) => {
        const menus = this.host.context_menus;
        if (menus)
          this.setHost({
            ...this.host,
            context_menus: setMockMenuLayout(
              menus,
              params.menu as string,
              (params.layout as MenuLayout | null) ?? null,
            ),
          });
        return {};
      },
      "cmux.settings.context_menus.show_item": (params) => {
        const menus = this.host.context_menus;
        if (menus)
          this.setHost({ ...this.host, context_menus: { ...menus, show_customize_item: params.show === true } });
        return {};
      },
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
      "cmux.chief.backend.list": async () => {
        await this.agents.endpoint.holdList;
        return {
          harnesses: {
            defaultHarness: "claude",
            harnesses: {
              claude: { displayName: "Claude Code" },
              codex: { displayName: "Codex" },
              ...this.agents.endpointHarnesses(),
              ...this.agents.terminalHarnesses(),
            },
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
        };
      },
      "cmux.chief.backend.add": async (params) => {
        await this.agents.endpoint.holdAdd;
        const before = this.agents.endpoint.addFails;
        if (before) throw new ProtocolError(before, "the endpoint's model list could not be read");
        const added = this.agents.addEndpoint(params);
        const fail = this.agents.endpoint.addThenFail;
        if (fail) throw new ProtocolError(fail, "the add did not answer in time");
        return added;
      },
      "cmux.chief.backend.doctor": async () => {
        await this.agents.endpoint.holdDoctor;
        return this.agents.endpoint.doctor;
      },
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
      "cmux.settings.theme.file.open": () => {
        if (this.themeFileRefusal) throw new ProtocolError("cmux.settings.theme.file_failed", this.themeFileRefusal);
        return {};
      },
      "cmux.settings.file.reveal": () => ({}),
      // The registry buttons SettingsSchema.actions(in:) lists for these sections.
      "cmux.settings.section.actions": (params) =>
        ({
          general: [{ id: "palette.makeDefaultTerminal", title: "Make cmux the Default Terminal", enabled: true }],
          advanced: [{ id: "reloadConfiguration", title: "Reload Configuration", enabled: true }],
          appearance: [
            { id: "space.setTheme", title: "Set Space Theme…", enabled: true },
            { id: "workspace.setTheme", title: "Set Workspace Theme…", enabled: true },
          ],
          rooms: [{ id: "space.new", title: "New Space", enabled: true }],
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
      "cmux.settings.backdrop.image.screen_saver": () => ({ id: this.screenSaver, pending: false }),
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
      "cmux.settings.app_update.run": () => ({}),
      "cmux.settings.web_updates.check": () => ({}),
      "cmux.settings.web_updates.rollback": () => ({}),
      "cmux.settings.language.relaunch": () => ({}),
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
      "cmux.settings.tailnet.state": () => {
        this.onTailnetRead?.();
        if (this.tailnetDropReads > 0) {
          this.tailnetDropReads -= 1;
          return null;
        }
        return this.tailnet;
      },
      "cmux.settings.tailnet.start": () => this.stepTailnet("start"),
      "cmux.settings.tailnet.login": () => this.stepTailnet("login"),
      "cmux.settings.tailnet.logout": () => this.stepTailnet("logout"),
      "cmux.settings.tailnet.joinVM": (params) => {
        const vm = String((params as { vm?: unknown }).vm ?? "");
        this.tailnetSteps.push(`joinVM:${vm}`);
        if (String((params as { key?: unknown }).key ?? "").includes("OTHER")) {
          return {
            ok: false,
            vm,
            error:
              "the VM is already on another tailnet (https://headscale.other.example); nothing changed. Run again with --switch to add yours as a second profile.",
          };
        }
        return {
          ok: true,
          vm,
          node: { dnsName: `${vm}.ts.net`, ips: ["100.64.0.7"], tags: ["tag:cmux"], online: true },
        };
      },
      "cmux.settings.tailnet.leaveVM": (params) => {
        const vm = String((params as { vm?: unknown }).vm ?? "");
        this.tailnetSteps.push(`leaveVM:${vm}`);
        return { ok: true, vm };
      },
      "cmux.settings.customize.run": (params) => {
        const verb = String((params as { verb?: unknown }).verb ?? "");
        if (verb === "status") return { try_on: this.tryOn };
        this.customizeVerbs.push(verb);
        this.tryOn = null;
        return { settled: [] };
      },
      "cmux.settings.shares.list": () => this.shares,
      "cmux.settings.archived.list": () => this.archived,
      "cmux.settings.archived.run": (params) => this.runArchived(params as ArchivedRun),
      "cmux.settings.customize.library": (params) => this.runLibrary(params as LibraryRun),
      "cmux.settings.customize.checklist": (params) => ({
        checklist: mockChecklist(this.values, (params as { has?: ChecklistFact[] }).has ?? []),
      }),
      "cmux.settings.keys.list": () => this.keys,
      "cmux.settings.keys.answer": (params) => this.answerKey(params as { request_id?: unknown; value?: unknown }),
      "cmux.settings.keys.decline": (params) =>
        this.declineKey(String((params as { request_id?: unknown }).request_id ?? "")),
      "cmux.settings.keys.revoke": (params) => this.revokeKey(String((params as { id?: unknown }).id ?? "")),
      "cmux.settings.shares.revoke": (params) =>
        this.revokeShare(String((params as { share_id?: unknown }).share_id ?? "")),
      "cmux.settings.environments.state": () => this.environments,
      "cmux.settings.environments.run": (params) => this.runEnvironments(params as unknown as CloudEnvironmentsRun),
      // Settings > Extensions: the daemon's apps.settings.list / apps.settings.set.
      "cmux.settings.extensions.list": () => {
        if (this.extensionsUnsupported)
          throw new ProtocolError("cmux.protocol.unknown_op", "cmux.settings.extensions.list");
        return { apps: this.extensionApps.map((app) => ({ ...app, values: this.extensionValues(app) })) };
      },
      "cmux.settings.extensions.set": (params) =>
        this.setExtensionSettings(params as { app: string; values: Record<string, unknown> }),
      // Settings > Agents > Worktree Setup: the session host's ops through the page relay.
      "cmux.settings.worktree.list": () => ({
        projects: this.worktreeProjects.map((project) => ({
          path: project.path,
          name: project.name,
          state: "present",
          overlay: project.saved ? { worktree: project.saved } : {},
        })),
        sources: [],
      }),
      "cmux.settings.worktree.save": (params) => {
        const { path, worktree } = params as { path: string; worktree: WorktreeRecipe | null };
        this.worktreeProjects = this.worktreeProjects.map((project) => {
          if (project.path !== path) return project;
          const { saved: _saved, ...rest } = project;
          return worktree ? { ...rest, saved: worktree } : rest;
        });
        return { value: { path }, replayed: false };
      },
      "cmux.settings.worktree.read": (params) =>
        this.worktreeReadHold
          ? this.worktreeReadHold.then(() => this.readWorktree(params as { path: string }))
          : this.readWorktree(params as { path: string }),
      "cmux.settings.cloud.allotment.get": () => {
        if (!this.allotment) throw new ProtocolError("cmux.settings.unavailable", "this host has no Compute part");
        return this.allotment;
      },
      "cmux.settings.cloud.allotment.set": (params) => {
        const run = params as AllotmentSet;
        this.allotmentRuns.push(run);
        if (!this.allotment) throw new ProtocolError("cmux.settings.unavailable", "this host has no Compute part");
        if (run.action !== undefined && run.action !== "down" && run.action !== "hold" && run.action !== "up")
          throw new ProtocolError("cmux.settings.invalid", "action must be down, hold or up");
        if (run.action === undefined && run.auto === undefined)
          throw new ProtocolError("cmux.settings.invalid", "a set names an action or auto");
        this.allotment = runMockAllotment(this.allotment, run);
        return this.allotment;
      },
      "cmux.settings.models.state": () => {
        if (!this.models) throw new ProtocolError("cmux.settings.unavailable", "this host has no Models part");
        return this.models;
      },
      "cmux.settings.models.run": (params) => {
        const run = params as ModelsRun;
        this.modelRuns.push(run);
        if (!this.models) throw new ProtocolError("cmux.settings.unavailable", "this host has no Models part");
        try {
          this.setModels(runMockModels(this.models, run));
        } catch (error) {
          throw new ProtocolError("cmux.settings.invalid", error instanceof Error ? error.message : String(error));
        }
        return {};
      },
      "cmux.settings.harnesses.state": () => this.harnesses,
      "cmux.settings.harnesses.run": (params) => {
        const run = params as HarnessesRun;
        if (run.action.startsWith("account")) {
          return this.runAccount(run);
        }
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
      "cmux.settings.agentTools.state": () => this.agentTools,
      "cmux.settings.agentTools.run": (params) => {
        const run = params as AgentToolsCardRun;
        if (run.action === "refresh") return this.agentTools;
        this.agentToolsRuns.push(run);
        // Like the host: Remove takes out that agent's old cmux entry.
        if (run.action === "removeLeftover" && this.agentToolsKeeps) {
          this.agentTools = { ...this.agentTools, note: this.agentToolsKeeps };
          return this.agentTools;
        }
        if (run.action === "removeLeftover") {
          this.agentTools = {
            ...this.agentTools,
            rows: this.agentTools.rows.map((row) => (row.id === run.id ? { ...row, leftover: null } : row)),
          };
          return this.agentTools;
        }
        // Like the host: Turn On sets the choice to on; every agent found then gets cmux's tools in cmux.
        this.values.set("agents.cmuxMcp", "on");
        this.agentTools = {
          ...this.agentTools,
          choice: "on",
          rows: this.agentTools.rows.map((row) => (row.state === "ready" ? { ...row, state: "terminals" } : row)),
        };
        return this.agentTools;
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
      "cmux.settings.agentSkills.state": () => this.agentSkills,
      "cmux.settings.agentSkills.run": (params) => {
        const run = params as AgentSkillsRun;
        const shown = this.agentSkills;
        if (run.action === "refresh" || !shown.enabled) return this.agentSkills;
        if (run.action === "add") {
          // Like the CLI: a Claude Code command is listed; Codex's and cmux's are only reported.
          this.agentSkillRuns.push(run);
          const dir = { claude: "~/.claude/commands", codex: "~/.codex/prompts", cmux: "~/.config/cmux/commands" };
          const path = `${dir[run.agent]}/${run.name}.md`;
          const invocation = run.agent === "codex" ? `/prompts:${run.name}` : `/${run.name}`;
          const taken = (entry: AgentSkillRow) =>
            entry.agent === run.agent && entry.kind === "command" && entry.name === run.name;
          if (shown.skills.some(taken)) {
            this.agentSkills = {
              ...shown,
              refusal: { path: "new-command", message: `${path} already exists (--replace writes over it)` },
            };
            return this.agentSkills;
          }
          const listed: AgentSkillRow[] =
            run.agent === "claude"
              ? [
                  {
                    agent: "claude",
                    kind: "command",
                    scope: "user",
                    name: run.name,
                    description: run.description || run.prompt.split("\n")[0],
                    path,
                    enabled: true,
                  },
                ]
              : [];
          this.agentSkills = {
            ...shown,
            skills: [...shown.skills, ...listed],
            refusal: null,
            added: { agent: run.agent, invocation, path },
          };
          return this.agentSkills;
        }
        const row = shown.skills.find((entry) => entry.path === run.path);
        // Like the host: only a listed file.
        if (!row) throw new ProtocolError("cmux.settings.invalid", "path must be a listed skill's file");
        this.agentSkillRuns.push(run);
        if (run.action === "on" || run.action === "off") {
          this.agentSkills = {
            ...shown,
            skills: shown.skills.map((entry) =>
              entry.path === run.path ? { ...entry, enabled: run.action === "on" } : entry,
            ),
          };
        }
        return this.agentSkills;
      },
      "cmux.settings.agentMcp.state": () => (this.agentMcp.enabled ? this.agentMcp : { enabled: false, servers: [] }),
      "cmux.settings.agentMcp.run": (params) => {
        const run = params as AgentMcpRun;
        if (!this.agentMcp.enabled) throw new ProtocolError("cmux.page.unavailable", "labs.agentCustomization is off");
        if (run.action === "refresh" || run.action === "pickFolder" || !("name" in run)) return {};
        this.agentMcpRuns.push(run);
        const { agent, name, scope } = run;
        const same = (row: { agent: string; name: string; scope: string }) =>
          row.agent === agent && row.name === name && row.scope === scope;
        if (run.action === "add") {
          const row = {
            agent: run.agent,
            name: run.name,
            scope: run.scope,
            transport: run.url ? (run.transport ?? "http") : "stdio",
            command: run.command ?? null,
            args: run.args ?? [],
            url: run.url ?? null,
            enabled: true,
            env: (run.env ?? []).map((line) => line.split("=")[0]!),
            headers: (run.headers ?? []).map((line) => line.split("=")[0]!),
            file: run.agent === "claude" ? "/Users/me/.claude.json" : "/Users/me/.codex/config.toml",
            shadowed: false,
            removable: true,
          } as const;
          this.agentMcp = { ...this.agentMcp, servers: [...this.agentMcp.servers, row], error: null };
          return {};
        }
        // Like the host: only a listed server.
        if (!this.agentMcp.servers.some(same))
          throw new ProtocolError("cmux.settings.invalid", "name must be a listed server");
        this.agentMcp = {
          ...this.agentMcp,
          error: null,
          servers:
            run.action === "remove"
              ? this.agentMcp.servers.filter((row) => !same(row))
              : this.agentMcp.servers.map((row) => (same(row) ? { ...row, enabled: run.action === "enable" } : row)),
        };
        return {};
      },
      "cmux.settings.agentHooks.state": () => this.agentHooks,
      "cmux.settings.agentHooks.run": (params) => {
        const run = params as AgentHooksRun;
        const state = this.agentHooks;
        if (!state.available || run.action === "refresh") return state;
        this.agentHookRuns.push(run);
        const listing = state.listing!;
        if (run.action === "add") {
          const hook = {
            id: `${run.agent}-new${listing.hooks.length}`,
            agent: run.agent,
            scope: run.scope ?? "user",
            file: "",
            event: run.event,
            matcher: run.matcher ?? null,
            type: "command",
            command: run.command,
            timeout: run.timeout ?? null,
            enabled: true,
            owner: "user" as const,
            read_only: false,
          };
          this.agentHooks = { ...state, listing: { ...listing, hooks: [...listing.hooks, hook] } };
          return this.agentHooks;
        }
        const row = listing.hooks.find((entry) => entry.id === run.id);
        // Like the host: only a listed, editable hook.
        if (!row) throw new ProtocolError("cmux.settings.invalid", "id must be a listed hook");
        const hooks =
          run.action === "remove"
            ? listing.hooks.filter((entry) => entry.id !== run.id)
            : listing.hooks.map((entry) =>
                entry.id === run.id ? { ...entry, enabled: run.action === "enable" } : entry,
              );
        this.agentHooks = { ...state, listing: { ...listing, hooks } };
        return this.agentHooks;
      },
      "cmux.settings.autocloud.state": () => this.autocloud,
      "cmux.settings.autocloud.run": (params) => {
        const run = params as AutocloudAction;
        if (run.action !== "refresh" && run.action !== "preview") this.autocloudRuns.push(run);
        const { answer, state } = runMockAutocloud(this.autocloud, run);
        this.autocloud = state;
        return answer;
      },
      "cmux.settings.hub.state": () => this.hub,
      "cmux.settings.hub.run": (params) => {
        const run = params as HubRun;
        if (run.action !== "refresh") this.hubRuns.push(run);
        this.hub = runMockHub(this.hub, run);
        return {};
      },
      "cmux.settings.connections.state": () => this.connections,
      "cmux.settings.connections.run": (params) => {
        const run = params as ConnectionsRun;
        if (run.action !== "refresh") this.connectionsRuns.push(run);
        this.connections = runMockConnections(this.connections, run);
        return {};
      },
      "cmux.settings.mcp.state": () => this.mcpServers,
      "cmux.settings.mcp.run": (params) => {
        const run = params as McpServersRun;
        if (run.action === "refresh") return {};
        const row = this.mcpServers.servers.find((entry) => entry.name === run.name);
        // Like the host: only a listed server.
        if (!row) throw new ProtocolError("cmux.settings.invalid", "name must be a listed server");
        this.mcpServerRuns.push(run);
        this.mcpServers = {
          ...this.mcpServers,
          servers:
            run.action === "remove"
              ? this.mcpServers.servers.filter((entry) => entry.name !== run.name)
              : this.mcpServers.servers.map((entry) =>
                  entry.name === run.name
                    ? {
                        ...entry,
                        signingIn: true,
                        page: "https://linear.app/oauth/authorize?client_id=mock",
                        error: null,
                      }
                    : entry,
                ),
        };
        return {};
      },
      "cmux.settings.agentConfig": (params) => {
        const run = params as AgentConfigRun;
        // Like the host while labs.agentCustomization is off there.
        if (this.agentConfigDisabled) return { enabled: false };
        // Like the host: changes and opens are the person's; a get only reads.
        if (run.verb !== "get") this.agentConfigRuns.push(run);
        const current = this.agentConfig[run.agent];
        if (!current) throw new ProtocolError("cmux.settings.invalid", "agent is claude or codex");
        const { state, answer } = runAgentConfigMock(current, run);
        this.agentConfig[run.agent] = state;
        return answer;
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
        this.actionsRun.push({ action: String(params.action), args: (params.args ?? {}) as Params });
        if (!this.actionRan) return { ran: false };
        this.runProfileAction(
          params.action as string,
          (params.args ?? {}) as Params,
          params.target as string | undefined,
        );
        return { ran: true };
      },
    };
    const native = new Set([
      "cmux.settings.preview",
      "cmux.settings.preview.end",
      "cmux.settings.sound.play",
      "cmux.settings.host.lists",
      "cmux.settings.devices.remove",
      "cmux.settings.devices.full_access",
      "cmux.settings.devices.join_consent",
      "cmux.settings.machines.vm_host",
      "cmux.settings.accounts.state",
      "cmux.settings.accounts.run",
      "cmux.settings.channels.state",
      "cmux.settings.channels.go_back",
      "cmux.settings.channels.update_machine",
      "cmux.settings.channels.switch_build",
      "cmux.settings.agents.state",
      "cmux.settings.agents.run",
      "cmux.chief.profile.list",
      "cmux.chief.profile.avatar.get",
      "cmux.chief.profile.history",
      "cmux.chief.profile.update",
      "cmux.chief.profile.create",
      "cmux.chief.backend.list",
      "cmux.chief.backend.add",
      "cmux.chief.backend.doctor",
      "cmux.settings.harnesses.state",
      "cmux.settings.harnesses.run",
      "cmux.settings.models.state",
      "cmux.settings.models.run",
      "cmux.settings.cloud.allotment.get",
      "cmux.settings.cloud.allotment.set",
      "cmux.settings.devices.state",
      "cmux.settings.devices.run",
      "cmux.settings.environments.state",
      "cmux.settings.environments.run",
      "cmux.settings.customize.run",
      "cmux.settings.shares.list",
      "cmux.settings.customize.library",
      "cmux.settings.customize.checklist",
      "cmux.settings.shares.revoke",
      "cmux.settings.archived.list",
      "cmux.settings.archived.run",
      "cmux.settings.keys.list",
      "cmux.settings.keys.answer",
      "cmux.settings.keys.decline",
      "cmux.settings.keys.revoke",
      "cmux.settings.tailnet.state",
      "cmux.settings.tailnet.start",
      "cmux.settings.tailnet.login",
      "cmux.settings.tailnet.logout",
      "cmux.settings.tailnet.joinVM",
      "cmux.settings.tailnet.leaveVM",
      "cmux.settings.integrations.state",
      "cmux.settings.integrations.run",
      "cmux.settings.agentTools.state",
      "cmux.settings.agentTools.run",
      "cmux.settings.mcp.state",
      "cmux.settings.autocloud.state",
      "cmux.settings.autocloud.run",
      "cmux.settings.hub.state",
      "cmux.settings.hub.run",
      "cmux.settings.connections.state",
      "cmux.settings.connections.run",
      "cmux.settings.agentSkills.state",
      "cmux.settings.agentSkills.run",
      "cmux.settings.mcp.run",
      "cmux.settings.agentConfig",
      "cmux.settings.agentMcp.state",
      "cmux.settings.agentMcp.run",
      "cmux.settings.agentHooks.state",
      "cmux.settings.agentHooks.run",
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
      "cmux.settings.backdrop.image.screen_saver",
      "cmux.settings.backdrop.workspace",
      "cmux.settings.backdrop.workspace.set",
      "cmux.settings.backdrop.workspace.preview",
      "cmux.settings.art.search",
      "cmux.settings.art.use",
      "cmux.settings.app_update.run",
      "cmux.settings.web_updates.check",
      "cmux.settings.web_updates.rollback",
      "cmux.settings.language.relaunch",
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
    provide("cmux.settings.models.changed", (ctx) => this.track(this.modelsChanged, ctx));
    provide("cmux.settings.keys.changed", (ctx) => this.track(this.keysChanged, ctx));
    provide("cmux.settings.channels.machines.changed", (ctx) => this.track(this.machinesChanged, ctx));
    provide("cmux.settings.channels.switch.changed", (ctx) => this.track(this.switchChanged, ctx));
  }

  /** Settings > Team > Compute as the backend serves it (mockAllotments.ts); null is a host without it. */
  allotment: AllotmentView | null = structuredClone(mockAllotments.proposalUp);
  /** Compute gestures the page sent, in order. */
  readonly allotmentRuns: AllotmentSet[] = [];

  /** Settings > Models as the app serves it (mockModels.ts); null is a host without the part. */
  models: ModelsState | null = structuredClone(mockModels.macLogins);
  /** Models gestures the page sent (pasted keys included, so tests can check what was sent). */
  readonly modelRuns: ModelsRun[] = [];
  private readonly modelsChanged = new Set<EventSourceContext>();

  /** Replaces Settings > Models and tells the page, like the app's acpmux change push. */
  setModels(models: ModelsState): void {
    this.models = models;
    for (const ctx of this.modelsChanged) ctx.emit(models);
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

  /** What `cmux customize library` lists (Appearance > Customization Library). */
  library: LibraryListing = mockLibrary();
  /** The CLI's refusal of every library change (a preview is open); null: changes run. */
  libraryRefusal: string | null = null;
  /** Every library change the page ran, in order (tests). */
  readonly libraryRuns: LibraryRun[] = [];
  /** Holds each `customize library list` until it settles; the read answers the library as it was
   * when the read began (a test's slow read that a change overtakes). */
  libraryReadHold: Promise<void> | null = null;

  /** What `cmux customize doctor` reports; default nothing (the start state). */
  doctor: DoctorReport = mockEmptyDoctor();
  /** The CLI's refusal of every doctor change; null: changes run. */
  doctorRefusal: string | null = null;
  /** Every doctor verb but the read the page ran, in order (tests). */
  readonly doctorRuns: DoctorRun[] = [];

  /** `cmux --json customize doctor …` (and the host's own `doctor-open`): the report, or the CLI's
   * error envelope. */
  private runDoctor(run: DoctorRun) {
    if (run.verb !== "doctor") {
      this.doctorRuns.push(run);
      if (this.doctorRefusal) return { code: "customize.doctor", message: this.doctorRefusal };
    }
    const answer = runDoctor(this.doctor, run);
    if ("doctor" in answer && answer.doctor) this.doctor = answer.doctor;
    return answer;
  }

  /** `cmux --json customize library VERB`: the listing, or the CLI's error envelope as the host
   * answers it (a refusal is an answer, not a failed call). */
  private runLibrary(run: LibraryRun): LibraryAnswer | Promise<LibraryAnswer> {
    if (run.verb === "list") {
      const listed = this.library;
      return this.libraryReadHold ? this.libraryReadHold.then(() => ({ library: listed })) : { library: listed };
    }
    if (run.verb.startsWith("doctor")) return this.runDoctor(run as DoctorRun);
    if (!("name" in run)) return { code: "customize.library", message: `unknown verb "${run.verb}"` };
    this.libraryRuns.push(run);
    if (this.libraryRefusal) return { code: "customize.library", message: this.libraryRefusal };
    const next = runLibrary(this.library, run);
    if (!next) return { code: "customize.library", message: `there is no library entry "${run.name}"` };
    this.library = next;
    return { library: next };
  }

  /** Settings > Keys as the app answers it: one request waiting and three keys (live, expired,
   * revoked). */
  keys: KeysState = mockKeys(Date.now());
  /** Every answer the page sent, value included, so tests can check it went to the host once (the
   * real host pipes it to `cmux keys put` and keeps nothing). */
  keyAnswers: { request_id: string; value: string }[] = [];
  keyDeclines: string[] = [];
  keyRevokes: string[] = [];
  /** The host's refusal of the next Store (tests), else null. */
  keyAnswerRefusal: string | null = null;
  private keysRevision = 0;
  private readonly keysChanged = new Set<EventSourceContext>();

  /** Replaces the Keys part and tells the page, as the app does when a request arrives. */
  setKeys(keys: KeysState): void {
    this.keys = keys;
    this.keysRevision += 1;
    for (const ctx of this.keysChanged) ctx.emit({ revision: this.keysRevision });
  }

  private answerKey(params: { request_id?: unknown; value?: unknown }): { stored: boolean; name: string } {
    const id = String(params.request_id ?? "");
    const value = typeof params.value === "string" ? params.value : "";
    const request = this.keys.requests.find((row) => row.id === id);
    if (!request) throw new ProtocolError(ProtocolErrorCode.invalidParams, "keys.request_not_found");
    if (!value) throw new ProtocolError(ProtocolErrorCode.invalidParams, "keys.value_required");
    if (this.keyAnswerRefusal) {
      const refusal = this.keyAnswerRefusal;
      this.keyAnswerRefusal = null;
      throw new ProtocolError(ProtocolErrorCode.invalidParams, refusal);
    }
    this.keyAnswers.push({ request_id: id, value });
    const at = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    this.keys = {
      ...this.keys,
      requests: this.keys.requests.filter((row) => row.id !== id),
      keys: [
        {
          id: `local-${request.name.toLowerCase()}`,
          label: request.name,
          name: request.name,
          provider: "local",
          kind: "secret",
          source: "person",
          purpose: request.purpose,
          hosts: request.hosts,
          stores: [],
          uses: [],
          by: "user=you",
          asked_by: request.requester,
          created_at: at,
          expires_at: null,
          state: "live",
        },
        ...this.keys.keys.filter((key) => key.name !== request.name),
      ],
    };
    return { stored: true, name: request.name };
  }

  private declineKey(id: string): Record<string, never> {
    if (!this.keys.requests.some((row) => row.id === id))
      throw new ProtocolError(ProtocolErrorCode.invalidParams, "keys.request_not_found");
    this.keyDeclines.push(id);
    this.keys = { ...this.keys, requests: this.keys.requests.filter((row) => row.id !== id) };
    return {};
  }

  private revokeKey(id: string): { revoked: string } {
    if (!this.keys.keys.some((key) => key.id === id))
      throw new ProtocolError(ProtocolErrorCode.invalidParams, "keys.not_found");
    this.keyRevokes.push(id);
    this.keys = {
      ...this.keys,
      keys: this.keys.keys.map((key) => (key.id === id ? { ...key, state: "revoked" } : key)),
    };
    return { revoked: id };
  }

  /** What `cmux customize` is trying on; Keep and Revert Now end it. */
  tryOn: CustomizeTryOn | null = null;
  /** Every try-on verb the page ran but status, in order (tests). */
  customizeVerbs: string[] = [];

  /** Settings > Privacy and Security > Shared Links as this Mac's daemon answers it: a guest link with
   * a guest in it, an invite share, and an ended link the card leaves out. */
  shares: SharesState = mockShares(Date.now());
  /** Every share the page revoked, in order (tests). */
  shareRevokes: string[] = [];

  /** Settings > Sidebar > Archived Workspaces: two archived workspaces (one in a group) and a link. */
  archived: ArchivedState = mockArchived();
  /** Every archived-row action the page ran, in order (tests). */
  archivedRuns: ArchivedRun[] = [];

  /** Open leaves the row (it stays archived); Restore and Delete take it out of the list. */
  private runArchived(run: ArchivedRun): { error?: string } {
    const rows = this.archived.rows ?? [];
    if (!rows.some((row) => row.kind === run.kind && row.id === run.id))
      throw new ProtocolError(ProtocolErrorCode.invalidParams, "archived.not_found");
    this.archivedRuns.push(run);
    if (run.action !== "open")
      this.archived = { ...this.archived, rows: rows.filter((row) => !(row.kind === run.kind && row.id === run.id)) };
    return {};
  }

  private revokeShare(id: string): { share_id: string; state: string } {
    const share = this.shares.shares?.find((row) => row.share_id === id);
    if (!share) throw new ProtocolError(ProtocolErrorCode.invalidParams, "share.not_found");
    this.shareRevokes.push(id);
    this.shares = {
      ...this.shares,
      shares: this.shares.shares?.map((row) =>
        row.share_id === id
          ? { ...row, state: "revoked", guests: row.guests.map((g) => ({ ...g, state: "left" })) }
          : row,
      ),
    };
    return { share_id: id, state: "revoked" };
  }
  private readWorktree(params: { path: string }) {
    const project = this.worktreeProjects.find((row) => row.path === params.path);
    const repository = project?.repository ?? {};
    const saved = project?.saved;
    const pick = (key: "setup" | "run" | "teardown") => {
      const value = saved?.[key] ?? repository[key];
      return value ? value : null;
    };
    return {
      root: project?.path ?? "",
      recipe: {
        setup: pick("setup"),
        run: pick("run"),
        teardown: pick("teardown"),
        include: [...(repository.include ?? []), ...(saved?.include ?? [])],
        repository,
        ...(saved ? { saved } : {}),
        files: project?.files ?? [],
      },
      run: { state: "none", output: "", output_start: "0", output_end: "0" },
    };
  }
  /** Settings > Extensions: the installed extensions whose manifests declare settings, as
   * `apps.settings.list` answers them; `stored` is what the person changed. */
  extensionApps: MockExtensionApp[] = [
    {
      app: "acme/standup",
      name: "Standup Notes",
      enabled: true,
      schema: {
        type: "object",
        properties: {
          greeting: {
            type: "string",
            title: "Greeting",
            description: "The first line of each note.",
            default: "Morning!",
            maxLength: 40,
          },
          compact: { type: "boolean", title: "Compact rows", default: false },
          size: { type: "string", title: "Note size", enum: ["small", "large"], default: "small" },
          limit: { type: "integer", title: "Notes kept", minimum: 1, maximum: 50, default: 10 },
        },
      },
      stored: {},
    },
  ];
  /** While true, `cmux.settings.extensions.list` is unknown (a host without the route). */
  extensionsUnsupported = false;

  private extensionValues(app: MockExtensionApp): Record<string, unknown> {
    const values: Record<string, unknown> = {};
    for (const [key, property] of Object.entries(app.schema.properties)) values[key] = property.default;
    return { ...values, ...app.stored };
  }

  /** Like the daemon: every key declared, every value of its type and range, `null` resets it. */
  private setExtensionSettings(params: { app: string; values: Record<string, unknown> }) {
    const app = this.extensionApps.find((row) => row.app === params.app);
    if (!app) throw new ProtocolError("cmux.apps.settings.invalid", `${params.app} declares no settings`);
    for (const [key, value] of Object.entries(params.values)) {
      const property = app.schema.properties[key];
      if (!property) throw new ProtocolError("cmux.apps.settings.invalid", `${params.app} has no setting ${key}`);
      if (value === null) continue;
      const fits = property.enum
        ? property.enum.includes(value as string)
        : property.type === "boolean"
          ? typeof value === "boolean"
          : property.type === "string"
            ? typeof value === "string" && value.length <= (property.maxLength ?? 4096)
            : typeof value === "number" &&
              (property.type !== "integer" || Number.isInteger(value)) &&
              value >= (property.minimum ?? -Infinity) &&
              value <= (property.maximum ?? Infinity);
      if (!fits) throw new ProtocolError("cmux.apps.settings.invalid", `${key} is not a value it allows`);
    }
    const stored = { ...app.stored };
    for (const [key, value] of Object.entries(params.values)) {
      if (value === null) delete stored[key];
      else stored[key] = value;
    }
    app.stored = stored;
    return { app: app.app, values: this.extensionValues(app) };
  }

  /** While set, `cmux.settings.worktree.read` answers only once it resolves (a slow host). */
  worktreeReadHold: Promise<void> | null = null;
  /** Settings > Agents > Worktree Setup: the session host's projects and each one's recipe files. */
  worktreeProjects: MockWorktreeProject[] = [
    {
      path: "/Users/you/src/cmux",
      name: "cmux",
      repository: { setup: "bun install", run: "bun run dev --port $CMUX_PORT", include: [".env", ".env.local"] },
      files: [".worktreeinclude", ".cmux/worktree.toml"],
    },
    {
      path: "/Users/you/src/website",
      name: "website",
      repository: { setup: "npm ci" },
      saved: { setup: "pnpm install", include: ["config/local.json"] },
      files: [".cmux/worktree.toml"],
    },
  ];

  /** Settings > Server > This Mac on Your Tailnet as acpmux answers the app's relay: signed out; null is
   * an acpmux with no tailnet. */
  tailnet: TailnetState | null = { state: "stopped" };
  /** Every tailnet step the page asked for, in order (tests). */
  tailnetSteps: string[] = [];

  /** Start, Login and Logout answer null while true (the relay got no answer); state still reads. */
  tailnetRefuses = false;
  /** Called on every tailnet state read, so a test can wait for the card's next read. */
  onTailnetRead: (() => void) | null = null;
  /** The next this many state reads answer null (the relay dropped them), then reads answer again. */
  tailnetDropReads = 0;
  /** Start and Login fail with this text (acpmux keeps it in its state; the step itself answers null). */
  tailnetFails: string | null = null;

  /** As acpmux does: Start and Login answer `starting` at once and the node publishes its sign-in page
   * on the next read; Logout signs out. */
  private stepTailnet(verb: "start" | "login" | "logout"): TailnetState | null {
    this.tailnetSteps.push(verb);
    if (this.tailnet === null || this.tailnetRefuses) return null;
    if (this.tailnetFails) {
      this.tailnet = { state: "error", error: this.tailnetFails };
      return null;
    }
    if (verb === "logout") return (this.tailnet = { state: "stopped" });
    this.tailnet = { state: "needs_login", browse_to_url: "https://login.tailscale.com/a/1a2b3c4d5e" };
    return { state: "starting" };
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
        env: [
          { name: "NODE_ENV", value: "development" },
          { name: "OPENAI_API_KEY", secret: "openai" },
        ],
        status: "ready",
        error: null,
        log_tail: null,
      },
      {
        id: "env_00000000000000000002",
        name: "api",
        repo: "octo/api",
        setup_script: "make deps",
        env: [],
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
        if (run.name !== undefined ? !run.name.trim() : !run.id) return { error: "Name must be 1-80 characters." };
        if (run.id) {
          // Like CloudDO: a rename alone keeps the snapshot; a repo, script or variable edit makes it stale.
          const builds = run.repo !== undefined || run.setup_script !== undefined || run.env !== undefined;
          this.environments = {
            ...this.environments,
            environments: rows.map((row) =>
              row.id === run.id
                ? {
                    ...row,
                    name: run.name ?? row.name,
                    repo: run.repo === undefined ? row.repo : run.repo || null,
                    setup_script: run.setup_script ?? row.setup_script,
                    env: run.env ?? row.env,
                    status: builds && row.status === "ready" ? "stale" : row.status,
                  }
                : row,
            ),
          };
          return {};
        }
        this.environments = {
          ...this.environments,
          environments: [
            ...rows,
            {
              id: `env_${String(rows.length + 1).padStart(20, "0")}`,
              name: run.name ?? "",
              repo: run.repo || null,
              setup_script: run.setup_script ?? "",
              env: run.env ?? [],
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
      case "openScreen":
      case "shareThisMac":
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
      case "setAgentsMayShare":
        if (state.sharing) this.setDevices({ ...state, sharing: { ...state.sharing, agentsMayShare: run.on } });
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
  private readonly switchChanged = new Set<EventSourceContext>();

  /** Moves the running Switch or Go Back to its next stage (null: it ended) and tells the page,
   * like the app's push; a later read of the card answers it too. */
  setSwitchProgress(progress: ChannelsProgress | null): void {
    if (this.channels) this.channels = { ...this.channels, progress };
    for (const ctx of this.switchChanged) ctx.emit(progress);
  }
  /** Holds every Switch and Go Back reply until it resolves, as a host that answers only once
   * the switch ends would; null: they answer at once. */
  switchHold: Promise<void> | null = null;
  /** The way back the host answers with (Nightly's: the fixture runs a Dev build). */
  channelSwitch: ChannelSwitch | null = null;
  /** The build the card's Go Back asked for. */
  wentBack: string | null = null;
  /** The build the card's last Switch asked for. */
  switchedTo: string | null = null;
  /** The host's refusal of every join consent switch press (`cmux.app.user_only`); null: it runs. */
  joinConsentRefusal: string | null = null;
  /** The `error` a join consent switch press's reply carries (the host was busy with another write); null: it runs. */
  joinConsentReplyError: string | null = null;
  /** The host's refusal of every Switch; null: Switch runs. */
  switchRefusal: string | null = null;
  /** Why Open Theme File's export failed (the CLI's last stderr line); null: the file opens. */
  themeFileRefusal: string | null = null;
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
  /** `cmux setup mcp` as the app serves it (`SettingsAgentTools.state`). */
  agentTools: AgentToolsCardState = {
    loaded: true,
    applying: false,
    failed: false,
    choice: "on",
    rows: [
      { id: "claude", name: "Claude Code", state: "terminals" },
      { id: "codex", name: "Codex", state: "terminals" },
    ],
    manual: [
      "claude mcp add --scope user cmux -- '/Applications/cmux NEXT.app/Contents/Resources/bin/cmux' mcp serve",
      "codex mcp add cmux -- '/Applications/cmux NEXT.app/Contents/Resources/bin/cmux' mcp serve",
    ],
  };
  /** Agents on This Mac gestures the page sent (turnOn). */
  readonly agentToolsRuns: AgentToolsCardRun[] = [];
  /** When set, Remove keeps the entry and the host says why (`note`), as for an entry with
   * settings cmux could not put back. */
  agentToolsKeeps: string | null = null;

  /** Settings > Automations as the app serves it (`SettingsAutomationsCloud.state`). */
  autocloud: AutocloudState = mockAutocloudState();
  /** Every Automations action but refresh and preview, in order. */
  autocloudRuns: AutocloudAction[] = [];

  /** Settings > Integrations as the app serves it (`SettingsIntegrationsHub.state`). */
  hub: HubState = mockHubState();
  /** Every Integrations gesture but refresh, in order (the key a Link sent included). */
  hubRuns: HubRun[] = [];

  /** Settings > Connections as the app serves it (`SettingsConnections.state`). */
  connections: ConnectionsState = mockConnectionsState();
  /** Every Connections gesture but refresh, in order (a pasted key included). */
  connectionsRuns: ConnectionsRun[] = [];

  /** The person's saved MCP servers as the app serves them (`SettingsMcpServers.state`). */
  mcpServers: McpServersState = {
    loading: false,
    problem: null,
    servers: [
      {
        name: "linear",
        kind: "remote",
        address: "https://mcp.linear.app/mcp",
        publisher: "linear.app",
        verified: true,
        state: "connected",
        problem: null,
        scope: "agents",
        tools: 23,
        signingIn: false,
        page: null,
        error: null,
      },
      {
        name: "slack",
        kind: "remote",
        address: "https://mcp.slack.com/mcp",
        publisher: "slack.com",
        verified: true,
        state: "signInNeeded",
        problem: null,
        scope: "chief",
        tools: 0,
        signingIn: false,
        page: null,
        error: null,
      },
      {
        name: "notes",
        kind: "local",
        address: "npx -y @example/notes-mcp",
        publisher: "local",
        verified: false,
        state: "failed",
        problem: "the command exited with status 1",
        scope: "chat",
        tools: 0,
        signingIn: false,
        page: null,
        error: null,
      },
    ],
  };
  /** Settings > Agents > Claude Code & Codex: each agent's settings as `agent-config settings get`
   * answers them (mockAgentConfig.ts); `set` and `unset` change them in memory. */
  agentConfig: Record<AgentConfigAgent, AgentConfigState> = mockAgentConfig();
  /** Every Claude Code & Codex change and open the page sent (a get is not recorded). */
  readonly agentConfigRuns: AgentConfigRun[] = [];
  /** The host's lab is off: every call answers `{enabled: false}`. */
  agentConfigDisabled = false;
  /** MCP Servers gestures the page sent (sign in, remove). */
  readonly mcpServerRuns: McpServersRun[] = [];
  /** Settings > Agents > Claude Code & Codex > Skills (`SettingsAgentSkills.state`); Labs off by default. */
  agentSkills: AgentSkillsState = { enabled: false };
  /** Skills gestures the page sent (open, reveal, on, off). */
  readonly agentSkillRuns: AgentSkillsRun[] = [];
  /** Settings > MCP Servers, Claude Code and Codex: off (Labs) until a test or gallery turns it on. */
  agentMcp: AgentMcpState = {
    enabled: false,
    loading: false,
    problem: null,
    project: "/Users/me/src/app",
    listMs: 38,
    cliMs: 21,
    error: null,
    problems: [],
    servers: [
      {
        agent: "claude",
        name: "agent-memory",
        scope: "user",
        transport: "stdio",
        command: "/Users/me/bin/agent-memory",
        args: ["mcp"],
        url: null,
        enabled: true,
        env: [],
        headers: [],
        file: "/Users/me/.claude.json",
        shadowed: false,
        removable: true,
      },
      {
        agent: "claude",
        name: "linear",
        scope: "user",
        transport: "http",
        command: null,
        args: [],
        url: "https://mcp.linear.app/mcp",
        enabled: false,
        env: [],
        headers: ["Authorization"],
        file: "/Users/me/.claude.json",
        shadowed: false,
        removable: true,
      },
      {
        agent: "claude",
        name: "playwright",
        scope: "project",
        transport: "stdio",
        command: "npx",
        args: ["@playwright/mcp@latest"],
        url: null,
        enabled: true,
        approval: "pending",
        env: [],
        headers: [],
        file: "/Users/me/src/app/.mcp.json",
        shadowed: false,
        removable: true,
      },
      {
        agent: "codex",
        name: "repo",
        scope: "user",
        transport: "stdio",
        command: "/Users/me/bin/repo-tools",
        args: ["mcp"],
        url: null,
        enabled: true,
        env: ["REPO_TOKEN"],
        headers: [],
        file: "/Users/me/.codex/config.toml",
        shadowed: false,
        removable: true,
      },
      {
        agent: "codex",
        name: "openaiDeveloperDocs",
        scope: "user",
        transport: "http",
        command: null,
        args: [],
        url: "https://developers.openai.com/mcp",
        enabled: true,
        env: [],
        headers: [],
        file: "/Users/me/.codex/config.toml",
        shadowed: false,
        removable: true,
      },
      {
        agent: "codex",
        name: "codex_app",
        scope: "plugin",
        transport: "stdio",
        command: "./scripts/launch_codex_app_tools_mcp",
        args: ["./server.mjs"],
        url: null,
        enabled: false,
        env: ["CODEX_APP_TOOLS_DEFERRED"],
        headers: [],
        file: "/Users/me/.codex/plugins/cache/openai-bundled/codex-app-tools/1.0/.mcp.json",
        plugin: "codex-app-tools@openai-bundled",
        shadowed: false,
        removable: false,
      },
    ],
  };
  /** Claude Code / Codex MCP gestures the page sent. */
  readonly agentMcpRuns: AgentMcpRun[] = [];

  /** Settings > Agents > Claude Code & Codex > Hooks as the app serves it (`SettingsAgentHooks.state`);
   * `{ available: false }` is the Labs switch off. */
  agentHooks: AgentHooksState = {
    available: true,
    error: null,
    listing: {
      counts: { claude: 3, codex: 2 },
      codex_hooks_feature: true,
      elapsed_micros: 900,
      files: [],
      hooks: [
        {
          id: "claude-0a1b2c3d4e",
          agent: "claude",
          scope: "user",
          file: "/Users/me/.claude/settings.json",
          event: "PreToolUse",
          matcher: "Bash",
          type: "command",
          command: "bash ~/.claude/hooks/guard.sh",
          timeout: null,
          enabled: true,
          owner: "user",
          read_only: false,
        },
        {
          id: "claude-1a1b2c3d4e",
          agent: "claude",
          scope: "user",
          file: "/Users/me/.claude/settings.json",
          event: "Stop",
          matcher: null,
          type: "command",
          command: "notify-done",
          timeout: 5,
          enabled: false,
          owner: "user",
          read_only: false,
        },
        {
          id: "claude-2a1b2c3d4e",
          agent: "claude",
          scope: "user",
          file: "/Users/me/.claude/settings.json",
          event: "SessionStart",
          matcher: null,
          type: "command",
          command: '"${CMUX_TUI_HOOK:-:}" claude SessionStart;#cmux-tui-journal-hook',
          timeout: 5,
          enabled: true,
          owner: "cmux",
          read_only: true,
        },
        {
          id: "codex-3a1b2c3d4e",
          agent: "codex",
          scope: "user",
          file: "/Users/me/.codex/hooks.json",
          event: "PreToolUse",
          matcher: "Bash",
          type: "command",
          command: "lazy-command hook",
          timeout: null,
          enabled: true,
          owner: "user",
          read_only: false,
          trust: "trusted",
        },
        {
          id: "codex-4a1b2c3d4e",
          agent: "codex",
          scope: "user",
          file: "/Users/me/.codex/hooks.json",
          event: "Stop",
          matcher: null,
          type: "command",
          command: "say done",
          timeout: null,
          enabled: true,
          owner: "user",
          read_only: false,
          trust: "untrusted",
        },
      ],
    },
  };
  readonly agentHookRuns: AgentHooksRun[] = [];
  /** Agent integrations gestures the page sent (install, repair, remove). */
  readonly integrationRuns: IntegrationsRun[] = [];

  /** Harnesses gestures the page sent. */
  readonly harnessRuns: HarnessesRun[] = [];
  private readonly harnessesChanged = new Set<EventSourceContext>();

  /** Like the host's account gestures: a listed account only, and Add account for Codex and Claude (a
   * login folder under ~/.cmux/accounts, signed out until its sign-in runs, or an API key). */
  private runAccount(run: HarnessesRun): Record<string, never> {
    // Like the host: GitHub's terminal sign-in is gh's own `gh auth login`, needing no account list.
    if (run.action === "accountAdd" && run.family === "github" && run.way === "new") {
      this.harnessRuns.push(run);
      return {};
    }
    const accounts = this.harnesses.accounts;
    if (!accounts) throw new ProtocolError("cmux.settings.invalid", "this daemon lists no accounts");
    if (run.action === "accountAdd") {
      const family = run.family ?? "";
      const brand = ({ codex: "ChatGPT", claude: "Claude" } as Record<string, string>)[family];
      if (!brand) throw new ProtocolError("cmux.settings.invalid", "accountAdd needs codex or claude");
      if (run.way === "key" && !run.secret)
        throw new ProtocolError("cmux.settings.invalid", "a key needs its reference");
      let number = Math.max(2, accounts.filter((account) => account.family === family).length + 1);
      while (accounts.some((account) => account.id === `${family}-${number}`)) number += 1;
      this.harnessRuns.push(run);
      const id = `${family}-${number}`;
      const key = run.way === "key";
      this.setHarnesses({
        ...this.harnesses,
        accounts: [
          ...accounts,
          {
            id,
            family,
            name: run.name ?? `${brand} ${number}`,
            home: key ? null : `~/.cmux/accounts/${id}`,
            defaultHome: `~/.${family}`,
            shadowOf: family === "codex" && !key ? `~/.codex` : null,
            signedIn: key,
            plan: null,
            email: null,
            enabled: true,
            builtin: false,
            default: false,
            key,
          },
        ],
      });
      return {};
    }
    if (!accounts.some((account) => account.id === run.account)) {
      throw new ProtocolError("cmux.settings.invalid", "account must be a listed account");
    }
    const target = accounts.find((account) => account.id === run.account)!;
    // Like the host: a disabled account is never made the default.
    if (run.action === "accountDefault" && !target.enabled) {
      throw new ProtocolError("cmux.settings.invalid", "accountDefault needs an enabled account");
    }
    this.harnessRuns.push(run);
    const change = (next: ProviderAccount[]) => this.setHarnesses({ ...this.harnesses, accounts: next });
    if (run.action === "accountEnable") {
      change(accounts.map((account) => (account === target ? { ...account, enabled: run.on === true } : account)));
    } else if (run.action === "accountRename" && run.name) {
      change(accounts.map((account) => (account === target ? { ...account, name: run.name! } : account)));
    } else if (run.action === "accountDefault") {
      change(
        accounts.map((account) =>
          account.family === target.family ? { ...account, default: account === target } : account,
        ),
      );
    } else if (run.action === "accountRemove") {
      change(accounts.filter((account) => account !== target));
    }
    return {};
  }

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
    context_menus: mockContextMenus(),
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
    computer_use: {
      phase: "ready",
      accessibility: true,
      screen_recording: false,
      helper: "cmux Computer Use",
      engine: "cmux Computer Use 1.0",
      worker: { state: "running", pid: 4242 },
      approvals: [
        { app_id: "com.apple.Safari", name: "Safari", decision: "always" },
        { app_id: "com.apple.MobileSMS", name: "Messages", decision: "never" },
      ],
      running_apps: [
        { id: "com.apple.Safari", name: "Safari" },
        { id: "com.apple.Notes", name: "Notes" },
        { id: "com.figma.Desktop", name: "Figma" },
      ],
    },
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
  /** The macOS screen saver as a background id (Use My Screen Saver); null: not an aerial. */
  screenSaver: string | null = null;
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
  /** The Teams part (roles, details, create, rename, delete); tests edit its teams and flags. */
  readonly teams = new MockTeams();

  /** The Accounts part with the Teams part while signed in, unless a test set `teamList` itself. */
  private accountsState(): AccountsState {
    if (this.accounts.teamList !== undefined || !this.accounts.teams) return this.accounts;
    return { ...this.accounts, teamList: this.teams.state() };
  }

  /** What the app's AccountsModel does to the state (enough for the page's tests). */
  private runAccounts(run: AccountsRun): AccountsRunReply | Promise<AccountsRunReply> {
    this.accountRuns.push(run);
    if ((Object.values(ACCOUNT_ACTIONS) as string[]).includes(run.action)) return this.signIn.run(run);
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
      if (run.team) this.teams.active = run.team;
    } else if (run.action.startsWith("team.")) {
      error = this.teams.run(run) ?? undefined;
      // The Active Team menu lists the same teams and follows a create or delete.
      if (this.accounts.teams) {
        const active = this.teams.active;
        this.accounts = {
          ...this.accounts,
          teams: {
            ...this.accounts.teams,
            options: this.teams.teams.map((team) => ({ id: team.id, name: team.name, active: team.id === active })),
          },
        };
      }
    } else if (run.action.startsWith("agentKey") && this.accounts.agentKeys) {
      this.accounts = { ...this.accounts, agentKeys: runMockAgentKeys(this.accounts.agentKeys, run) };
    } else if (run.action === "remove") {
      this.accounts = rows((row) => ({ ...row, linked: row.linked.filter((account) => account.id !== run.account) }));
    } else if (run.action === "cmux.signOut" || run.action === "cmux.cancelSignIn") {
      this.accounts = { ...this.accounts, cmux: mockCmuxAccount.signedOut };
    } else if (run.action === "cmux.signIn") {
      this.accounts = { ...this.accounts, cmux: mockCmuxAccount.signingIn };
    }
    for (const ctx of this.accountsChanged) ctx.emit(this.accountsState());
    return error ? { error } : {};
  }

  /** The in-place sign-in (shared/signIn/mockSignIn.ts) as the daemon answers it, on
   * `accounts.signInAccounts`; onboarding's mock runs the same one. */
  readonly signIn = new MockAccountSignIn({
    rows: () => this.accounts.signInAccounts ?? [],
    set: (next) => {
      this.accounts = { ...this.accounts, signInAccounts: next };
      for (const ctx of this.accountsChanged) ctx.emit(this.accountsState());
    },
  });
  /** A sign-in's finish waits for this when set (tests and the gallery hold the code on screen). */
  get signInHold(): Promise<void> | null {
    return this.signIn.hold;
  }
  set signInHold(hold: Promise<void> | null) {
    this.signIn.hold = hold;
  }
  /** The next sign-in start is refused with this reason (`not_installed`, `shared_machine`, ...). */
  get signInRefusal(): string | null {
    return this.signIn.refusal;
  }
  set signInRefusal(reason: string | null) {
    this.signIn.refusal = reason;
  }
  /** How long a started sign-in's code lasts (tests shorten it to see the expiry). */
  get signInExpiresInMs(): number {
    return this.signIn.expiresInMs;
  }
  set signInExpiresInMs(ms: number) {
    this.signIn.expiresInMs = ms;
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

  /** What the app's `computerUse.approval.*` actions do to the saved approvals. */
  private runApprovalAction(action: string, args: Params): void {
    const computerUse = this.host.computer_use;
    if (!computerUse) return;
    const approvals = computerUse.approvals ?? [];
    const next: ComputerUseApproval[] =
      action === "computerUse.approval.forget"
        ? approvals.filter((approval) => approval.app_id !== args.app_id)
        : approvals.map((approval) =>
            approval.app_id === args.app_id && (args.decision === "always" || args.decision === "never")
              ? { ...approval, decision: args.decision }
              : approval,
          );
    this.setHost({ ...this.host, computer_use: { ...computerUse, approvals: next } });
  }

  setHost(host: HostLists): void {
    this.host = host;
    for (const ctx of this.hostChanged) ctx.emit(host);
  }

  /** What the app's `browserProfile.*` actions do to the lists (enough for the page's tests). */
  private runProfileAction(action: string, args: Params, target: string | undefined): void {
    if (action === "computerUse.approval.forget" || action === "computerUse.approval.set") {
      this.runApprovalAction(action, args);
      return;
    }
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
  setActionRan(actionRan: boolean): void {
    this.actionRan = actionRan;
  }

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
      domains: this.domains ?? {
        themes: null,
        font_families: null,
        ui_font_families: null,
        sounds: null,
        recent_fonts: null,
      },
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
      stored: this.values.get(key) ?? null,
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
    if (!hostRowsByKey.has(key)) throw new ProtocolError("cmux.settings.invalid", `unknown setting ${key}`);
    const managed = this.managed.get(key);
    if (managed) {
      throw new ProtocolError("cmux.settings.managed", managed.reason, {
        details: { key, source: managed.source, reason: managed.reason },
      });
    }
  }

  private set(key: string, value: unknown): MutationResult {
    this.guard(key);
    const refusal = this.refusals[key];
    if (refusal) throw new ProtocolError("cmux.settings.invalid", refusal.message, { details: refusal.details });
    const reason = validate(hostRowsByKey.get(key)!, value, this.domains ?? undefined);
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
      agentsToggle: "My agents can turn screen sharing and control on my machines",
      agentsDetail: "Your agents share without asking, with a notice each time.",
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
      screenAction: { kind: "share", title: "Share" },
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
        screenAction: { kind: "view", title: "View screen", disabled: true },
        removeConfirm: removeConfirm("MacBook Pro"),
      },
    ],
    sharing: {
      on: true,
      busy: false,
      agentsMayShare: false,
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

/** Settings > Keys at `now`: Claude Code asks for a deploy token for two sites; a live key it
 * stored and wrote to a repository secret, an expired provider key, and a revoked key the person typed. */
export function mockKeys(now: number): KeysState {
  const day = 86_400_000;
  const at = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
  return {
    available: true,
    requests: [
      {
        id: "kr_0001",
        name: "DEPLOY_TOKEN",
        purpose: "Deploy the preview build to the staging site",
        hosts: ["api.example.com"],
        requester: "CLAUDE_CODE_SESSION_ID=4f2a9c1e-77b0-4d1a-9e3b-0c5d6e7f8a9b",
        asked_at: at(now - 2 * 60_000),
      },
    ],
    keys: [
      {
        id: "local-search_api_key",
        label: "SEARCH_API_KEY",
        name: "SEARCH_API_KEY",
        provider: "local",
        kind: "secret",
        source: "stdin",
        purpose: "Embeddings for the search index",
        hosts: ["search.example.com"],
        stores: ["gh-secret:example/search:SEARCH_API_KEY"],
        uses: [{ target: "search.example.com", last_used_at: at(now - 3_600_000), count: 12 }],
        by: "CLAUDE_CODE_SESSION_ID=9b1c2d3e-0000-4000-8000-000000000001",
        asked_by: null,
        created_at: at(now - 3 * day),
        expires_at: at(now + 87 * day),
        state: "live",
      },
      {
        id: "cf-7d1e",
        label: "Bucket handoff (read and write)",
        provider: "cloudflare",
        kind: "r2",
        source: "cloudflare",
        bucket: "handoff",
        purpose: null,
        hosts: [],
        stores: ["keychain:handoff"],
        uses: [],
        by: "CODEX_SESSION_ID=0c9d8e7f-1111-4000-8000-000000000002",
        asked_by: null,
        created_at: at(now - 10 * day),
        expires_at: at(now - day),
        state: "expired",
      },
      {
        id: "local-publish_token",
        label: "PUBLISH_TOKEN",
        name: "PUBLISH_TOKEN",
        provider: "local",
        kind: "secret",
        source: "person",
        purpose: "Publish the CLI package",
        hosts: ["registry.example.com"],
        stores: [],
        uses: [],
        by: "user=you",
        asked_by: "CLAUDE_CODE_SESSION_ID=4f2a9c1e-77b0-4d1a-9e3b-0c5d6e7f8a9b",
        created_at: at(now - 20 * day),
        expires_at: null,
        state: "revoked",
      },
    ],
  };
}

/** This Mac's shares at `now`: a guest link with a guest in it (shared 2 h ago, 24 h), an invite
 * share with two accounts (yesterday, 7 days) and a revoked link the card leaves out. */
export function mockShares(now: number): SharesState {
  const hour = 3_600_000;
  return {
    available: true,
    titles: { "12": "Fix the flaky login test", "31": "Plan the onboarding redesign" },
    shares: [
      {
        share_id: "sh_link_0001",
        state: "active",
        session: "s-login",
        surface: 12,
        created_at: now - 2 * hour,
        expires_at: now + 22 * hour,
        uses_left: 0,
        invite_url: null,
        guests: [{ guest_id: "g1", name: "Sam", joined_at: now - hour, state: "active" }],
        invitees: [],
      },
      {
        share_id: "sh_invite_0002",
        state: "active",
        session: "s-onboarding",
        surface: 31,
        created_at: now - 26 * hour,
        expires_at: now + 142 * hour,
        uses_left: 1,
        invite_url: "https://share.example.com/i/sh_invite_0002",
        guests: [],
        invitees: [
          { account: "ana@example.com", role: "talk", invited_at: now - 26 * hour, state: "invited" },
          { account: "@kim", role: "view", invited_at: now - 25 * hour, state: "invited" },
        ],
      },
      {
        share_id: "sh_old_0003",
        state: "revoked",
        session: "s-old",
        surface: 7,
        created_at: now - 72 * hour,
        expires_at: now + 2 * hour,
        uses_left: 0,
        invite_url: null,
        guests: [],
        invitees: [],
      },
    ],
  };
}

/** Archived rows as the app lists them, in sidebar order. */
export function mockArchived(): ArchivedState {
  return {
    available: true,
    rows: [
      { kind: "workspace", id: "ws-archived-1", title: "Fix the flaky login test", group: null, machine: "This Mac" },
      { kind: "workspace", id: "ws-archived-2", title: "Release notes draft", group: "Docs", machine: "This Mac" },
      { kind: "item", id: "itm-archived-link", title: "Design review", group: null, machine: null },
    ],
  };
}
