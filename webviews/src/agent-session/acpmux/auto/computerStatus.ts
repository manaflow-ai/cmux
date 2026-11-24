// RFD 0080 (AUTO-first agentic computers): the typed state the status line and the popover rows read,
// and the pure functions that turn it into words. React only draws what these return; the daemon
// (acpmux, Rust) owns the state itself. Every word comes from the pane's string table.
import type { StringKey, Translate } from "../i18n";

export type ComputerHome = "this_mac" | "cloud" | "peer";
export type ComputerPhase =
  | "running"
  | "preparing"
  | "moving"
  | "move_failed"
  | "reconnecting"
  | "sleeping"
  | "paused_spend_cap"
  | "paused_pool_spent"
  | "staying_local_slots_full";
export type MoveFailure = "network_dropped" | "mac_slept" | "refused" | "other";
export type WhyReason =
  | "mac_memory_pressure"
  | "mac_busy"
  | "lid_closed"
  | "grew_for_memory"
  | "person_moved"
  | "slots_full"
  | "spend_cap";

/// Mirrors the daemon's `ComputerStatus` (serde snake_case).
export type ComputerStatus = {
  session_id: string;
  home: ComputerHome;
  phase: ComputerPhase;
  phase_since_ms?: number;
  move?: { direction: "to_cloud" | "to_mac"; cancellable: boolean; failure?: MoveFailure };
  /// Only when the chat has a cloud computer.
  shape?: { vcpu: number; memory_gib: number };
  size: { mode: "auto" } | { mode: "pinned"; vcpu: number; memory_gib: number };
  /// `until_ms` absent means until the person says.
  sleep: { mode: "auto" } | { mode: "keep_awake"; until_ms?: number };
  why?: { at_ms: number; reason: WhyReason; command?: string };
};

export type StatusActionId = "cancel" | "retry" | "raise_limit" | "run_on_mac" | "pause_one" | "upgrade";
export type StatusAction = { id: StatusActionId; label: string };
export type StatusLineText = { text: string; actions: StatusAction[] };

const ACTION_KEY: Record<StatusActionId, StringKey> = {
  cancel: "computer.action.cancel",
  retry: "computer.action.retry",
  raise_limit: "computer.action.raiseLimit",
  run_on_mac: "computer.action.runOnMac",
  pause_one: "computer.action.pauseOne",
  upgrade: "computer.action.upgrade",
};

const FAILURE_KEY: Record<MoveFailure, StringKey> = {
  network_dropped: "computer.status.failNetwork",
  mac_slept: "computer.status.failMacSlept",
  refused: "computer.status.failRefused",
  other: "computer.status.failOther",
};

const PLACE_KEY: Record<ComputerHome, StringKey> = {
  this_mac: "computer.place.thisMac",
  cloud: "computer.place.cloud",
  peer: "computer.place.peer",
};

/// Whole seconds since the phase began; never negative, none when the daemon sent no start.
export function elapsedSeconds(status: ComputerStatus, nowMs: number): number {
  return Math.max(0, Math.floor((nowMs - (status.phase_since_ms ?? nowMs)) / 1000));
}

function actions(t: Translate, ids: StatusActionId[]): StatusAction[] {
  return ids.map((id) => ({ id, label: t(ACTION_KEY[id]) }));
}

/// What the status line says and offers. Undefined while the chat simply runs where it is: the line
/// is empty then, and takes no room.
export function statusLine(status: ComputerStatus, nowMs: number, t: Translate): StatusLineText | undefined {
  const seconds = elapsedSeconds(status, nowMs);
  switch (status.phase) {
    case "running":
      return undefined;
    case "preparing":
      return { text: t("computer.status.preparing", { seconds }), actions: [] };
    case "moving": {
      const key = status.move?.direction === "to_mac" ? "computer.status.moveToMac" : "computer.status.moveToCloud";
      return { text: t(key, { seconds }), actions: status.move?.cancellable === false ? [] : actions(t, ["cancel"]) };
    }
    case "move_failed": {
      const failure = status.move?.failure;
      const parts = [t("computer.status.moveFailed")];
      if (failure) parts.push(t(FAILURE_KEY[failure]));
      parts.push(t("computer.status.stillOn", { place: t(PLACE_KEY[status.home]) }));
      return { text: parts.join(" · "), actions: actions(t, ["retry"]) };
    }
    case "reconnecting":
      return { text: t("computer.status.reconnecting"), actions: [] };
    case "sleeping":
      return { text: t("computer.status.sleeping"), actions: [] };
    case "paused_spend_cap":
      return { text: t("computer.status.pausedSpendCap"), actions: actions(t, ["raise_limit", "run_on_mac"]) };
    case "paused_pool_spent":
      return { text: t("computer.status.pausedPoolSpent"), actions: actions(t, ["upgrade", "run_on_mac"]) };
    case "staying_local_slots_full":
      return { text: t("computer.status.slotsFull"), actions: actions(t, ["pause_one", "upgrade"]) };
  }
}

/// The compact chip's one-word form: the text up to its first separator, so it never outgrows a pill.
export function statusChipText(line: StatusLineText): string {
  return line.text.split(" · ")[0] ?? line.text;
}

export type SizeRow = {
  auto: boolean;
  pinned: boolean;
  /// The size sentence; absent until the chat has a cloud computer (a pin alone still reads).
  note?: string;
};

/// The Size row: "now 2 vCPU · 4 GB, grows as it works" once there is a cloud computer, the pin when pinned.
export function sizeRow(status: ComputerStatus, t: Translate): SizeRow {
  if (status.size.mode === "pinned") {
    const { vcpu, memory_gib: memory } = status.size;
    return { auto: false, pinned: true, note: t("computer.size.pinned", { vcpu, memory }) };
  }
  const note = status.shape
    ? t("computer.size.now", { vcpu: status.shape.vcpu, memory: status.shape.memory_gib })
    : undefined;
  return { auto: true, pinned: false, ...(note ? { note } : {}) };
}

export type SleepRow = {
  mode: "auto" | "keep_awake";
  /// Which keep-awake length is running, when it is one of the offered two.
  note: string;
};

/// The Sleep row's note; `formatTime` renders a clock time (the app's locale in the page).
export function sleepRow(status: ComputerStatus, t: Translate, formatTime: (ms: number) => string): SleepRow {
  if (status.sleep.mode === "auto") return { mode: "auto", note: t("computer.sleep.autoNote") };
  const until = status.sleep.until_ms;
  return {
    mode: "keep_awake",
    note:
      until === undefined
        ? t("computer.sleep.keepForever")
        : t("computer.sleep.keepUntil", { time: formatTime(until) }),
  };
}

/// The Why row: one sentence in the person's terms, or none before AUTO has done anything.
export function whyRow(status: ComputerStatus, t: Translate, formatTime: (ms: number) => string): string | undefined {
  const why = status.why;
  if (!why) return undefined;
  const time = formatTime(why.at_ms);
  switch (why.reason) {
    case "grew_for_memory":
      return why.command
        ? t("computer.why.grew_for_command", { time, command: why.command })
        : t("computer.why.grew_for_memory", { time });
    case "person_moved":
      return t("computer.why.person_moved", { time, place: t(PLACE_KEY[status.home]) });
    case "mac_memory_pressure":
    case "mac_busy":
    case "lid_closed":
    case "slots_full":
    case "spend_cap":
      return t(`computer.why.${why.reason}`, { time });
  }
}
