// The onboarding tool window's page protocol (cmux-page://cmux.onboarding/). The window is native
// (OnboardingWindowController: placement, the one glass backdrop, the close button); everything in
// it is this page. The host (CmuxNextOnboarding/Page/OnboardingPageProvider.swift) reads its
// OnboardingModel and answers `state`, pushes `changed` with the whole state after every model
// change, and runs each gesture on the model. Text the page shows is its own (Localizable.xcstrings
// next to this file); the host sends values, never sentences.

/** The one tool a window shows; it never changes for a window. */
/** `agentTools` asks whether cmux may add its MCP server (Computer Use included) to the person's coding agents. */
export type OnboardingStep = "agents" | "importData" | "computerUse" | "agentTools";

/** What the footer's filled button says (OnboardingModel.primaryTitle). */
export type PrimaryAction =
  | "continue"
  | "done"
  | "detecting"
  | "findBrowsers"
  | "import"
  | "beginImporting"
  | "addTools";

export interface OnboardingFooter {
  primary: PrimaryAction;
  /** False while browser detection runs (the button stays, disabled). */
  primaryEnabled: boolean;
  /** Skip, Skip Importing on the Keychain explainer, Not Now on cmux Tools until answered, or
   * `none` (cmux Tools answered: only Done is left). */
  skip: "skip" | "skipImporting" | "notNow" | "none";
  /** Back shows over the import explainers (the progress bar is up). */
  showsBack: boolean;
  backEnabled: boolean;
  /** The bar over the import explainers (0.5 access, 0.75 Keychain); null elsewhere. */
  progress: number | null;
}

/** An image the host drew: a `data:` PNG. `template`: a single-color mark the page tints with the
 * text color (agent marks, SF Symbols); otherwise drawn as is (app icons, profile pictures). */
export interface HostImage {
  src: string;
  template: boolean;
}

// MARK: Agents

export type AgentAuth = "signedIn" | "signedOut" | "expired" | "unknown";

/** The Install offer of an agent CLI not on this Mac that cmux can install (Claude Code, Codex); absent for an installed one. */
export interface AgentInstall {
  state: "idle" | "installing" | "failed" | "installed";
  /** While installing: the step acpmux reports (`download`, `verify`, ...). */
  step?: string | null;
  /** When failed: acpmux's own text. */
  message?: string | null;
  /** The vendor's install page, for a failure or a manual install. */
  vendorURL?: string | null;
}

export interface AgentRow {
  id: string;
  name: string;
  auth: AgentAuth;
  /** Sign In shows for every agent not known to be signed in. */
  offersSignIn: boolean;
  icon: HostImage | null;
  install?: AgentInstall;
}

export interface AgentsState {
  rows: AgentRow[];
  /** The first read answered (an empty list then says no agents were found). */
  loaded: boolean;
  /** The agent whose Sign In ran last; its terminal tab is where the login runs. */
  signingIn: string | null;
  signInFailed: boolean;
}

// MARK: Import from Browser

export type ImportDataKind = "bookmarks" | "history" | "openTabs" | "cookies" | "searchEngines" | "passwords";

export interface ImportCounts {
  bookmarks: number;
  history: number;
  openTabs: number;
  cookies: number;
  passwords: number;
  searchEngines: number;
}

/** One profile row's place in the current or last import (ImportStepModel.RowState). */
export type ImportRowState =
  | { kind: "idle" }
  | { kind: "waiting" }
  | { kind: "importing"; dataKind: ImportDataKind | null; counts: ImportCounts }
  | { kind: "done"; counts: ImportCounts }
  | { kind: "failed"; reason: string };

