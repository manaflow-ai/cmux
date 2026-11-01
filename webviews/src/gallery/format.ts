// The gallery's fixture format: ONE format for both hosts (the web gallery here, the DEBUG native
// gallery in cmux-next, CmuxNextGallery). A `<name>.gallery.ts(x)` file next to a component or
// page exports one entry by default: an id, which host draws it, what it covers and its named
// variants. A variant is plain data of the real structures (an AcpmuxSnapshot, a markdown file, a
// patch, a Swift model's JSON), never a copy of the component: the host feeds it through the
// input the app uses (the pane bridge, the cmuxPage bridge, the Swift view's model), so the real
// code renders it.
//
// Ids are dotted lower kebab case (`agent-pane.transcript`, `home.list-row`), the same in Swift
// and TypeScript; variant names are lower kebab case (`pending-single`, `9`). The URL names both.
//
// Gallery files import types only (and pure data helpers), so a test can import every one of them
// without a DOM (test/gallery-coverage.test.ts). A component host loads its component lazily.
import type { ComponentType } from "react";
import type { AcpmuxSnapshot } from "../agent-session/acpmux/model";
import type { AppDetail, Grants, InstalledApp } from "../pages/apps/types";
import type { CloudMachine, CloudSnapshot } from "../pages/cloud/ops";
import type { ProviderRow } from "../pages/coderouter/types";
import type { ReleaseNotes } from "../pages/changelog/types";
import type { PickerSession } from "../pages/icon-picker/host";
import type { EditorFile, ReadOnlyReason } from "../pages/editor/host";
import type { HistoryFilter, HistoryGrouping } from "../pages/history/model";
import type { HistoryEntry } from "../pages/history/types";
import type { Binding } from "../pages/keybindings/types";
import type { WidthName } from "./env";
import { checkReasons, type Play, type PlayChecks, type PlayTarget } from "./play";
import { armIds, validateExperiments, type Experiment } from "../experiments/experiment";
import { validateTunables, type Tunable } from "../experiments/tunable";
import { optionAccepts, validateOptions, type GalleryOption } from "./options";
import type { MockOptions } from "../pages/settings/mockProvider";
import type {
  AccountsState,
  AgentsState,
  CloudEnvironmentsState,
  DevicesState,
  HarnessesState,
  HostLists,
  IntegrationsState,
} from "../pages/settings/ops";
import type { MockData } from "../pages/passwords/mockProvider";

/** Initial gestures use the real controls, so local forms remain interactive. */
export type PageFixtureStep = {
  selector: string;
  action: "click" | "input" | "change" | "focus" | "select" | "enter" | "wait";
  value?: string;
};
export type SettingsPageVariant = VariantBase & {
  section: string;
  focus?: string;
  /** The workspace the page was opened for (Change Background… on a workspace). */
  workspace?: string;
  options?: MockOptions;
  host?: Partial<HostLists>;
  accounts?: AccountsState;
  /** Settings > Accounts > Cloud Environments fixture state. */
  environments?: CloudEnvironmentsState;
  /** Settings > Agents over the mock's harness list (`manages: false`: an older acpmux). */
  agents?: Partial<AgentsState>;
  /** Settings > Agents > Harnesses; default the mock's four. */
  harnesses?: HarnessesState;
  /** Settings > Devices; default the mock's (this Mac, two other devices, two relays). */
  devices?: DevicesState;
  /** Settings > Agents > Agent integrations; default the mock's four (focus `agents.integrations` opens it). */
  integrations?: IntegrationsState;
  /** Public-safe thumbnail data URLs for native-origin backdrop images. */
  backdropImages?: Record<string, string>;
  loading?: boolean;
  steps?: PageFixtureStep[];
  /** Publish every bundled theme and its colors (the app does); default the mock's six. */
  allThemes?: boolean;
};
export type PasswordsPageVariant = VariantBase & {
  data: MockData;
  loading?: boolean;
  authenticate?: boolean;
  gesture?: boolean;
  confirm?: boolean;
  failure?: { op: string; code: string; message: string };
  steps?: PageFixtureStep[];
};

