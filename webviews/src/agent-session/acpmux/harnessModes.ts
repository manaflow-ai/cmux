// l10n-allow-file: each harness's own mode names and descriptions, shown exactly as that harness's
// own app shows them (as model names are), never reworded by cmux. The menus' headings and the
// Recommended badge are pane strings (Localizable.xcstrings).
// The mode menu lists the harness's OWN modes, with its own labels, descriptions and order (Leo
// 2026-10-21, against Claude Code's and Codex's menus: "WHY ARE YOU HALLUCINATING THINGS?"). acpmux
// and the Codex bridge report the mode ids; a family listed here shows them as its own app does. A
// harness this table does not list shows what it reports, unchanged.

import type { StringKey } from "./i18n";

export type ModeIconName = "hand" | "terminal-shield" | "shield-alert";

export type HarnessModeRow = {
  /** The mode id the harness reports over ACP (`availableModes[].id`). */
  id: string;
  name: string;
  description: string;
  /** The harness marks this mode as its recommended one. */
  recommended?: boolean;
  /** The row's own icon, as the harness's menu draws it; none draws no icon column. */
  icon?: ModeIconName;
};

export type HarnessModeMenu = {
  /** The menu's heading, a pane string. `undefined` uses the picker's own label ("Mode"). */
  heading?: StringKey;
  /** Rows show their number keys (1 to 9), as Claude Code's mode menu does. */
  numbered: boolean;
  rows: readonly HarnessModeRow[];
  /** Reported ids that only acpmux or a bridge adds (not the harness's own): shown only while current. */
  hidden: readonly string[];
  /** The mode that skips every approval, the harness's highest permission level (acpmux's
   *  `FULL_ACCESS_MODES`, hub/start_mode.rs): what acpmux starts a chat in when the person chose none. */
  highest: string;
};

/** Claude Code's Mode menu: its five permission modes (`--permission-mode` ids), in its order. */
const CLAUDE: HarnessModeMenu = {
  numbered: true,
  rows: [
    { id: "auto", name: "Auto", description: "Claude handles permission decisions", recommended: true },
    { id: "default", name: "Manual", description: "Always ask before making changes" },
    { id: "acceptEdits", name: "Accept edits", description: "Automatically accept all file edits" },
    { id: "plan", name: "Plan", description: "Create a plan before making changes" },
    { id: "bypassPermissions", name: "Bypass permissions", description: "Accepts all permissions" },
  ],
  hidden: [],
  highest: "bypassPermissions",
};

/** Codex's approval menu. The bridge (cmux-codex-acp `config.rs` `MODES`) runs Codex's default as
 * `agent` (on-request, workspace-write) and full access as `agent-full-access`; Approve for me
 * (Codex's auto-review) shows once the bridge reports it as `auto-review`. The bridge's own `ask` and
 * `read-only` (acpmux's policy modes) are not Codex's menu. */
const CODEX: HarnessModeMenu = {
  heading: "picker.codexApprovalHeading",
  numbered: false,
  rows: [
    {
      id: "agent",
      name: "Ask for approval",
      description: "Always ask to edit external files and use the internet",
      icon: "hand",
    },
    {
      id: "auto-review",
      name: "Approve for me",
      description: "Only ask for actions detected as potentially unsafe",
      icon: "terminal-shield",
    },
    {
      id: "agent-full-access",
      name: "Full access",
      description: "Unrestricted access to the internet and any file on your computer",
      icon: "shield-alert",
    },
  ],
  hidden: ["ask", "read-only"],
  highest: "agent-full-access",
};

/** The harness family's own menu (by acpmux's family, else by the harness id: a second Claude
 * account's profile is `claude-…`), when the harness reports at least one of its modes. An adapter
 * that reports other ids (another Codex adapter, an old build) shows what it reports. */
export function harnessModeMenu(
  family: string | undefined,
  harness: string | undefined,
  reported: readonly string[],
): HarnessModeMenu | undefined {
  const menu = familyMenu(family, harness);
  return menu?.rows.some((row) => reported.includes(row.id)) ? menu : undefined;
}

/** The family's highest permission level (Claude Code's Bypass permissions, Codex's Full access), the
 * mode to show and start in when nothing chose one (Leo 2026-10-23: "if you don't know what to switch
 * to, typically just switch to the highest permission level"). None for a harness this table does
 * not list. */
export function highestMode(family: string | undefined, harness: string | undefined): HarnessModeRow | undefined {
  const menu = familyMenu(family, harness);
  return menu?.rows.find((row) => row.id === menu.highest);
}

/** The family's own menu whatever the harness reported (none yet: a New Tab before its chat
 * starts), for a pick made before the chat reports its modes. None for a harness this table does
 * not list. */
export function harnessFamilyMenu(
  family: string | undefined,
  harness: string | undefined,
): HarnessModeMenu | undefined {
  return familyMenu(family, harness);
}

function familyMenu(family: string | undefined, harness: string | undefined): HarnessModeMenu | undefined {
  const of = (value: string | undefined) => {
    const id = (value ?? "").toLowerCase();
    if (id === "claude" || id.startsWith("claude-") || id.startsWith("claude_")) return CLAUDE;
    if (id === "codex" || id.startsWith("codex-") || id.startsWith("codex_")) return CODEX;
    return undefined;
  };
  return of(family) ?? of(harness);
}

export type ReportedMode = { id: string; name: string; description?: string };
export type ShownMode = ReportedMode & { recommended?: boolean; icon?: ModeIconName };

/** The rows the menu shows for what the harness reported: the family's own rows it reported, in the
 * family's order with its labels; then any other reported mode as reported (one only acpmux adds,
 * `hidden`, only while it is `current`, so the button can still name it). */
export function shownModes(
  menu: HarnessModeMenu | undefined,
  reported: readonly ReportedMode[],
  current?: string,
): ShownMode[] {
  if (!menu) return [...reported];
  const ids = new Set(reported.map((mode) => mode.id));
  const own: ShownMode[] = menu.rows
    .filter((row) => ids.has(row.id))
    .map((row) => ({
      id: row.id,
      name: row.name,
      description: row.description,
      ...(row.recommended ? { recommended: true } : {}),
      ...(row.icon ? { icon: row.icon } : {}),
    }));
  const known = new Set(menu.rows.map((row) => row.id));
  const rest = reported.filter(
    (mode) => !known.has(mode.id) && (!menu.hidden.includes(mode.id) || mode.id === current),
  );
  return [...own, ...rest];
}

/** The badge on the mode the harness recommends, as Claude Code's menu labels Auto. */
export const RECOMMENDED_BADGE: StringKey = "picker.modeRecommended";