export type ImportRow =
  | {
      kind: "profile";
      /** BrowserSourceProfile.id */
      id: string;
      browserName: string;
      /** The profile's name under the browser's; null for Safari and one-profile browsers. */
      profileName: string | null;
      icon: HostImage | null;
      avatar: HostImage | null;
      /** macOS blocks it until Full Disk Access: Open System Settings instead of a checkbox. */
      needsFullDiskAccess: boolean;
      checked: boolean;
      state: ImportRowState;
      /** The cmux profile it goes into; null makes its own matching profile. */
      target: string | null;
    }
  | {
      kind: "awaiting";
      /** ImportBrowser raw value: the `import.askAccess` argument. */
      browser: string;
      browserName: string;
      icon: HostImage | null;
    };

export type ImportPhase =
  | "idle"
  | "detecting"
  | "ready"
  | "explainingAccess"
  | "confirmingPasswords"
  | "importing"
  | "finished"
  | "cancelled"
  | "failed";

export interface ImportSummaryState {
  counts: ImportCounts;
  /** Passwords not imported other than conflicts, summed over the batches. */
  passwordsSkipped: number;
  /** Already saved with a different password: the saved one was kept. */
  passwordsConflicts: number;
  /** A batch could not read its passwords. */
  passwordsNotRead: boolean;
  /** Some profiles failed (the rest imported). */
  someFailed: boolean;
}

export interface ImportState {
  phase: ImportPhase;
  /** The failure's text when `phase` is `failed`. */
  failure: string | null;
  /** Profiles, then browsers awaiting a folder grant, in detection order (Edge first). */
  rows: ImportRow[];
  /** Checkboxes, the target menus and Keep in Sync take clicks. */
  editable: boolean;
  /** The cmux profiles a row can go into; empty hides the menus. */
  targetChoices: { id: string; name: string }[];
  /** A caller fixed the target (the cookie card): no row menus. */
  targetFixed: boolean;
  kindChoices: ImportDataKind[];
  kinds: ImportDataKind[];
  keepsHistoryInSync: boolean;
  offersPasswordCSV: boolean;
  summary: ImportSummaryState | null;
  /** The folder grant explainer, while it shows. */
  access: {
    browserName: string;
    /** `~/Library/Application Support/Google/Chrome` */
    folder: string;
    requesting: boolean;
    notGranted: boolean;
  } | null;
  /** The Keychain explainer, while it shows. */
  consent: {
    /** "Microsoft Edge Safe Storage", one per browser, in list order. */
    keychainItems: string[];
    includesFirefox: boolean;
    authorizing: boolean;
    denied: boolean;
  } | null;
}

// MARK: Computer Use

export type ComputerUsePane = "accessibility" | "screenRecording";

export interface ComputerUseRow {
  pane: ComputerUsePane;
  /** The trailing control: Done with a check, Allow (filled when `allowPrimary`), or nothing. */
  control: "done" | "allow" | "allowPrimary" | "hidden";
  icon: HostImage | null;
}

export interface ComputerUseState {
  /** The helper app's icon (cmux's own until the helper is found on disk). */
  helperIcon: HostImage | null;
  rows: ComputerUseRow[];
  allGranted: boolean;
  /** The footer's one line on why Allow cannot help, if it cannot. */
  note: "helperFailed" | "helperVersionMismatch" | "unavailable" | "off" | null;
  /** Restart shows (the helper did not answer). */
  showsRestart: boolean;
  /** A grant landed or the drag panel's back button closed it: the count goes up, and the page
   * moves focus back to its primary control. */
  comebacks: number;
}

// MARK: cmux Tools

/** One coding agent and whether its own config gives it cmux's tools (`cmux setup mcp`):
 * `ready` (none yet), `added`, `conflict` (another server named cmux is the person's) or `failed`. */
export interface AgentToolsRow {
  id: string;
  /** The product's own name ("Claude Code"): never translated. */
  name: string;
  state: "ready" | "added" | "conflict" | "failed";
}

export interface AgentToolsState {
  /** The coding agents found on this Mac; the page draws each one's mark from its id. */
  rows: AgentToolsRow[];
  /** The first read answered (an empty list then says none was found). */
  loaded: boolean;
  /** `agents.cmuxMcp` now: `ask` until the person answers. */
  choice: "ask" | "on" | "off";
  /** Add to My Agents runs `cmux setup mcp`. */
  applying: boolean;
  /** The run could not set up every agent. */
  failed: boolean;
  /** The person answered in this window. */
  answered: boolean;
}