/** Public-safe answers for the agent pane's link/image/browser host calls. */
export type ChipHostFixture = {
  paths?: Record<string, { place: "root" | "outside" | "denied" | "missing"; folder: boolean }>;
  sites?: Record<string, { icon?: string; title?: string }>;
  policy?: {
    outsideRoots?: "confirm" | "text" | "open";
    remoteImages?: "click" | "never" | "always";
    clickFreeImageHosts?: string[];
  };
  images?: Record<string, string | null>;
  /** `media.load` answers: the URL the player plays for each path. */
  media?: Record<string, string>;
  browsers?: { id: string; name: string; icon?: string }[];
  /** `project.icon` answers: a project folder's favicon as a data URL (projectIcon.ts). */
  projectIcons?: Record<string, string>;
  /** `project.icon` answers' `glyph`: a project folder's language or framework (projectIcon.ts). */
  projectGlyphs?: Record<string, string>;
  /** `pr.inspect` answers, by pull request address: the pull request card's own fixture. */
  pullRequests?: Record<string, PullRequestFixture>;
};

/** One `pr.inspect` answer: what the host has for a pull request, and how old it is. */
export type PullRequestFixture = {
  pullRequest: Record<string, unknown> | null;
  /** Seconds since 1970; left out when the host has never had an answer. */
  fetchedAt?: number;
  reading?: boolean;
};

/** One step of an experiment's scripted interaction (the compare view replays them in sync). */
export type ExperimentStep = { name: string; run: Play };

/** Frame timings of one arm, from a matrix run on a Freestyle VM (scripts/gallery-matrix). */
export type ArmMeasurement = {
  /** The matrix run's name (its index is at :18796/matrix/<run>/). */
  run: string;
  engine: "chromium" | "webkit";
  /** Frames sampled across the script's steps. */
  frames: number;
  /** Frame interval percentiles and maximum, in ms. */
  p50: number;
  p95: number;
  max: number;
  /** Frames over 16.7 ms. */
  over16: number;
  /** Main-thread time the arm spent planning its motion, in ms per toggle (largest). */
  planMs?: number;
  /** Action-to-settled samples across clicks, keys and press-drag pointer steps. */
  settleCount?: number;
  settleP50?: number;
  settleP95?: number;
  settleMax?: number;
  /** The frame strip image, relative to the run's folder. */
  strip?: string;
};

/**
 * An entry's experiment: the arms of `definition` render the same variant side by side in the
 * `compare` view, and `script` drives them all at once. `setup` runs before step 1 with every
 * animation finished at once (the starting state). `measurements` are the numbers a matrix run
 * measured for each arm, shown in the cell captions.
 */
export type GalleryExperiment = {
  definition: Experiment;
  setup?: Play;
  script: ExperimentStep[];
  measurements?: Record<string, ArmMeasurement>;
};

/** Common to every variant. */
type VariantBase = {
  /** One line for the stage header: what the variant shows. */
  note?: string;
  /** The stage's height in px; else the entry's. */
  height?: number;
  /**
   * Steps that drive the mounted page into the variant's state (play.ts): an open menu, a typed
   * prompt. They run before the stage is ready, in the shell and in the matrix runner alike.
   */
  play?: Play;
  /** Variant-specific play thresholds, merged over the entry defaults. */
  checks?: PlayChecks;
};

