// l10n-allow-file: public-safe gallery, test and browser development fixtures, not shipped UI.
// Fixture states of the onboarding page, one per step and state the host can send (ops.ts). The
// browsers and profiles are made up; icons are small drawn SVGs standing in for the host's PNGs.
import type {
  AgentRow,
  AgentToolsRow,
  ComputerUseState,
  HostImage,
  ImportCounts,
  ImportRow,
  ImportState,
  OnboardingFooter,
  OnboardingState,
} from "./ops";

function svg(body: string): string {
  return `data:image/svg+xml;utf8,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">${body}</svg>`)}`;
}

/** A round app icon with a letter, as a browser's icon. */
function appIcon(fill: string, letter: string): HostImage {
  return {
    template: false,
    src: svg(
      `<circle cx="16" cy="16" r="15" fill="${fill}"/><text x="16" y="21" font-family="-apple-system,sans-serif" font-size="15" font-weight="600" text-anchor="middle" fill="white">${letter}</text>`,
    ),
  };
}

/** A profile picture: a colored disc. */
function avatar(fill: string): HostImage {
  return { template: false, src: svg(`<circle cx="16" cy="16" r="16" fill="${fill}"/>`) };
}

/** A single-color agent mark the page tints. */
const sparkMark: HostImage = {
  template: true,
  src: svg(`<path d="M16 2l3.5 10.5L30 16l-10.5 3.5L16 30l-3.5-10.5L2 16l10.5-3.5z" fill="black"/>`),
};
const ringMark: HostImage = {
  template: true,
  src: svg(`<circle cx="16" cy="16" r="11" fill="none" stroke="black" stroke-width="4"/>`),
};

/** A grant's icon: a rounded square, as System Settings' pane icons. */
function paneIcon(fill: string, glyph: string): HostImage {
  return {
    template: false,
    src: svg(`<rect x="1" y="1" width="30" height="30" rx="7" fill="${fill}"/><path d="${glyph}" fill="white"/>`),
  };
}
const accessibilityIcon = paneIcon(
  "#5f6368",
  "M16 6a2.5 2.5 0 1 1 0 5 2.5 2.5 0 0 1 0-5zM8 12h16v2.5h-5.5V26h-2.5v-6h-0v6h-2.5V14.5H8z",
);
const screenIcon = paneIcon("#6e5ae6", "M7 9h18v12H7zM13 23h6v2h-6z");
const helperIcon: HostImage = {
  template: false,
  src: svg(
    `<rect x="1" y="1" width="30" height="30" rx="7" fill="#2b2b30"/><path d="M9 11l7 5-7 5" stroke="white" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/><path d="M17 22h7" stroke="white" stroke-width="2.5" stroke-linecap="round"/>`,
  ),
};

const footer = (over: Partial<OnboardingFooter> = {}): OnboardingFooter => ({
  primary: "continue",
  primaryEnabled: true,
  skip: "skip",
  showsBack: false,
  backEnabled: true,
  progress: null,
  ...over,
});

// MARK: Agents

const AGENTS: AgentRow[] = [
  { id: "claude", name: "Claude Code", auth: "signedIn", offersSignIn: false, icon: sparkMark },
  { id: "codex", name: "Codex", auth: "signedOut", offersSignIn: true, icon: ringMark },
  { id: "gemini", name: "Gemini CLI", auth: "expired", offersSignIn: true, icon: null },
  { id: "opencode", name: "OpenCode", auth: "unknown", offersSignIn: true, icon: null },
];

export type AgentsFixture = "checking" | "mixed" | "signingIn" | "failed" | "none" | "install";

export function agentsState(kind: AgentsFixture = "mixed"): OnboardingState {
  const rows =
    kind === "checking" || kind === "none"
      ? []
      : kind === "install"
        ? [
            AGENTS[0]!,
            {
              id: "codex",
              name: "Codex",
              auth: "unknown",
              offersSignIn: true,
              icon: ringMark,
              install: { state: "idle", vendorURL: "https://example.com/install" },
            } satisfies AgentRow,
            {
              id: "gemini",
              name: "Gemini CLI",
              auth: "unknown",
              offersSignIn: true,
              icon: null,
              install: { state: "installing", step: "download" },
            } satisfies AgentRow,
            {
              id: "opencode",
              name: "OpenCode",
              auth: "unknown",
              offersSignIn: true,
              icon: null,
              install: {
                state: "failed",
                message: "npm exited with status 1",
                vendorURL: "https://example.com/install",
              },
            } satisfies AgentRow,
          ]
        : AGENTS;
  return {
    step: "agents",
    footer: footer(),
    agents: {
      rows,
      loaded: kind !== "checking",
      signingIn: kind === "signingIn" ? "codex" : null,
      signInFailed: kind === "failed",
    },
    importer: null,
    computerUse: null,
  };
}

// MARK: Import

const zero: ImportCounts = { bookmarks: 0, history: 0, openTabs: 0, cookies: 0, passwords: 0, searchEngines: 0 };

const PROFILES: Extract<ImportRow, { kind: "profile" }>[] = [
  {
    kind: "profile",
    id: "northwind/Default",
    browserName: "Northwind",
    profileName: "Personal",
    icon: appIcon("#e8710a", "N"),
    avatar: avatar("#34a853"),
    needsFullDiskAccess: false,
    checked: true,
    state: { kind: "idle" },
    target: null,
  },
  {
    kind: "profile",
    id: "northwind/Profile 1",
    browserName: "Northwind",
    profileName: "Work",
    icon: appIcon("#e8710a", "N"),
    avatar: avatar("#a142f4"),
    needsFullDiskAccess: false,
    checked: false,
    state: { kind: "idle" },
    target: "work",
  },
  {
    kind: "profile",
    id: "meridian/Default",
    browserName: "Meridian",
    profileName: null,
    icon: appIcon("#0f9d9a", "M"),
    avatar: null,
    needsFullDiskAccess: true,
    checked: false,
    state: { kind: "idle" },
    target: null,
  },
];

const AWAITING: Extract<ImportRow, { kind: "awaiting" }> = {
  kind: "awaiting",
  browser: "orbit",
  browserName: "Orbit",
  icon: appIcon("#7b61ff", "O"),
};

const importer = (over: Partial<ImportState> = {}): ImportState => ({
  phase: "ready",
  failure: null,
  rows: [...PROFILES, AWAITING],
  editable: true,
  targetChoices: [
    { id: "default", name: "Default" },
    { id: "work", name: "Work" },
  ],
  targetFixed: false,
  kindChoices: ["bookmarks", "history", "openTabs", "cookies", "searchEngines", "passwords"],
  kinds: ["bookmarks", "history", "cookies"],
  keepsHistoryInSync: true,
  offersPasswordCSV: false,
  summary: null,
  access: null,
  consent: null,
  ...over,
});

export type ImportFixture =
  | "idle"
  | "crowded"
  | "detecting"
  | "ready"
  | "noBrowsers"
  | "importing"
  | "finished"
  | "failed"
  | "access"
  | "accessRefused"
  | "consent"
  | "consentFirefox"
  | "denied";

function importStateFor(kind: ImportFixture): { importer: ImportState; footer: OnboardingFooter } {
  switch (kind) {
    case "idle":
      return { importer: importer({ phase: "idle", rows: [] }), footer: footer({ primary: "findBrowsers" }) };
    case "detecting":
      return {
        importer: importer({ phase: "detecting", rows: [], editable: false }),
        footer: footer({ primary: "detecting", primaryEnabled: false }),
      };
    case "ready":
      return { importer: importer(), footer: footer({ primary: "import" }) };
    case "crowded":
      // The worst list: a Full Disk Access row first, a long profile name, more rows than fit, one
      // kind checked, and the passwords CSV offered (the footer's menu).
      return {
        importer: importer({
          rows: [
            { ...PROFILES[2]!, id: "harbor/Default", browserName: "Harbor", icon: appIcon("#1a73e8", "H") },
            { ...PROFILES[0]!, profileName: null, avatar: null },
            {
              ...PROFILES[1]!,
              checked: true,
              target: null,
              profileName: "Client Work — Northwind Traders Quarterly Planning",
            },
            {
              ...PROFILES[1]!,
              id: "lumen/Default",
              browserName: "Lumen Classic",
              profileName: null,
              avatar: null,
              checked: true,
              target: null,
              icon: appIcon("#5f6368", "L"),
            },
            {
              ...PROFILES[0]!,
              id: "kestrel/Default",
              browserName: "Kestrel",
              profileName: "School",
              icon: appIcon("#d93025", "K"),
            },
            AWAITING,
          ],
          kindChoices: ["bookmarks", "history", "openTabs", "cookies", "searchEngines", "passwords"],
          kinds: ["cookies"],
          offersPasswordCSV: true,
        }),
        footer: footer({ primary: "import" }),
      };
    case "noBrowsers":
      return { importer: importer({ rows: [] }), footer: footer({ primary: "import", primaryEnabled: false }) };
    case "importing":
      return {
        importer: importer({
          phase: "importing",
          editable: false,
          rows: [
            {
              ...PROFILES[0]!,
              state: { kind: "done", counts: { ...zero, bookmarks: 204, history: 8311, searchEngines: 1 } },
            },
            {
              ...PROFILES[1]!,
              checked: true,
              state: { kind: "importing", dataKind: "history", counts: { ...zero, bookmarks: 37 } },
            },
            { ...PROFILES[2]!, needsFullDiskAccess: false, checked: true, state: { kind: "waiting" } },
          ],
        }),
        footer: footer({ primary: "import", primaryEnabled: false }),
      };
    case "finished":
      return {
        importer: importer({
          phase: "finished",
          editable: false,
          rows: [
            {
              ...PROFILES[0]!,
              state: { kind: "done", counts: { ...zero, bookmarks: 204, history: 8311, passwords: 41 } },
            },
            {
              ...PROFILES[1]!,
              checked: true,
              state: { kind: "failed", reason: "The profile’s history database is locked by the browser." },
            },
          ],
          summary: {
            counts: { ...zero, bookmarks: 204, history: 8311, passwords: 41, searchEngines: 1 },
            passwordsSkipped: 9,
            passwordsConflicts: 2,
            passwordsNotRead: false,
            someFailed: true,
          },
        }),
        footer: footer({ primary: "done" }),
      };
    case "failed":
      return {
        importer: importer({ phase: "failed", failure: "The import stopped: the disk is full.", editable: true }),
        footer: footer({ primary: "import" }),
      };
    case "access":
    case "accessRefused":
      return {
        importer: importer({
          phase: "explainingAccess",
          access: {
            browserName: "Orbit",
            folder: "~/Library/Application Support/Orbit",
            requesting: false,
            notGranted: kind === "accessRefused",
          },
        }),
        footer: footer({ primary: "continue", showsBack: true, progress: 0.5 }),
      };
    case "consent":
    case "consentFirefox":
    case "denied":
      return {
        importer: importer({
          phase: "confirmingPasswords",
          kinds: ["bookmarks", "history", "passwords"],
          offersPasswordCSV: kind === "denied",
          consent: {
            keychainItems: kind === "consentFirefox" ? [] : ["Northwind Safe Storage", "Meridian Safe Storage"],
            includesFirefox: kind === "consentFirefox",
            authorizing: false,
            denied: kind === "denied",
          },
        }),
        footer: footer({ primary: "beginImporting", skip: "skipImporting", showsBack: true, progress: 0.75 }),
      };
  }
}

export function importState(kind: ImportFixture = "ready"): OnboardingState {
  const { importer: state, footer: bar } = importStateFor(kind);
  return { step: "importData", footer: bar, agents: null, importer: state, computerUse: null };
}

// MARK: Computer Use

export type ComputerUseFixture = "fresh" | "oneGranted" | "allGranted" | "helperFailed" | "off" | "unavailable";

export function computerUseState(kind: ComputerUseFixture = "fresh"): OnboardingState {
  const rows: ComputerUseState["rows"] = [
    {
      pane: "accessibility",
      control:
        kind === "oneGranted" || kind === "allGranted" ? "done" : kind === "helperFailed" ? "hidden" : "allowPrimary",
      icon: accessibilityIcon,
    },
    {
      pane: "screenRecording",
      control:
        kind === "allGranted"
          ? "done"
          : kind === "helperFailed"
            ? "hidden"
            : kind === "oneGranted"
              ? "allowPrimary"
              : "allow",
      icon: screenIcon,
    },
  ];
  return {
    step: "computerUse",
    footer: footer({ primary: "done", primaryEnabled: kind === "allGranted" }),
    agents: null,
    importer: null,
    computerUse: {
      helperIcon: kind === "unavailable" ? null : helperIcon,
      rows,
      allGranted: kind === "allGranted",
      note:
        kind === "helperFailed"
          ? "helperFailed"
          : kind === "off"
            ? "off"
            : kind === "unavailable"
              ? "unavailable"
              : null,
      showsRestart: kind === "helperFailed",
      comebacks: kind === "oneGranted" ? 1 : 0,
    },
  };
}

// MARK: cmux Tools

export type AgentToolsFixture =
  | "checking"
  | "none"
  | "found"
  | "oneAdded"
  | "conflict"
  | "adding"
  | "added"
  | "declined"
  | "failed";

const TOOLS_AGENTS: AgentToolsRow[] = [
  { id: "claude", name: "Claude Code", state: "ready" },
  { id: "codex", name: "Codex", state: "ready" },
];

/** The cmux Tools step: before an answer (checking, none found, Claude Code and Codex found, one
 * already has cmux's tools, one keeps the person's own server named cmux), while Add runs, and each
 * answer (added, declined, some agent failed). */
export function agentToolsState(kind: AgentToolsFixture = "found"): OnboardingState {
  const answered = kind === "adding" || kind === "added" || kind === "declined" || kind === "failed";
  const rows: AgentToolsRow[] =
    kind === "checking" || kind === "none"
      ? []
      : kind === "oneAdded"
        ? [{ ...TOOLS_AGENTS[0]!, state: "added" }, TOOLS_AGENTS[1]!]
        : kind === "conflict"
          ? [TOOLS_AGENTS[0]!, { ...TOOLS_AGENTS[1]!, state: "conflict" }]
          : kind === "added"
            ? TOOLS_AGENTS.map((row) => ({ ...row, state: "added" as const }))
            : kind === "failed"
              ? [
                  { ...TOOLS_AGENTS[0]!, state: "added" },
                  { ...TOOLS_AGENTS[1]!, state: "failed" },
                ]
              : TOOLS_AGENTS;
  const done = kind === "added" || kind === "declined" || kind === "failed";
  return {
    step: "agentTools",
    footer: footer({
      primary: done ? "done" : "addTools",
      primaryEnabled: kind !== "adding",
      skip: answered ? "none" : "notNow",
    }),
    agents: null,
    importer: null,
    computerUse: null,
    agentTools: {
      rows,
      loaded: kind !== "checking",
      choice: kind === "declined" ? "off" : answered ? "on" : "ask",
      applying: kind === "adding",
      failed: kind === "failed",
      answered,
    },
  };
}
