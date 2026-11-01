// The Harnesses page's rows (cx-uj5g8): every harness the model catalog names and every one acpmux
// found on this Mac, each with its state here. The installed ones first, then the rest, each in
// the catalog's order: a sign-in check that answers later changes a row's state, never its place.
import { type HarnessHealth, needsLogin } from "../HarnessHealthNotice";
import type { AcpmuxSnapshot } from "../model";
import type { PickerCatalog } from "../modelCatalogData";

export type HarnessStatus = "ready" | "signIn" | "unavailable" | "notInstalled" | "checking";

/// npm where this machine has it (an npm setup keeps its channel), else the vendor's own installer,
/// which needs no Node. `/bin/sh`: the host runs the command in the user's login shell, which may
/// not be a POSIX one (fish).
const npmOrNative = (npmPackage: string, native: string) =>
  // l10n-allow: a shell command Install runs, never shown as text
  `/bin/sh -c 'if command -v npm >/dev/null 2>&1; then npm install -g ${npmPackage}; else ${native}; fi'`;

/// The command that installs a harness's CLI, run in place by Install (the rest open their setup
/// page). Keyed by the acpmux harness id.
export const INSTALL_COMMANDS: Readonly<Record<string, string>> = {
  claude: npmOrNative("@anthropic-ai/claude-code", "curl -fsSL https://claude.ai/install.sh | bash"),
  // No tty here: never ask to start Codex or to remove another install.
  codex: npmOrNative("@openai/codex", "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh"),
  opencode: npmOrNative("opencode-ai", "curl -fsSL https://opencode.ai/install | bash"),
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
};

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
  return [...rows.filter((row) => installed.has(row.harness)), ...rows.filter((row) => !installed.has(row.harness))];
}
