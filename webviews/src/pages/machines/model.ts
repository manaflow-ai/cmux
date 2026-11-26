// The Machines section's layout, from the app's rows (moved from Swift: MachineSectionStyle.groups,
// MachineSectionRow.stateText/healthHelp/readinessRank, JoinedMachineStrings.caption). Pure: the
// component and its tests read the same answers.
import type { Strings } from "../shared/i18n";
import type {
  JoinedMachine,
  JoinedDialPhase,
  JoinedMachineChange,
  MachineKind,
  MachineRow,
  MachineSectionStyle,
  MachinesSnapshot,
} from "./types";

/** The kinds in group order: this Mac (no header), then Cloud, SSH, Servers, Joined. */
export const KIND_ORDER: readonly MachineKind[] = ["local", "cloud", "ssh", "server", "joined"];

/** A kind's icon in the cmux icon pack (the native catalog's icon for the same kind). */
export const KIND_ICON: Record<MachineKind, string> = {
  local: "machine.local",
  cloud: "cloud",
  ssh: "machine.remote",
  server: "machine.mac",
  joined: "network",
};

/** Whether machines sit under a header per kind. */
export const groupsByKind = (style: MachineSectionStyle) => style !== "flat";
/** Whether each row has a second line with its link state. */
export const showsStateLine = (style: MachineSectionStyle) => style !== "compact";

/** Where a row sorts inside its group (Leo, 2026-10-31: "ready machines first, then paused, then
 * offline"): this Mac, connected, connecting or resuming, paused, then the rest. */
export function readinessRank(row: MachineRow): number {
  if (row.isLocal) return 0;
  if (row.isConnected) return 1;
  if (row.isConnecting) return 2;
  if (row.serverState === "paused") return 3;
  return 4;
}

export interface MachineGroup {
  id: string;
  /** The kind its header names; undefined draws no header (this Mac, or the flat list). */
  kind?: MachineKind;
  rows: MachineRow[];
}

/** `rows` in `style`'s groups: one untitled group for flat; otherwise this Mac first with no header,
 * then Cloud, SSH, server and joined machines under their headers. Inside a group, by readiness,
 * each rank in the order given (a stable sort). A kind with no machine has no group. */
export function groups(rows: readonly MachineRow[], style: MachineSectionStyle): MachineGroup[] {
  const sorted = rows
    .map((row, index) => ({ row, index }))
    .sort((a, b) => readinessRank(a.row) - readinessRank(b.row) || a.index - b.index)
    .map(({ row }) => row);
  if (!groupsByKind(style)) return sorted.length ? [{ id: "all", rows: sorted }] : [];
  return KIND_ORDER.flatMap((kind) => {
    const members = sorted.filter((row) => row.kind === kind);
    return members.length ? [{ id: kind, kind: kind === "local" ? undefined : kind, rows: members }] : [];
  });
}

/** A group header's text; undefined for this Mac. */
export function groupTitle(kind: MachineKind | undefined, strings: Strings): string | undefined {
  switch (kind) {
    case "cloud":
      return strings.t("machines.group.cloud");
    case "ssh":
      return strings.t("machines.group.ssh");
    case "server":
      return strings.t("machines.group.servers");
    case "joined":
      return strings.t("machines.group.joined");
    default:
      return undefined;
  }
}

/** The state in words: Connected, the server's state, Connecting… or Offline. */
export function stateText(row: MachineRow, strings: Strings): string {
  if (row.isConnected) return strings.t("machines.connected");
  if (row.serverState) return strings.t(`machines.${row.serverState}`);
  return strings.t(row.isConnecting ? "machines.connecting" : "machines.offline");
}

/** A check step's line, keyed by its name in camelCase (`peer-back` is `addMachine.step.peerBack`); a step
 * this build does not know shows by its raw name. */
export function stepText(step: string, strings: Strings): string {
  const key = `addMachine.step.${step.replace(/-([a-z])/g, (_, c: string) => c.toUpperCase())}`;
  const text = strings.t(key);
  return text === key ? step : text;
}

/** The status mark's tooltip: which step the last check flagged. */
export function healthHelp(row: MachineRow, strings: Strings): string | undefined {
  const step = row.healthStep ? stepText(row.healthStep, strings) : "";
  switch (row.health) {
    case "ok":
      return strings.t("machines.health.ok");
    case "warning":
      return strings.format("machines.health.warning", step);
    case "failing":
      return strings.format("machines.health.failing", step);
    default:
      return undefined;
  }
}

/** The platform a machine reported at join, as a person reads it (an unknown one as sent). */
export function platformText(platform: string): string {
  switch (platform.toLowerCase()) {
    case "macos":
    case "darwin":
      return "macOS";
    case "linux":
      return "Linux";
    case "windows":
      return "Windows";
    default:
      return platform;
  }
}

