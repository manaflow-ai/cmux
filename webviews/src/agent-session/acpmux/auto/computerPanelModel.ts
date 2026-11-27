// The Computer panel's typed state and its formatting (RFD 0080 "Computer details"). Pure
// presentation: the daemon decides home, shape, size, sleep and why; this turns them into words.
// Mirrors the shared ComputerStatus shape (Rust serde snake_case).
import { intl } from "../../../ui/intl";
import type { StringKey, Translate } from "../i18n";
import { SURVIVES_ROWS, type SurvivesRow } from "./survivesTable";

export type ComputerHome = "this_mac" | "cloud" | "peer";
export type ComputerShape = { vcpu: number; memory_gib: number };
export type ComputerSize = { mode: "auto" } | ({ mode: "pinned" } & ComputerShape);
export type ComputerSleep = { mode: "auto" } | { mode: "keep_awake"; until_ms?: number };
export type WhyReason =
  | "mac_memory_pressure"
  | "mac_busy"
  | "lid_closed"
  | "grew_for_memory"
  | "person_moved"
  | "slots_full"
  | "spend_cap";
export type HistoryChange = "moved_to_cloud" | "moved_to_mac" | "resized_up" | "resized_down" | "lost";

/// One time the computer changed: when, what, and AUTO's one-sentence reason. `vm_id` is shown only here.
export type ComputerHistoryEntry = {
  at_ms: number;
  change: HistoryChange;
  reason: WhyReason;
  command?: string;
  vm_id?: string;
};

export type ComputerPanelProps = {
  agent_name: string;
  session_id: string;
  home: ComputerHome;
  shape?: ComputerShape;
  size: ComputerSize;
  sleep: ComputerSleep;
  history: readonly ComputerHistoryEntry[];
  /// Minutes this agent's cloud computer was awake today; absent while it has none.
  minutes_awake_today?: number;
  survives?: readonly SurvivesRow[];
};

export type PanelFormat = { t: Translate; locale?: string; timeZone?: string };

export function shapeText(shape: ComputerShape, t: Translate): string {
  return t("computerPanel.shape", { vcpu: shape.vcpu, gib: shape.memory_gib });
}

export function durationText(minutes: number, t: Translate): string {
  const total = Math.max(0, Math.round(minutes));
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h === 0) return t("computerPanel.duration.m", { m });
  if (m === 0) return t("computerPanel.duration.h", { h });
  return t("computerPanel.duration.hm", { h, m });
}

export function clockText(ms: number, { locale, timeZone }: Pick<PanelFormat, "locale" | "timeZone">): string {
  return intl.DateTimeFormat(locale, { hour: "2-digit", minute: "2-digit", timeZone }).format(new Date(ms));
}

export function homeText(home: ComputerHome, t: Translate): string {
  return t(`computerPanel.home.${home}`);
}

/// The Size row: what is chosen, then what it is now. Pinned is the only state that shows a pin.
export function sizeRow(
  p: Pick<ComputerPanelProps, "size" | "shape" | "home">,
  t: Translate,
): { pinned: boolean; text: string } {
  if (p.size.mode === "pinned") {
    return { pinned: true, text: t("computerPanel.size.pinned", { shape: shapeText(p.size, t) }) };
  }
  if (p.shape) return { pinned: false, text: t("computerPanel.size.auto", { shape: shapeText(p.shape, t) }) };
  return { pinned: false, text: t("computerPanel.size.none") };
}

export function sleepRow(sleep: ComputerSleep, f: PanelFormat): { pinned: boolean; text: string } {
  if (sleep.mode === "auto") return { pinned: false, text: f.t("computerPanel.sleep.auto") };
  if (sleep.until_ms === undefined) return { pinned: true, text: f.t("computerPanel.sleep.keepForever") };
  return { pinned: true, text: f.t("computerPanel.sleep.keepUntil", { time: clockText(sleep.until_ms, f) }) };
}

/// "Awake today" cost line: local time is free, said as plainly as the RFD does.
export function awakeRow(p: Pick<ComputerPanelProps, "home" | "minutes_awake_today">, t: Translate): string {
  if (p.home === "this_mac") return t("computerPanel.awake.free");
  if (p.minutes_awake_today === undefined) return t("computerPanel.awake.none");
  return t("computerPanel.awake.today", { duration: durationText(p.minutes_awake_today, t) });
}

const WHY_KEYS: Record<WhyReason, StringKey> = {
  mac_memory_pressure: "computerPanel.why.mac_memory_pressure",
  mac_busy: "computerPanel.why.mac_busy",
  lid_closed: "computerPanel.why.lid_closed",
  grew_for_memory: "computerPanel.why.grew_for_memory",
  person_moved: "computerPanel.why.person_moved",
  slots_full: "computerPanel.why.slots_full",
  spend_cap: "computerPanel.why.spend_cap",
};

export function reasonText(reason: WhyReason, command: string | undefined, t: Translate): string {
  if (reason === "grew_for_memory" && command) return t("computerPanel.why.grew_for_command", { command });
  return t(WHY_KEYS[reason]);
}

/// One history line: "14:02 · Moved to Cloud: your Mac was under memory pressure." The VM id is
/// returned apart because only this panel shows it.
export function historyLine(e: ComputerHistoryEntry, f: PanelFormat): { time: string; text: string; vmId?: string } {
  return {
    time: clockText(e.at_ms, f),
    text: f.t("computerPanel.history.line", {
      change: f.t(`computerPanel.change.${e.change}`),
      reason: reasonText(e.reason, e.command, f.t),
    }),
    vmId: e.vm_id,
  };
}

/// A survives row as one sentence per column, for the one-line-per-row list.
export function survivesLine(row: SurvivesRow, t: Translate): string {
  const parts = (["project_files", "other_files", "processes", "chat"] as const).map((column) => {
    const cell = row.cells[column];
    const base = t("computerPanel.survives.cell", {
      column: t(`computerPanel.column.${column}`),
      value: t(`computerPanel.value.${cell.value}`),
    });
    return cell.note ? `${base} (${t(cell.note)})` : base;
  });
  return parts.join("; ");
}

export function survivesRows(p: Pick<ComputerPanelProps, "survives">): readonly SurvivesRow[] {
  return p.survives ?? SURVIVES_ROWS;
}

export type { StringKey };