// MARK: The page

export interface OnboardingState {
  step: OnboardingStep;
  footer: OnboardingFooter;
  agents: AgentsState | null;
  importer: ImportState | null;
  computerUse: ComputerUseState | null;
  /** The cmux Tools step's state; null on the other steps (absent from older hosts). */
  agentTools?: AgentToolsState | null;
}

/** Ops the page calls: [params, result]. Every gesture answers `{}` and the change comes back on
 * `cmux.onboarding.changed`. */
export interface OnboardingOps {
  "cmux.onboarding.state": [Record<string, never>, OnboardingState];
  /** The page gained focus: back from a Sign In, the host checks the sign-ins again. A read, so it
   * needs no click or key (the page engine keys its own child window, not the onboarding window). */
  "cmux.onboarding.focused": [Record<string, never>, unknown];
  /** The footer's filled button, or Return (cmux Tools: Add to My Agents, then Done). */
  "cmux.onboarding.next": [Record<string, never>, unknown];
  /** Skip / Skip Importing / Not Now, or Escape (cmux Tools' Not Now answers no). */
  "cmux.onboarding.skip": [Record<string, never>, unknown];
  "cmux.onboarding.back": [Record<string, never>, unknown];
  "cmux.onboarding.agents.signIn": [{ id: string }, unknown];
  "cmux.onboarding.agents.install": [{ id: string }, unknown];
  "cmux.onboarding.import.toggleProfile": [{ id: string }, unknown];
  "cmux.onboarding.import.toggleKind": [{ kind: ImportDataKind }, unknown];
  "cmux.onboarding.import.toggleKeepInSync": [Record<string, never>, unknown];
  /** `target` null: the row's own new matching profile. */
  "cmux.onboarding.import.setTarget": [{ id: string; target: string | null }, unknown];
  "cmux.onboarding.import.askAccess": [{ browser: string }, unknown];
  "cmux.onboarding.import.openFullDiskAccess": [Record<string, never>, unknown];
  "cmux.onboarding.import.fromFiles": [Record<string, never>, unknown];
  "cmux.onboarding.import.passwordsCSV": [Record<string, never>, unknown];
  "cmux.onboarding.import.skipPasswords": [Record<string, never>, unknown];
  "cmux.onboarding.computerUse.allow": [{ pane: ComputerUsePane }, unknown];
  "cmux.onboarding.computerUse.restart": [Record<string, never>, unknown];
}

export interface OnboardingEvents {
  "cmux.onboarding.changed": OnboardingState;
}

export const OPS = {
  state: "cmux.onboarding.state",
  focused: "cmux.onboarding.focused",
  next: "cmux.onboarding.next",
  skip: "cmux.onboarding.skip",
  back: "cmux.onboarding.back",
  signIn: "cmux.onboarding.agents.signIn",
  install: "cmux.onboarding.agents.install",
  toggleProfile: "cmux.onboarding.import.toggleProfile",
  toggleKind: "cmux.onboarding.import.toggleKind",
  toggleKeepInSync: "cmux.onboarding.import.toggleKeepInSync",
  setTarget: "cmux.onboarding.import.setTarget",
  askAccess: "cmux.onboarding.import.askAccess",
  openFullDiskAccess: "cmux.onboarding.import.openFullDiskAccess",
  fromFiles: "cmux.onboarding.import.fromFiles",
  passwordsCSV: "cmux.onboarding.import.passwordsCSV",
  skipPasswords: "cmux.onboarding.import.skipPasswords",
  allow: "cmux.onboarding.computerUse.allow",
  restart: "cmux.onboarding.computerUse.restart",
  changed: "cmux.onboarding.changed",
} as const satisfies Record<string, keyof OnboardingOps | keyof OnboardingEvents>;