/** The whole agent pane (AcpmuxApp) on the pane bridge, as the app hosts it. */
export type AgentPaneVariant = VariantBase & {
  /** Fields of the `ready` answer the app sends (newTab, draft, newSession, machineName, ...). */
  ready?: Record<string, unknown>;
  /** Fields over the theme the app pushes (`applyTheme`, AgentPaneTheme.swift), such as a Debug
   *  Settings value it carries (`chatWidth`). */
  theme?: Record<string, unknown>;
  /** The snapshot the bridge delivers after `ready`. */
  snapshot: AcpmuxSnapshot;
  /** With `ready.transport: "mock"`: the harnesses the mock daemon lists (`[]`: none installed). */
  mockHarnesses?: unknown[];
  /** Mock-daemon health rows by harness id. Absent keeps its signed-in default. */
  mockHarnessHealth?: Record<string, { auth: "signedIn" | "signedOut" | "unknown"; login?: string }>;
  /** With `ready.transport: "mock"`: the capability ids the mock daemon's `initialize` names. */
  mockCapabilities?: string[];
  /** Mock-daemon selected-session auth reply. Expiry is session-scoped, never a harness health row. */
  mockSessionAuth?: {
    state: "ready" | "signedOut" | "expired" | "routeAuthNeeded" | "routeUnreachable" | "peerUnreachable" | "unknown";
    source: "peerLink" | "routeProbe" | "turn" | "authCheck" | "none";
    evidenceAt: number | null;
    detail?: string;
    harness: string;
    host: string | null;
    routeId: string | null;
    fromSessionId: string | null;
    login?: { kind: "terminal" | "route"; command?: string; host?: string | null; routeId?: string | null };
  };
  /** Answers for native page methods (`turn.undo`, ...) by name; any other method answers null.
   * `{ nativeError: {code, userMessage?} }` answers as the app refusing the call. */
  native?: Record<string, unknown>;
  /** Gallery-only answers for the reply chips and preview card's host calls. */
  chipHost?: ChipHostFixture;
  /** The snapshot the bridge delivers after the pane makes a host call, by method: what acpmux
   *  would send next (`chat.cancel`: the turn ends and the next queued prompt starts). */
  afterCall?: Record<string, AcpmuxSnapshot>;
  /** Milliseconds a native method's answer waits, by method: a slow host call the pane shows as
   *  in progress (New Worktree's "Creating worktree…"). */
  nativeDelayMs?: Record<string, number>;
  /** The in-session status toggle (Debug Settings `agent.sessionStatus`, off by default) on, as the
   *  app's `sessionStatus` push sends it: the live plan card and the recap card. */
  sessionStatus?: boolean;
  /** The chat's `display` push (AgentPaneDisplaySetting.swift, chatDisplay.ts): `agentPane.display.*`
   *  keys and the app keys the chat follows, such as Minimal Mode (`{ "sidebar.minimal": true }`). */
  display?: Record<string, unknown>;
  /** Claude workflows (on by default; false as the app's `workflowLabs` push would send it turns
   *  them off): a Claude workflow's transcript card and its Session Info panel. */
  workflowLabs?: boolean;
  /** `<html data-*>` attributes the app sets at document start for Debug Settings choices
   *  (AgentPaneTunables `documentAttributes`), by name without `data-`: `{ "needs-you": "off" }`. */
  documentAttributes?: Record<string, string>;
};

/** The markdown editor page (src/pages/markdown) on an in-page cmuxPage host. */
export type MarkdownPageVariant = VariantBase & {
  path: string;
  /** Null: the page opens in its empty state (no file). */
  text: string | null;
  readOnly?: boolean;
  /** Gallery-only GitHub `origin` repository used for bare issue references. */
  githubRepository?: string;
  /** cmux.json's `markdown` section. */
  settings?: Record<string, unknown>;
  /** The user's markdown/theme.css. */
  themeCSS?: string;
  /** Other files links may name (and the empty state's recents). */
  files?: Record<string, string>;
  /** Opens find (the `find` page command, Cmd-F) with this query once the document shows. */
  find?: string;
};

/** One file of a diff fixture: the text before (absent for a new file) and after (absent when deleted). */
export type DiffFixtureFile = { path: string; before?: string; after?: string };

/** The diff viewer page (src/pages/diff) on an in-page cmuxPage host serving fixed patches. */
export type DiffPageVariant = VariantBase & {
  title?: string;
  layout?: "split" | "unified";
  /** A unified patch (`git diff` output) or files to diff. */
  patch?: string;
  files?: DiffFixtureFile[];
  repoRoot?: string;
  baseRef?: string;
  /** A machine error while the loaded diff remains visible. */
  fingerprintError?: { code: string; message: string };
};

