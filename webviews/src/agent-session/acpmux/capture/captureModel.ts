// The capture bar's state (CaptureBar.tsx; plans/cmux-next/capture-bar-DESIGN.md). Leo, 2026-11-07:
// "could we also have a more native screenshot/screensharer (ergonomic one)/video recording of the
// app type thing/route?" One shortcut opens the bar on the chat the person is working in; a click on
// a target takes the screenshot, Record films the cmux window, and what it makes goes to the chat's
// composer, the clipboard, or a file. The pixels are the host's (AgentPaneCapture.swift); the
// choices, the recording's state and where the result goes are here.

/// What a screenshot takes: a region the person drags, a window they click (macOS's own pick), the
/// pane that was focused when the bar opened, or the whole cmux window.
export type CaptureTarget = "screen" | "window" | "pane" | "app";
export const CAPTURE_TARGETS: readonly CaptureTarget[] = ["screen", "window", "pane", "app"];

/// Where a capture goes: the chat's composer (the default), the clipboard, or a file.
export type CaptureDestination = "chat" | "copy" | "save";
export const CAPTURE_DESTINATIONS: readonly CaptureDestination[] = ["chat", "copy", "save"];

/// What the bar is doing.
export type CapturePhase =
  | { kind: "closed" }
  | { kind: "open" }
  /// A screenshot pick or a recording start is out with the host; the bar's buttons wait.
  | { kind: "busy"; what: CaptureTarget | "record" }
  /// Recording since `startedAt` (the page's clock, ms).
  | { kind: "recording"; startedAt: number }
  /// The recording is being written; its result goes where the destination says.
  | { kind: "finishing" };

export type CaptureState = {
  phase: CapturePhase;
  destination: CaptureDestination;
  /// A recording draws the pointer, and rings each click.
  cursor: boolean;
  clicks: boolean;
};

export const INITIAL_CAPTURE: CaptureState = {
  phase: { kind: "closed" },
  destination: "chat",
  cursor: true,
  clicks: true,
};

/// The longest recording, in seconds; the host stops one by itself then (AgentPaneRecord.maxSeconds).
export const MAX_RECORDING_SECONDS = 300;

export type CaptureEvent =
  /// The shortcut or the menu item: opens a closed bar, closes an open one, stops a recording.
  | { type: "toggle" }
  | { type: "close" }
  | { type: "destination"; destination: CaptureDestination }
  | { type: "option"; option: "cursor" | "clicks"; on: boolean }
  | { type: "begin"; what: CaptureTarget | "record" }
  | { type: "recording"; at: number }
  | { type: "stop" }
  /// The host answered (a shot taken or cancelled, a recording written or failed).
  | { type: "done" };

/// What a toggle means now: open, close, or stop the recording that runs.
export function toggleMeaning(phase: CapturePhase): "open" | "close" | "stop" | "wait" {
  switch (phase.kind) {
    case "closed":
      return "open";
    case "open":
      return "close";
    case "recording":
      return "stop";
    default:
      return "wait";
  }
}

export function captureReducer(state: CaptureState, event: CaptureEvent): CaptureState {
  const { phase } = state;
  switch (event.type) {
    case "toggle": {
      const meaning = toggleMeaning(phase);
      if (meaning === "open") return { ...state, phase: { kind: "open" } };
      if (meaning === "close") return { ...state, phase: { kind: "closed" } };
      if (meaning === "stop") return { ...state, phase: { kind: "finishing" } };
      return state;
    }
    case "close":
      // A recording ends only through Stop: closing never drops what was filmed.
      return phase.kind === "open" ? { ...state, phase: { kind: "closed" } } : state;
    case "destination":
      return state.destination === event.destination ? state : { ...state, destination: event.destination };
    case "option":
      return state[event.option] === event.on ? state : { ...state, [event.option]: event.on };
    case "begin":
      return phase.kind === "open" ? { ...state, phase: { kind: "busy", what: event.what } } : state;
    case "recording":
      return phase.kind === "busy" && phase.what === "record"
        ? { ...state, phase: { kind: "recording", startedAt: event.at } }
        : state;
    case "stop":
      return phase.kind === "recording" ? { ...state, phase: { kind: "finishing" } } : state;
    case "done":
      // A screenshot taken (or cancelled) or a recording delivered closes the bar: one shortcut,
      // one capture, back to the chat. A failed start leaves it open to try again (`reopen`).
      return phase.kind === "closed" ? state : { ...state, phase: { kind: "closed" } };
  }
}

/// After a failed start the bar stays open with its choices.
export function reopen(state: CaptureState): CaptureState {
  return { ...state, phase: { kind: "open" } };
}

/// A recording's length as the bar shows it: `m:ss`.
export function elapsedLabel(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/// The host's answer to `capture.record.stop`, checked: the movie's path, name and length.
export type Recording = { path: string; name: string; seconds: number };
export function parseRecording(value: unknown): Recording | undefined {
  if (!value || typeof value !== "object") return undefined;
  const { path, name, seconds } = value as Record<string, unknown>;
  if (typeof path !== "string" || !path.startsWith("/") || !/\.(mp4|mov)$/i.test(path)) return undefined;
  return {
    path,
    name: typeof name === "string" && name.trim() ? name : path.slice(path.lastIndexOf("/") + 1),
    seconds: typeof seconds === "number" && Number.isFinite(seconds) && seconds > 0 ? seconds : 0,
  };
}
