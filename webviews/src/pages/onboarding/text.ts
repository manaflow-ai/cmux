// The onboarding page's words and keys, as pure functions over the host's state (ops.ts) and the
// page's string table, so tests read them without rendering. Every sentence is a catalog string
// (Localizable.xcstrings, the Swift steps' keys and translations); the host sends values only.
import type { Strings } from "../shared/i18n";
import type {
  AgentAuth,
  AgentRow,
  AgentToolsRow,
  AgentToolsState,
  ComputerUseState,
  ImportCounts,
  ImportDataKind,
  ImportRow,
  ImportState,
  OnboardingFooter,
  OnboardingState,
  OnboardingStep,
  PrimaryAction,
} from "./ops";

const KIND_KEYS: Record<ImportDataKind, string> = {
  bookmarks: "onboarding.kind.bookmarks",
  history: "onboarding.kind.history",
  openTabs: "onboarding.kind.openTabs",
  cookies: "onboarding.kind.signIns",
  searchEngines: "onboarding.kind.searchEngine",
  passwords: "onboarding.kind.passwords",
};

/** A kind's checkbox label (Sign-ins for cookies). */
export function kindLabel(strings: Strings, kind: ImportDataKind): string {
  return strings.t(KIND_KEYS[kind]);
}

/** A count in the page's language ("8,311"). */
export function formatCount(strings: Strings, value: number): string {
  try {
    return new Intl.NumberFormat(strings.language).format(value);
  } catch {
    return new Intl.NumberFormat("en").format(value);
  }
}

/** The counted kinds, in the order the line names them; the search engine follows without a count. */
const COUNTED: readonly (keyof ImportCounts & ImportDataKind)[] = [
  "bookmarks",
  "history",
  "openTabs",
  "cookies",
  "passwords",
];

/** "Bookmarks 204 · History 8,311 · Search Engine": what came over, empty when nothing did. */
export function countsLine(strings: Strings, counts: ImportCounts | null | undefined): string {
  if (counts == null) return "";
  const parts = COUNTED.filter((kind) => (counts[kind] ?? 0) > 0).map(
    (kind) => `${kindLabel(strings, kind)} ${formatCount(strings, counts[kind])}`,
  );
  // One default engine per profile: its name alone says it came over.
  if ((counts.searchEngines ?? 0) > 0) parts.push(kindLabel(strings, "searchEngines"));
  return parts.join(" · ");
}

/** Quotation marks per language (CLDR's quotationStart and quotationEnd, as Foundation's Locale). */
const QUOTES: Record<string, readonly [string, string]> = {
  ar: ["”", "“"],
  bs: ["„", "“"],
  de: ["„", "“"],
  es: ["«", "»"],
  fr: ["«", "»"],
  it: ["«", "»"],
  ja: ["「", "」"],
  nb: ["«", "»"],
  pl: ["„", "”"],
  ru: ["«", "»"],
  uk: ["«", "»"],
  "zh-Hant": ["「", "」"],
};

export function quotationMarks(language: string): readonly [string, string] {
  return QUOTES[language] ?? QUOTES[language.split("-")[0] ?? ""] ?? ["“", "”"];
}

/** “Microsoft Edge Safe Storage” and “Google Chrome Safe Storage”, in the language's quotation
 * marks and list style. */
export function quotedList(items: readonly string[], language: string): string {
  const [open, close] = quotationMarks(language);
  const quoted = items.map((item) => `${open}${item}${close}`);
  try {
    return new Intl.ListFormat(language, { type: "conjunction" }).format(quoted);
  } catch {
    return new Intl.ListFormat("en", { type: "conjunction" }).format(quoted);
  }
}

/** The Keychain explainer's one line: the items macOS asks about; Firefox alone asks for none. */
export function keychainLine(strings: Strings, keychainItems: readonly string[], includesFirefox: boolean): string {
  if (keychainItems.length === 0) return strings.t("onboarding.passwords.firefoxOnly");
  const line = strings.format("onboarding.unlock.line", quotedList(keychainItems, strings.language));
  return includesFirefox ? `${line} ${strings.t("onboarding.passwords.firefoxPrimary")}` : line;
}

const PRIMARY_KEYS: Record<PrimaryAction, string> = {
  continue: "onboarding.button.continue",
  done: "onboarding.button.done",
  detecting: "onboarding.import.detecting",
  findBrowsers: "onboarding.import.findBrowsers",
  import: "onboarding.button.import",
  beginImporting: "onboarding.button.beginImporting",
  addTools: "onboarding.agentTools.add",
};

/** The footer's filled button. */
export function primaryLabel(strings: Strings, primary: PrimaryAction): string {
  return strings.t(PRIMARY_KEYS[primary] ?? PRIMARY_KEYS.continue);
}

/** The labels the filled button can take on a step, so its width is the widest one's and never
 * moves as the label changes (Agents only says Continue; Import walks through the rest). */
