// The Harnesses page's rows (cx-uj5g8): every harness the model catalog names and every one acpmux
// found on this Mac, each with its state here. The installed ones first, then the rest, each in
// the catalog's order: a sign-in check that answers later changes a row's state, never its place.
import { type HarnessHealth, needsLogin } from "../harnessHealthNoticeModel";
import type { AcpmuxSnapshot } from "../model";
import type { PickerCatalog } from "../modelCatalogData";
import { withNetworkRetry } from "./installRetry";

export type HarnessStatus = "ready" | "signIn" | "unavailable" | "notInstalled" | "checking";

/// npm where this machine has it (an npm setup keeps its channel), else the vendor's own installer,
/// which needs no Node. Bash ships with macOS; pipefail (``withNetworkRetry``) preserves a failed
/// download's exit status even when the installer reading the empty pipe exits successfully. The
/// explicit shell also works when the user's login shell is fish. A network that drops during the
/// install is waited for, and the install runs again by itself (first-run finding 6); `probe` is
/// the server whose answer means the network is back.
const npmOrNative = (npmPackage: string, native: string, probe: string) =>
  withNetworkRetry(
    // l10n-allow: a shell command Install runs, never shown as text
    `if command -v npm >/dev/null 2>&1; then npm install -g ${npmPackage}; else ${native}; fi`,
    { probeUrl: probe },
  );

/// The command that installs a harness's CLI, run in place by Install (the rest open their setup
/// page). Keyed by the acpmux harness id.
export const INSTALL_COMMANDS: Readonly<Record<string, string>> = {
  claude: npmOrNative(
    "@anthropic-ai/claude-code",
    "curl -fsSL https://claude.ai/install.sh | bash",
    "https://claude.ai",
  ),
  // No tty here: never ask to start Codex or to remove another install.
  codex: npmOrNative(
    "@openai/codex",
    "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh",
    "https://chatgpt.com",
  ),
  opencode: npmOrNative("opencode-ai", "curl -fsSL https://opencode.ai/install | bash", "https://opencode.ai"),
  gemini: npmOrNative("@google/gemini-cli", "brew install gemini-cli", "https://registry.npmjs.org"),
};

export type HarnessRow = {
  /** The id acpmux runs it under (`chat.new`'s harness, `harness.health`'s id). */
  harness: string;
  name: string;
  /** The brand its mark draws. */
  mark: string;
  status: HarnessStatus;
  /** Why it is unavailable, as acpmux said it. */
  detail?: string;
  /** The command that signs it in. */
  login?: string;
  /** Its install and setup page. */
  docsUrl?: string;
  /** The command that installs it, run in place. */
  install?: string;
  /** The harness this row needs before it can run (Chief needs Claude Code): its install, sign-in and
   * checks are that harness's, and the row's own state is that harness's. */
  needs?: { harness: string; name: string };
};

/** acpmux's family of the built-in Chief harness (acpmux `CHIEF_FAMILY`). */
const CHIEF_FAMILY = "chief";
/** The Chief's own Claude routes: with one configured the Chief answers through it (optchat-chief
 * `host::default_harness`), so its row is left as acpmux reports it. */
const CHIEF_ROUTES = ["claude-cr", "claude-sr2"];
/** The harness a Chief answers through when no route is configured: the person's own Claude Code. */
const CHIEF_AGENT = "claude";

/// The Chief row as what it answers through, Claude Code (first-run findings row 7: "Chief: Ready" on a
/// Mac with no Claude Code while Chief refused every message). Ready only when Claude Code is; else
/// Claude Code's own fix: install it, or sign in to it. Its row is the evidence, so a check that has not
/// answered leaves Chief checking too.
function chiefRow(chief: HarnessRow, agent: HarnessRow): HarnessRow {
  const needs = { harness: agent.harness, name: agent.name };
  const { detail: _detail, login: _login, install: _install, docsUrl: _docs, ...base } = chief;
  return {
    ...base,
    status: agent.status,
    needs,
    ...(agent.detail ? { detail: agent.detail } : {}),
    ...(agent.login ? { login: agent.login } : {}),
    ...(agent.install ? { install: agent.install } : {}),
    ...(agent.docsUrl ? { docsUrl: agent.docsUrl } : {}),
  };
}

export function harnessRows(
  catalog: PickerCatalog,
  acpmux: AcpmuxSnapshot["catalog"],
  health: Readonly<Record<string, HarnessHealth | undefined>>,
  /** acpmux has not answered yet: a harness it has not listed is not known to be missing. */
  checking = false,
): HarnessRow[] {
  const rows = catalog.harnesses
    // A routing entry (a terminal harness) is not something to connect.
    .filter((entry) => entry.pickable || !entry.installed)
    .map((entry): HarnessRow => {
      const harness = entry.acpmuxHarness ?? entry.id;
      const checked = health[harness];
      // Health carries the account-home-qualified command; catalog auth.login
      // is the unqualified fallback while health has not answered.
      const login =
        checked?.login?.trim() || acpmux.find((candidate) => candidate.id === harness)?.auth?.login || undefined;
      const status: HarnessStatus = !entry.installed
        ? checking
          ? "checking"
          : "notInstalled"
        : !checked
          ? "checking"
          : needsLogin(checked.auth)
            ? "signIn"
            : // Ready only on evidence of a sign-in: an answer without one (no `auth`, unknown, or a
              // state this page does not know) is not ready, and the row offers its fix instead.
              checked.auth !== "signedIn" || entry.unavailable
              ? "unavailable"
              : "ready";
      return {
        harness,
        name: entry.name,
        mark: entry.brand ?? harness,
        status,
        ...(status === "unavailable" && entry.unavailable ? { detail: entry.unavailable } : {}),
        ...(login ? { login } : {}),
        ...(entry.docsUrl ? { docsUrl: entry.docsUrl } : {}),
        ...(INSTALL_COMMANDS[harness] ? { install: INSTALL_COMMANDS[harness] } : {}),
      };
    });
  // Group by installation, not asynchronously resolved health, so a check never moves a row.
  const installed = new Set(
    catalog.harnesses.filter((entry) => entry.installed).map((entry) => entry.acpmuxHarness ?? entry.id),
  );
  const chief = catalog.harnesses.find((entry) => entry.family === CHIEF_FAMILY);
  const agent = rows.find((row) => row.harness === CHIEF_AGENT);
  const routed = acpmux.some((entry) => CHIEF_ROUTES.includes(entry.id));
  const shown =
    chief && agent && !routed
      ? rows.map((row) => (row.harness === (chief.acpmuxHarness ?? chief.id) ? chiefRow(row, agent) : row))
      : rows;
  return [...shown.filter((row) => installed.has(row.harness)), ...shown.filter((row) => !installed.has(row.harness))];
}