/** The App Store page on an in-page cmuxPage host serving its supervisor projection. */
export type AppsPageVariant = VariantBase & {
  hash?: string;
  mode?: "normal" | "loading" | "error";
  action?: "install";
  error?: { code: string; message: string };
  /** One transient detail failure after the catalog has loaded, for recovery-state coverage. */
  detailError?: { code: string; message: string };
  data: {
    details: Record<string, AppDetail>;
    installed: Record<string, InstalledApp>;
    grants: Record<string, Grants>;
  };
};

/** The Cloud page on an in-page cmuxPage host serving the Cloud app server's projection. */
export type CloudPageVariant = VariantBase & {
  mode?: "normal" | "loading" | "error";
  action?: "select-machine" | "create" | "get" | "ports-pending";
  error?: { code: string; message: string };
  signedIn?: boolean;
  layout?: "rows" | "cards";
  /** The page's URL fragment, e.g. `#/get` for the storefront. */
  hash?: string;
  /** The plan's active machine limit, when the variant needs another than the sample plan's. */
  maxActive?: number;
  /** Sample forwards shown by Ports variants (gallery-only). */
  ports?: import("../pages/cloud/ops").PortForward[];
  /** Hold one port action after its control is activated to show the busy boundary. */
  pendingAction?: "forward" | "close" | "browser";
  machines: CloudMachine[];
  snapshots: CloudSnapshot[];
};

/** The CodeRouter page on an in-page cmuxPage host serving account and provider rows. */
export type CodeRouterPageVariant = VariantBase & {
  mode?: "normal" | "loading" | "error";
  error?: { code: string; message: string };
  signedIn?: boolean;
  providers: ProviderRow[];
};

/** The changelog page on an in-page cmuxPage host serving verified release notes. */
export type ChangelogPageVariant = VariantBase & {
  mode?: "normal" | "loading" | "error";
  error?: { code: string; message: string };
  current?: string;
  notes: ReleaseNotes[];
  /** The page route the host opens it on (`#/?from=<v>&to=<v>`, an update's span). */
  route?: string;
};

/** The icon picker page on an in-page cmuxPage host serving a picker session. */
export type IconPickerPageVariant = VariantBase & {
  session: PickerSession;
  /** Saved picker prefs (Frequently Used, skin tone, symbol rendering) the host loads. */
  prefs?: unknown;
  assetState?: "loading" | "error";
  query?: string;
  active?: number;
  mode?: "normal" | "empty";
};

/** The code editor page (src/pages/editor) on a cmuxPage host with a fixture file. */
export type EditorPageVariant = VariantBase & {
  path?: string;
  text?: string;
  hash?: string;
  size?: number;
  readOnly?: boolean;
  readOnlyReason?: ReadOnlyReason;
  recoveredText?: string;
  settings?: unknown;
  files?: Record<string, EditorFile>;
  recents?: Array<{ path: string; name?: string; openedAt: number }>;
  /** Leave the first host request pending so the page's loading state remains visible. */
  loading?: boolean;
  error?: "network" | "permission" | "not-found" | "not-file" | "too-large";
  conflict?: { hash: string; text?: string; deleted?: boolean };
};

/** The history page (src/pages/history) on a cmuxPage host with timeline entries. */
export type HistoryPageVariant = VariantBase & {
  entries?: HistoryEntry[];
  loading?: boolean;
  error?: "network" | "permission" | "not-found";
  query?: {
    text?: string;
    filter?: HistoryFilter;
    grouping?: HistoryGrouping;
    selectIndex?: number;
    menuIndex?: number;
  };
};

/** The keyboard shortcuts page (src/pages/keybindings) on a cmuxPage host with bindings. */
export type KeybindingsPageVariant = VariantBase & {
  bindings?: Binding[];
  loading?: boolean;
  error?: "network" | "unsupported" | "not-found";
  query?: { text?: string; conflictsOnly?: boolean; selectIndex?: number; editIndex?: number; record?: boolean };
};

/** A React component with props, for components no page host draws on its own. */
export type ComponentVariant<P> = VariantBase & {
  props: P;
  /** Gallery-only answers for the component's reply chip/preview host calls. */
  chipHost?: ChipHostFixture;
};