export function primaryLabels(strings: Strings, step: OnboardingStep): string[] {
  const actions: PrimaryAction[] =
    step === "importData"
      ? ["findBrowsers", "detecting", "import", "beginImporting", "continue", "done"]
      : step === "agentTools"
        ? ["addTools", "done"]
        : ["continue"];
  return actions.map((action) => strings.t(PRIMARY_KEYS[action]));
}

export function skipLabel(strings: Strings, skip: OnboardingFooter["skip"]): string {
  if (skip === "notNow") return strings.t("onboarding.computerUse.notNow");
  return strings.t(skip === "skipImporting" ? "onboarding.button.skipImporting" : "onboarding.button.skip");
}

/** Skip's labels on a step: Import also says Skip Importing over the Keychain explainer. */
export function skipLabels(strings: Strings, step: OnboardingStep): string[] {
  if (step === "agentTools") return [strings.t("onboarding.computerUse.notNow")];
  return step === "importData"
    ? [strings.t("onboarding.button.skip"), strings.t("onboarding.button.skipImporting")]
    : [strings.t("onboarding.button.skip")];
}

const TOOLS_STATE_KEYS: Record<AgentToolsRow["state"], string> = {
  ready: "onboarding.agentTools.state.ready",
  added: "onboarding.agentTools.state.added",
  conflict: "onboarding.agentTools.state.conflict",
  failed: "onboarding.agentTools.state.failed",
};

/** The line under a coding agent's name: found, has cmux's tools, keeps the person's own server
 * named cmux, or could not be read; after Not Now a found agent says Not added. */
export function agentToolsDetail(strings: Strings, row: AgentToolsRow, tools: AgentToolsState): string {
  if (row.state === "ready" && tools.choice === "off") return strings.t("onboarding.agentTools.state.notAdded");
  return strings.t(TOOLS_STATE_KEYS[row.state] ?? TOOLS_STATE_KEYS.ready);
}

/** The line under the cmux Tools list, or null for none: Checking…, none found, Adding…, what the
 * answer did, or that some agent could not be set up. */
export function agentToolsStatus(strings: Strings, tools: AgentToolsState | null | undefined): string | null {
  if (tools == null || !tools.loaded) return strings.t("onboarding.agents.checking");
  if (tools.applying) return strings.t("onboarding.agentTools.adding");
  if (tools.answered && tools.failed) return strings.t("onboarding.agentTools.failed");
  if (tools.answered && tools.choice === "on") return strings.t("onboarding.agentTools.added");
  if (tools.answered && tools.choice === "off") return strings.t("onboarding.agentTools.declined");
  if (tools.rows.length === 0) return strings.t("onboarding.agentTools.none");
  return null;
}

const AUTH_KEYS: Record<AgentAuth, string> = {
  signedIn: "onboarding.agents.auth.signedIn",
  signedOut: "onboarding.agents.auth.signedOut",
  expired: "onboarding.agents.auth.expired",
  unknown: "onboarding.agents.auth.unknown",
};

/** The line under an agent's name: its install while one runs or failed, else its sign-in. */
export function agentDetail(strings: Strings, row: AgentRow): string {
  const install = row.install;
  if (install != null && install.state !== "installed") {
    if (install.state === "installing") {
      const step = install.step ?? "";
      return step ? `${strings.t("onboarding.agents.installing")} ${step}` : strings.t("onboarding.agents.installing");
    }
    if (install.state === "failed")
      return install.message
        ? strings.format("onboarding.agents.installFailed", install.message)
        : strings.t("onboarding.agents.notInstalled");
    return strings.t("onboarding.agents.notInstalled");
  }
  return strings.t(AUTH_KEYS[row.auth] ?? AUTH_KEYS.unknown);
}

/** The line under the agent list, or null for none. */
export function agentsStatus(strings: Strings, agents: OnboardingState["agents"]): string | null {
  if (agents?.signInFailed) return strings.t("onboarding.agents.signIn.failed");
  if (agents == null || !agents.loaded) return strings.t("onboarding.agents.checking");
  if (agents.rows.length === 0) return strings.t("onboarding.agents.none");
  if (agents.signingIn != null) return strings.t("onboarding.agents.signIn.running");
  return null;
}

/** A row's trailing words: Waiting, the running counts (or the kind being read), what came over,
 * or Couldn’t read (its reason the tooltip). */
export function importRowDetail(strings: Strings, row: ImportRow): { text: string; tooltip: string | null } {
  if (row.kind !== "profile") return { text: "", tooltip: null };
  const state = row.state;
  switch (state.kind) {
    case "waiting":
      return { text: strings.t("onboarding.import.waiting"), tooltip: null };
    case "importing": {
      const running = countsLine(strings, state.counts);
      return { text: running || (state.dataKind == null ? "" : kindLabel(strings, state.dataKind)), tooltip: null };
    }
    case "done":
      return { text: countsLine(strings, state.counts), tooltip: null };
    case "failed":
      return { text: strings.t("onboarding.import.rowFailed"), tooltip: state.reason ?? null };
    default:
      return { text: "", tooltip: null };
  }
}

