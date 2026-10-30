// The Harnesses page's rows (cx-uj5g8): every harness the model catalog names and every one acpmux
// found on this Mac, each with its state here. The installed ones first, then the rest, each in
// the catalog's order: a sign-in check that answers later changes a row's state, never its place.
import { type HarnessHealth, needsLogin } from "../HarnessHealthNotice";
import type { AcpmuxSnapshot } from "../model";
import type { PickerCatalog } from "../modelCatalogData";

export type HarnessStatus = "ready" | "signIn" | "unavailable" | "notInstalled" | "checking";

/// The command that installs a harness's CLI, run in place by Install (the rest open their setup
/// page). Keyed by the acpmux harness id.
export const INSTALL_COMMANDS: Readonly<Record<string, string>> = {
  claude: "npm install -g @anthropic-ai/claude-code",
  codex: "npm install -g @openai/codex",
  opencode: "npm install -g opencode-ai",
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
      const login =
        acpmux.find((candidate) => candidate.id === harness)?.auth?.login || checked?.login?.trim() || undefined;
      const status: HarnessStatus = !entry.installed
        ? checking
          ? "checking"
          : "notInstalled"
        : needsLogin(checked?.auth) && login
          ? "signIn"
          : entry.unavailable
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
  return [
    ...rows.filter((row) => row.status !== "notInstalled" && row.status !== "checking"),
    ...rows.filter((row) => row.status === "notInstalled" || row.status === "checking"),
  ];
}