/**
 * A native (Swift) view's variant: the view builder registered under the same id in
 * CmuxNextGallery decodes `fixture`. `fixture` is a repo-relative path of a JSON file of the
 * Swift model (a shared fixture both hosts and the model's tests read), or inline JSON.
 */
export type NativeVariant = VariantBase & { fixture?: string | Record<string, unknown> };

type EntryBase<V> = {
  /** Unique, dotted lower kebab case (`area.name`); the same id in both hosts. */
  id: string;
  title: string;
  /** Sidebar group. */
  area: string;
  /** Flagged or unshipped surfaces live in the final Experimental sidebar group. */
  experimental?: boolean;
  /**
   * What the entry shows, for the coverage test: `<path under webviews/src>#<ExportName>` (or the
   * path alone for every export of a file) for web components, `page:<PageDescriptor id>` for
   * pages, `swift:<TypeName>` for native views.
   */
  covers: string[];
  /** Default stage height in px (else 520). */
  height?: number;
  /** The width presets in px, when the entry's own differ from the host's. */
  widths?: Partial<Record<WidthName, number>>;
  /** Elements that must not move while a play step acts on something else (play.ts). */
  anchors?: PlayTarget[];
  /** Looser play checks than the strict defaults, each with its written reason. */
  checks?: PlayChecks;
  /** Opt into viewer choices tied to a tracker item. */
  pick?: { beadId: string; recommendedId: string };
  /** Arms of an experiment to compare side by side (view `compare`). */
  experiment?: GalleryExperiment;
  /** Values the stage edits live (a curve editor each; experiments/tunable.ts). */
  tunables?: readonly Tunable[];
  /**
   * Switches the header shows (options.ts): each sets one prop of a component entry's variant
   * (a layout, a platform frame, a count). The URL keeps only the values the viewer changed.
   */
  options?: readonly GalleryOption[];
  /** Extra words the gallery's filter matches (synonyms a person may type). */
  keywords?: readonly string[];
  variants: Record<string, V>;
};

export type AgentPaneEntry = EntryBase<AgentPaneVariant> & { host: "agent-pane" };
export type MarkdownPageEntry = EntryBase<MarkdownPageVariant> & { host: "markdown-page" };
export type DiffPageEntry = EntryBase<DiffPageVariant> & { host: "diff-page" };
export type AppsPageEntry = EntryBase<AppsPageVariant> & { host: "apps-page" };
export type CloudPageEntry = EntryBase<CloudPageVariant> & { host: "cloud-page" };
export type CodeRouterPageEntry = EntryBase<CodeRouterPageVariant> & { host: "coderouter-page" };
export type ChangelogPageEntry = EntryBase<ChangelogPageVariant> & { host: "changelog-page" };
export type IconPickerPageEntry = EntryBase<IconPickerPageVariant> & { host: "icon-picker-page" };
export type EditorPageEntry = EntryBase<EditorPageVariant> & { host: "editor-page" };
export type HistoryPageEntry = EntryBase<HistoryPageVariant> & { host: "history-page" };
export type KeybindingsPageEntry = EntryBase<KeybindingsPageVariant> & { host: "keybindings-page" };
export type ComponentEntry<P = Record<string, unknown>> = EntryBase<ComponentVariant<P>> & {
  host: "component";
  /** The component; loaded only in a stage frame. */
  load: () => Promise<ComponentType<P>>;
  /** Stylesheets the component needs, loaded before it. */
  styles?: () => Promise<unknown>;
  /**
   * An agent pane component: the host loads the pane's strings and stylesheet and applies its
   * theme (AgentPaneTheme through applyAgentTheme), as the pane has them around it.
   */
  pane?: boolean;
};
/** Drawn only by the native gallery; the web gallery lists it and shows its native snapshots. */
export type NativeEntry = EntryBase<NativeVariant> & { host: "native" };

export type SettingsPageEntry = EntryBase<SettingsPageVariant> & { host: "settings-page" };
export type PasswordsPageEntry = EntryBase<PasswordsPageVariant> & { host: "passwords-page" };
export type GalleryEntry =
  | AgentPaneEntry
  | MarkdownPageEntry
  | DiffPageEntry
  | AppsPageEntry
  | CloudPageEntry
  | CodeRouterPageEntry
  | ChangelogPageEntry
  | IconPickerPageEntry
  | EditorPageEntry
  | HistoryPageEntry
  | KeybindingsPageEntry
  | SettingsPageEntry
  | PasswordsPageEntry
  | ComponentEntry<any>
  | NativeEntry;
