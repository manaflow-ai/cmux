// The onboarding tool window's page protocol (cmux-page://cmux.onboarding/). The window is native
// (OnboardingWindowController: placement, the one glass backdrop, the close button); everything in
// it is this page. The host (CmuxNextOnboarding/Page/OnboardingPageProvider.swift) reads its
// OnboardingModel and answers `state`, pushes `changed` with the whole state after every model
// change, and runs each gesture on the model. Text the page shows is its own (Localizable.xcstrings
// next to this file); the host sends values, never sentences.
import type { AccountFamily, AccountRowWire, AccountRunParams, AccountRunReply } from "../shared/signIn/accountSignIn";

/** The one tool a window shows; it never changes for a window. */
/** `makeItYours` is a new person's one setup screen: how they work, the density and a background (cmux#48416). */
export type OnboardingStep = "agents" | "importData" | "computerUse" | "makeItYours";

/** What the footer's filled button says (OnboardingModel.primaryTitle). */
export type PrimaryAction = "continue" | "done" | "detecting" | "findBrowsers" | "import" | "beginImporting";

export interface OnboardingFooter {
  primary: PrimaryAction;
  /** False while browser detection runs (the button stays, disabled). */
  primaryEnabled: boolean;
  /** Skip, or Skip Importing on the Keychain explainer. */
  skip: "skip" | "skipImporting";
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

export type ImportDataKind =
  | "bookmarks"
  | "history"
  | "openTabs"
  | "extensions"
  | "cookies"
  | "searchEngines"
  | "passwords";

export interface ImportCounts {
  bookmarks: number;
  history: number;
  openTabs: number;
  /** Extensions read (store ones open their page in the profile, unpacked ones are copied). Older hosts leave it out. */
  extensions?: number;
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
  /** The person's Allow got the last grant on: the done view, and the window closes by itself. A
   * window opened with every grant already on keeps the rows and the ready line instead. */
  finished: boolean;
  /** Screen Recording turned on after the person allowed it here: the Screenshots row says macOS
   * asks once more (the private window picker "bypass" alert) the first time it captures. */
  confirmsCapture: boolean;
}

// MARK: Make cmux Yours

/** GUI-first (recommended: chats, browsers and terminals side by side, Cmd-T the New Tab page) or
 * terminal-first (Cmd-T opens a terminal). */
export type WorkStyle = "gui" | "terminal";
/** Where a new chat runs (`agentPane.newChatsIn`): this Mac (the default) or Cloud, which needs
 * nothing installed here. */
export type ChatsRunIn = "local" | "cloud";
/** A density offered: an `appearance.density` preset id (`cozy` is Settings' Default) and its name as
 * Settings shows it. Every density Settings has (cmux#49636). */
export interface MakeItYoursDensity {
  id: string;
  name: string;
}

/** The window's material under a background (`appearance.backgroundBlur`), as Settings offers it. */
export type MakeItYoursMaterial = "none" | "frosted" | "glass" | "glass-clear";

/** A background offered: Shuffle Paintings (`daily`, no name: the page names it) or a built-in work. */
export interface MakeItYoursBackground {
  id: string;
  /** The work's "Title — Artist"; empty for Shuffle Paintings. */
  name: string;
  preview: HostImage | null;
}

export interface MakeItYoursState {
  workStyle: WorkStyle;
  /** The density's preset id. */
  density: string;
  densities: MakeItYoursDensity[];
  /** The background's id; null: none. */
  background: string | null;
  backgrounds: MakeItYoursBackground[];
  /** The Opacity slider's value, 0 to 1: the one set, else what the window shows; null: unknown. */
  opacity: number | null;
  /** The person's settings set the Opacity (else it is the theme's). */
  opacitySet: boolean;
  /** `appearance.backgroundBlur`; null: unset (the theme's). */
  material: MakeItYoursMaterial | null;
  materials: MakeItYoursMaterial[];
  /** The intro walk's other settings now, by dotted path (walk.ts `WALK_PATHS`); absent: unset. */
  walk?: Record<string, string | number | boolean | null>;
  /** `experiments.introWalk`: the step is the intro walk's four screens; absent or false: today's one screen. */
  introWalk?: boolean;
  /** `experiments.setupShelf`: the step offers the setups shelf (setupShelf.ts); absent or false: no shelf. */
  setupShelf?: boolean;
  /** Where a new chat runs; an older host leaves it out, and the row is not drawn. */
  chatsRunIn?: ChatsRunIn;
  /** The backgrounds' previews were read. */
  loaded: boolean;
}

// MARK: Sign-in (logins done right)

/** Where one provider stands, as the daemon decides it: the page never re-derives installed or
 * ready, it only lays its own moments over this (installing from `agents`, a sign-in in progress
 * from the shared controller, shared/signIn/useAccountSignIn.ts). */
export interface SignInReadinessProvider {
  family: AccountFamily;
  state: "notInstalled" | "signInRequired" | "ready";
  /** Ready: the signed-in account. */
  account?: string;
  /** The provider's account label, when the daemon has one. */
  label?: string;
}

export interface SignInReadiness {
  providers: SignInReadinessProvider[];
}

// MARK: The page

export interface OnboardingState {
  step: OnboardingStep;
  footer: OnboardingFooter;
  agents: AgentsState | null;
  importer: ImportState | null;
  computerUse: ComputerUseState | null;
  /** Make cmux Yours' state; null on the other steps (absent from older hosts). */
  makeItYours?: MakeItYoursState | null;
  /** The in-place sign-in's accounts, the same rows Settings reads (`accounts.signInAccounts`);
   * absent from older hosts. */
  signInAccounts?: AccountRowWire[] | null;
  /** Each provider's readiness (GitHub, ChatGPT, Claude); absent from older hosts, and then the
   * agents step is as it was. */
  signInReadiness?: SignInReadiness | null;
}

/** Ops the page calls: [params, result]. Every gesture answers `{}` and the change comes back on
 * `cmux.onboarding.changed`. */
export interface OnboardingOps {
  "cmux.onboarding.state": [Record<string, never>, OnboardingState];
  /** The page gained focus: back from a Sign In, the host checks the sign-ins again. A read, so it
   * needs no click or key (the page engine keys its own child window, not the onboarding window). */
  "cmux.onboarding.focused": [Record<string, never>, unknown];
  /** The footer's filled button, or Return (cmux Tools: Turn On, then Done). */
  "cmux.onboarding.next": [Record<string, never>, unknown];
  /** Skip / Skip Importing / Not Now, or Escape (cmux Tools' Not Now answers no). */
  "cmux.onboarding.skip": [Record<string, never>, unknown];
  "cmux.onboarding.back": [Record<string, never>, unknown];
  "cmux.onboarding.agents.signIn": [{ id: string }, unknown];
  "cmux.onboarding.agents.install": [{ id: string }, unknown];
  /** One in-place sign-in gesture: the same actions (ACCOUNT_ACTIONS) and replies as
   * `cmux.settings.accounts.run`. Unlike the other gestures it answers with the daemon's reply. */
  "cmux.onboarding.accounts.run": [AccountRunParams, AccountRunReply];
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
  /** Make cmux Yours: each pick is written at once, so the window behind shows it. */
  "cmux.onboarding.makeItYours.workStyle": [{ value: WorkStyle }, unknown];
  "cmux.onboarding.makeItYours.density": [{ value: string }, unknown];
  "cmux.onboarding.makeItYours.chatsRunIn": [{ value: ChatsRunIn }, unknown];
  /** `id` null: no background. */
  "cmux.onboarding.makeItYours.background": [{ id: string | null }, unknown];
  /** The window's Opacity, 0 to 1 (Settings > Appearance's own row). */
  "cmux.onboarding.makeItYours.opacity": [{ value: number }, unknown];
  "cmux.onboarding.makeItYours.material": [{ value: MakeItYoursMaterial }, unknown];
  /** The intro walk (a look bundle, the trust and noise rows, Tidy): one publish; a null value removes. */
  "cmux.onboarding.makeItYours.walk": [
    { writes: { path: string; value: string | number | boolean | null }[] },
    unknown,
  ];
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
  accountsRun: "cmux.onboarding.accounts.run",
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
  workStyle: "cmux.onboarding.makeItYours.workStyle",
  density: "cmux.onboarding.makeItYours.density",
  chatsRunIn: "cmux.onboarding.makeItYours.chatsRunIn",
  background: "cmux.onboarding.makeItYours.background",
  opacity: "cmux.onboarding.makeItYours.opacity",
  material: "cmux.onboarding.makeItYours.material",
  walk: "cmux.onboarding.makeItYours.walk",
  changed: "cmux.onboarding.changed",
} as const satisfies Record<string, keyof OnboardingOps | keyof OnboardingEvents>;