/** The caption of a joined row whose last change failed. */
const FAILED_KEY: Record<JoinedMachineChange, string> = {
  revoke: "machines.joined.revokeFailed",
  rotate: "machines.joined.rotateFailed",
  remove: "machines.joined.removeFailed",
};

/** A joined machine's caption: the failure of its last change, else its state, platform and who
 * made its line. */
export function joinedCaption(
  machine: JoinedMachine,
  failed: JoinedMachineChange | undefined,
  strings: Strings,
): string {
  if (failed) return strings.t(FAILED_KEY[failed]);
  const parts = [strings.t(`machines.joined.${machine.state}`)];
  if (machine.platform) parts.push(platformText(machine.platform));
  if (machine.mintedBy) parts.push(strings.format("machines.joined.mintedBy", machine.mintedBy));
  return parts.join(" · ");
}

/** Whether the row is a machine the app connects to (it can open a workspace), not a joined machine
 * reached through the mesh alone. */
export const isLinked = (row: MachineRow) => !row.joined || row.id !== `joined:${row.joined.id}`;

/** Whether New Workspace on the row asks the other machine first (`openJoined`): an online joined
 * machine the app reaches only through the hub, Mac or Linux. A Mac signed in on itself allows it
 * there, once, on its consent card (Leo, 2026-11-14, hq#11046); a machine joined by a line or a pair
 * code made from another device counts that join as the consent (acpmux `session_service.rs`), so a
 * Linux box opens with no card. Whatever it refuses, the row says (`dialText`). */
export const asksFirst = (row: MachineRow) => !isLinked(row) && row.joined?.state === "online";

/** The words a row shows instead of its caption while its New Workspace on the other Mac is under way
 * or stopped (`name`: that Mac). */
export function dialText(phase: JoinedDialPhase, name: string, strings: Strings): string {
  return strings.format(`machines.dial.${phase}`, name);
}

/** Whether the row offers Retry: the ask stopped and nothing asks again by itself.
 * retry-prompt-ok: a Retry puts a consent card on the other Mac's screen and opens a workspace there. */
export const dialStopped = (phase: JoinedDialPhase | undefined) =>
  phase === "declined" || phase === "unanswered" || phase === "update" || phase === "failed";

/** One line of the section, top to bottom. */
export type SectionItem =
  | { type: "header"; key: string; title: string; first: boolean }
  | { type: "row"; key: string; row: MachineRow; afterHeader: boolean }
  | { type: "add"; key: string; gap: boolean };

/** A new snapshot with each row that did not change kept as the previous object. */
export function keptSnapshot(previous: MachinesSnapshot | undefined, next: MachinesSnapshot): MachinesSnapshot {
  if (!previous) return next;
  const rows = new Map(previous.rows.map((row) => [row.id, row]));
  return {
    ...next,
    rows: next.rows.map((row) => {
      const old = rows.get(row.id);
      return old && JSON.stringify(old) === JSON.stringify(row) ? old : row;
    }),
  };
}

/** The section's lines: each group's header, then its rows, then Add Machine…. */
export function sectionItems(
  snapshot: Pick<MachinesSnapshot, "rows" | "style">,
  strings: Strings,
  removed: ReadonlySet<string> = new Set(),
): SectionItem[] {
  const items: SectionItem[] = [];
  // A row the person just removed leaves at once; the host's next snapshot has it gone too.
  const rows = removed.size ? snapshot.rows.filter((row) => !removed.has(row.id)) : snapshot.rows;
  for (const group of groups(rows, snapshot.style)) {
    const title = groupTitle(group.kind, strings);
    // The Cloud header says only Cloud, never the active team the snapshot names
    // (https://github.com/manaflow-ai/cmux/issues/45695).
    if (title) items.push({ type: "header", key: `h:${group.id}`, title, first: items.length === 0 });
    group.rows.forEach((row, index) => {
      items.push({ type: "row", key: `r:${row.id}`, row, afterHeader: index === 0 && !!title });
    });
  }
  items.push({ type: "add", key: "add", gap: groupsByKind(snapshot.style) && items.length > 0 });
  return items;
}

/** The lines as shown, in text (tests): headers, `name · state` rows, Add Machine…. */
export function shownLines(snapshot: MachinesSnapshot, strings: Strings): string[] {
  const state = showsStateLine(snapshot.style);
  return sectionItems(snapshot, strings).map((item) => {
    if (item.type === "header") return item.title;
    if (item.type === "add") return strings.t("machines.addMachine");
    const { row } = item;
    if (row.joined) return [row.name, joinedCaption(row.joined, snapshot.failed[row.joined.id], strings)].join(" · ");
    const showsState = state || (!row.isConnected && !row.isConnecting);
    return showsState ? `${row.name} · ${stateText(row, strings)}` : row.name;
  });
}
