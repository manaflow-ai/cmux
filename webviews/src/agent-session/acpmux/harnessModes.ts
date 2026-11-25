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
  /** The mode a chat a Cloud machine begins in when it asks: a start whose level asks, or one the
   *  machine holds to the remote `ask` policy (a team machine, a phone), starts the harness in its
   *  asking mode (acpmux `web_modes.rs`: Claude's `ASKING_MODES` first row, the Codex bridge's
   *  `BRIDGE_ASKING_MODES`). The person's own machine starts at their level ([`cloudStartMode`]).
   *  `name` is the harness's own label for a mode its menu does not list (the bridge's `ask`). */
  remoteStart: { id: string; name?: string };
  /** The mode the person's own Cloud machine moves a new chat to under a full-access start level,
   *  where the harness takes it (cmux-tui agent_session_start.rs `cloud_default_mode`): Claude Code's
   *  Auto. None: the chat keeps the highest mode. */
  cloudDefault?: string;
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
  remoteStart: { id: "default" },
  // Lawrence 2026-11-20: "we need to support auto mode for cloud mode for claude harness".
  cloudDefault: "auto",
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
  // cmux-codex-acp `config.rs` `MODES` names it "Ask" ("Asks before every command and every edit").
  remoteStart: { id: "ask", name: "Ask" },
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

/** The asking mode a new chat whose first send starts it on a Cloud machine begins in when it asks
 * (`remoteStart`), named as the harness's menu names it. None for a harness this table does not list: the Cloud machine
 * decides, and the chip says so with its generic label until the chat reports. */
export function remoteStartMode(
  family: string | undefined,
  harness: string | undefined,
): { id: string; name: string } | undefined {
  const menu = familyMenu(family, harness);
  if (!menu) return undefined;
  const { id, name } = menu.remoteStart;
  return { id, name: menu.rows.find((row) => row.id === id)?.name ?? name ?? id };
}

/** acpmux's full-access mode ids (`FULL_ACCESS_MODES`, hub/start_mode.rs): a start-mode answer in one
 * of them says new chats start in full access. */
const FULL_ACCESS_MODE_IDS: ReadonlySet<string> = new Set([
  "bypassPermissions",
  "agent-full-access",
  "full-access",
  "yolo",
]);

/** The mode a new chat whose first send starts it on the person's own Cloud machine begins in when
 * nothing was picked for it: the person's start level for new chats, which the start carries to
 * that machine (`permission_mode`, cmux-tui agent_session_start.rs `start_policy`) and which this
 * Mac's acpmux answers as its start mode for the harness (`level`; `null`: it sets none;
 * `undefined`: no answer yet). Full access, the default level, is the family's Cloud default
 * (Claude Code's Auto, `cloudDefault`) else its highest mode (Codex's Full access; Lawrence
 * 2026-11-20: "cloud mode should default in bypass permissions/auto mode"), also before any answer
 * and when this Mac's acpmux has none for an agent it does not run. A level that asks is the
 * family's asking mode ([`remoteStartMode`]). None for a harness this table does not list: the
 * Cloud machine decides. */
export function cloudStartMode(
  family: string | undefined,
  harness: string | undefined,
  level: { modeId: string } | null | undefined,
): { id: string; name: string } | undefined {
  const asking = remoteStartMode(family, harness);
  const highest = highestMode(family, harness);
  if (!asking || !highest) return asking;
  if (level?.modeId && !FULL_ACCESS_MODE_IDS.has(level.modeId)) return asking;
  const menu = familyMenu(family, harness);
  const start = menu?.rows.find((row) => row.id === menu.cloudDefault) ?? highest;
  return { id: start.id, name: start.name };
}

/** The modes a Cloud start on this family can be picked into: its asking mode, its Cloud default
 * (Claude Code's Auto) and its highest level. acpmux starts a chat in another mode that does not ask
 * (Accept edits) only on the person's own proof, which the Cloud start does not carry. None for a
 * harness this table does not list. */
export function cloudPickableModes(family: string | undefined, harness: string | undefined): string[] | undefined {
  const menu = familyMenu(family, harness);
  if (!menu) return undefined;
  return [menu.remoteStart.id, menu.cloudDefault, menu.highest].filter((id): id is string => id !== undefined);
}

/** The agent a Cloud machine starts when its send names none: acpmux's default, Claude first
 * (default_harness.rs). */
export const CLOUD_DEFAULT_AGENT = "claude";

/** The built-in UniiChat harness (acpmux config/discover.rs UNIICHAT_PROFILE): every acpmux bundles
 * it, so a Mac with no agent CLI shows it in the composer. Its tools run on its own server; it has no
 * permission modes on a machine. */
const UNII = "unii";

/** The agent a Cloud start runs for a chat the composer shows on HARNESS, and whether the send names
 * it. Claude and Codex, and any other agent the person picked (opencode, say: the machine runs it),
 * are named and run. UniiChat is not a machine agent: the send leaves it out, so the machine starts
 * its default, Claude, which the Mode chip names. The chip and every Cloud send read this one answer. */
export function cloudStartAgent(
  family: string | undefined,
  harness: string | undefined,
): { family: string | undefined; harness: string | undefined; named: boolean } {
  const id = (family ?? harness ?? "").toLowerCase();
  // No harness yet (none installed, or still listing): the send names none, so the machine's default.
  if (!id || id === UNII || (harness ?? "").toLowerCase() === UNII)
    return { family: CLOUD_DEFAULT_AGENT, harness: CLOUD_DEFAULT_AGENT, named: false };
  // A profile of this Mac's that routes Claude Code or Codex its own way (claude-sr2, claude-cr,
  // codex-acp: a harness file in ~/.config/cmux/harnesses or a discovered launcher) exists only here.
  // A Cloud machine carries the agents themselves (web/services/vms/images/agents.ts), so it runs
  // the base agent: naming the profile was refused as `agent_session.harness_missing` (cmux#51731).
  const base = cloudMachineAgent(harness) ?? cloudMachineAgent(family);
  if (base) return { family: base, harness: base, named: true };
  return { family, harness, named: true };
}

/** The agents every Cloud machine carries (web/services/vms/images/agents.ts GUEST_AGENTS). */
const CLOUD_MACHINE_AGENTS = new Set(["claude", "codex", "opencode", "pi"]);

/** The Cloud machine's agent for a harness id: itself when the machine carries it, the base agent for
 * a Claude Code or Codex profile (`claude-sr2` → `claude`), none for anything else. */
function cloudMachineAgent(value: string | undefined): string | undefined {
  const id = (value ?? "").toLowerCase();
  if (CLOUD_MACHINE_AGENTS.has(id)) return id;
  for (const base of ["claude", "codex"]) if (id.startsWith(`${base}-`) || id.startsWith(`${base}_`)) return base;
  return undefined;
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

/** The native label for a reported mode id, with a safe Full access fallback for older adapters. */
export function harnessModeName(family: string | undefined, harness: string | undefined, modeId: string): string {
  const row = familyMenu(family, harness)?.rows.find((candidate) => candidate.id === modeId);
  if (row) return row.name;
  if (modeId === "bypassPermissions") return "Bypass permissions";
  if (modeId === "agent-full-access") return "Full access";
  return "Full access";
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