/** The line under the import list (empty while it says nothing). */
export function importStatus(strings: Strings, importer: ImportState): string {
  switch (importer.phase) {
    case "idle":
      return strings.t("onboarding.import.notSearched");
    case "detecting":
      return strings.t("onboarding.import.detecting");
    case "importing":
    case "confirmingPasswords":
    case "explainingAccess":
      return "";
    case "finished": {
      const summary = importer.summary;
      if (summary == null) return strings.t("onboarding.import.importedNothing");
      const counts = countsLine(strings, summary.counts);
      const parts = [
        counts ? strings.format("onboarding.import.imported", counts) : strings.t("onboarding.import.importedNothing"),
      ];
      if (summary.passwordsSkipped > 0)
        parts.push(
          strings.format("onboarding.import.passwordsSkipped", formatCount(strings, summary.passwordsSkipped)),
        );
      if (summary.passwordsConflicts > 0)
        parts.push(
          strings.format("onboarding.import.passwordsConflicts", formatCount(strings, summary.passwordsConflicts)),
        );
      if (summary.passwordsNotRead) parts.push(strings.t("onboarding.import.passwordsNotRead"));
      if (summary.someFailed) parts.push(strings.t("onboarding.import.someFailed"));
      return parts.join(" ");
    }
    case "failed":
      return importer.failure ?? "";
    default:
      return importer.rows.length === 0 ? strings.t("onboarding.import.none") : "";
  }
}

/** The Computer Use footer's line on why Allow cannot help, or null. */
export function computerUseNote(strings: Strings, note: ComputerUseState["note"]): string | null {
  switch (note) {
    case "helperFailed":
      return strings.t("onboarding.computerUse.helper.failed");
    case "helperVersionMismatch":
      return strings.t("onboarding.computerUse.helper.versionMismatch");
    case "unavailable":
      return strings.t("onboarding.computerUse.helper.unavailable");
    case "off":
      return strings.t("onboarding.computerUse.off");
    default:
      return null;
  }
}

export function computerUseName(strings: Strings, pane: string): string {
  return strings.t(
    pane === "accessibility" ? "onboarding.computerUse.accessibility" : "onboarding.computerUse.screenshots",
  );
}

export function computerUseLine(strings: Strings, pane: string): string {
  return strings.t(
    pane === "accessibility" ? "onboarding.computerUse.accessibility.line" : "onboarding.computerUse.screenshots.line",
  );
}

/** The window's title for the Window menu and VoiceOver. */
export function windowTitle(strings: Strings, state: OnboardingState | null): string {
  if (state?.step === "importData") return strings.t("onboarding.import.title2");
  if (state?.step === "computerUse") return strings.t("onboarding.computerUse.title");
  if (state?.step === "agentTools") return strings.t("onboarding.agentTools.title");
  return strings.t("onboarding.agents.title");
}

// MARK: Keys

/** What a key press asks for: Return the footer's filled button, Escape Skip / Not Now. */
export type KeyIntent = "next" | "skip" | null;

export interface KeyLike {
  key: string;
  repeat?: boolean;
  isComposing?: boolean;
  defaultPrevented?: boolean;
  metaKey?: boolean;
  ctrlKey?: boolean;
  altKey?: boolean;
  shiftKey?: boolean;
  target?: unknown;
}

/** A target that keeps Return for itself: a text field, a focused button or link (Return presses
 * it, as Space does), an open menu or popup, or a select. */
function ownsReturn(target: unknown): boolean {
  const element = target as {
    closest?: (selector: string) => unknown;
    isContentEditable?: boolean;
    tagName?: string;
    type?: string;
  } | null;
  if (!element || typeof element.closest !== "function") return false;
  if (element.isContentEditable) return true;
  const tag = (element.tagName ?? "").toLowerCase();
  if (tag === "textarea" || tag === "select") return true;
  if (tag === "input" && !["checkbox", "radio", "button", "submit", "reset"].includes(element.type ?? "text"))
    return true;
  return Boolean(
    element.closest(
      'button, a[href], [role="button"], [role="link"], [role="menu"], [role="listbox"], [role="dialog"], .ui-popup, [aria-haspopup][aria-expanded="true"]',
    ),
  );
}

/** A popup or menu open over the page keeps Escape for itself. */
function ownsEscape(target: unknown): boolean {
  const element = target as { closest?: (selector: string) => unknown } | null;
  if (!element || typeof element.closest !== "function") return false;
  return Boolean(element.closest('[role="menu"], [role="listbox"], [role="dialog"], .ui-popup'));
}

/** Return or Enter goes to the footer's filled button when it is enabled; Escape skips. Never on a
 * repeat, a modifier, an IME composition, a press something else took, or a control that owns it. */
export function keyIntent(event: KeyLike, footer: OnboardingFooter | null): KeyIntent {
  if (event.repeat || event.isComposing || event.defaultPrevented) return null;
  if (event.metaKey || event.ctrlKey || event.altKey) return null;
  if (event.key === "Enter") {
    if (event.shiftKey || ownsReturn(event.target)) return null;
    return footer?.primaryEnabled ? "next" : null;
  }
  if (event.key === "Escape") return ownsEscape(event.target) ? null : "skip";
  return null;
}