export type HostKind = GalleryEntry["host"];

export {
  settingsPageEntry,
  passwordsPageEntry,
  agentPaneEntry,
  markdownPageEntry,
  diffPageEntry,
  appsPageEntry,
  cloudPageEntry,
  codeRouterPageEntry,
  changelogPageEntry,
  iconPickerPageEntry,
  editorPageEntry,
  historyPageEntry,
  keybindingsPageEntry,
  componentEntry,
  nativeEntry,
} from "./entry";

export const DEFAULT_STAGE_HEIGHT = 520;

export function stageHeight(entry: GalleryEntry, variant: string): number {
  return entry.variants[variant]?.height ?? entry.height ?? DEFAULT_STAGE_HEIGHT;
}

export const ENTRY_ID = /^[a-z0-9-]+(\.[a-z0-9-]+)+$/;
export const VARIANT_NAME = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/** Checks a set of entries: unique ids, at least one variant each, names the URL can carry. */
export function validateEntries(entries: readonly GalleryEntry[]): string[] {
  const problems: string[] = [];
  const seen = new Set<string>();
  for (const entry of entries) {
    if (!ENTRY_ID.test(entry.id)) problems.push(`${entry.id}: the id must be dotted lower kebab case`);
    if (seen.has(entry.id)) problems.push(`${entry.id}: duplicate id`);
    seen.add(entry.id);
    const variants = Object.keys(entry.variants);
    if (variants.length === 0) problems.push(`${entry.id}: no variants`);
    for (const name of variants)
      if (!VARIANT_NAME.test(name)) problems.push(`${entry.id}#${name}: variant names are lower kebab case`);
    if (entry.pick) {
      if (!/^cx-[a-z0-9.]+$/.test(entry.pick.beadId)) problems.push(`${entry.id}: invalid pick bead id`);
      if (!variants.includes(entry.pick.recommendedId)) problems.push(`${entry.id}: recommended variant is missing`);
    }
    if (entry.covers.length === 0) problems.push(`${entry.id}: covers nothing`);
    if (entry.experiment) {
      const { definition, script, measurements } = entry.experiment;
      for (const problem of validateExperiments([definition])) problems.push(`${entry.id}: ${problem}`);
      if (script.length === 0) problems.push(`${entry.id}: the experiment script has no steps`);
      if (new Set(script.map((step) => step.name)).size !== script.length)
        problems.push(`${entry.id}: experiment step names repeat`);
      for (const arm of Object.keys(measurements ?? {}))
        if (!armIds(definition).includes(arm)) problems.push(`${entry.id}: a measurement names no arm ${arm}`);
    }
    for (const problem of validateTunables(entry.tunables ?? [])) problems.push(`${entry.id}: ${problem}`);
    for (const problem of validateOptions(entry.options ?? [])) problems.push(`${entry.id}: ${problem}`);
    for (const option of entry.options ?? [])
      for (const [name, variant] of Object.entries(entry.variants)) {
        const value = (variant as { props?: Record<string, unknown> }).props?.[option.id];
        if (value === undefined) continue;
        const encoded =
          option.kind === "toggle" ? (value === true ? "on" : value === false ? "off" : undefined) : String(value);
        if (encoded === undefined || !optionAccepts(option, encoded))
          problems.push(`${entry.id}#${name}: prop ${option.id} is not one of the option's values`);
      }
    if (entry.options?.length && entry.host !== "component")
      problems.push(`${entry.id}: options set props, so only component entries take them`);
    for (const problem of checkReasons(entry.checks)) problems.push(`${entry.id}: ${problem}`);
    for (const [name, variant] of Object.entries(entry.variants))
      for (const problem of checkReasons(variant.checks)) problems.push(`${entry.id}#${name}: ${problem}`);
  }
  return problems;
}
