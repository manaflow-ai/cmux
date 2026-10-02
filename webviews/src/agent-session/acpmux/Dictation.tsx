import React, { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { applyDictation, type DictationAnchor, type DictationState, type DictationUpdate } from "./dictationText";

/// Native dictation for the composer. Swift owns the microphone and speech engine
/// (CmuxNextAgentPane `AgentPaneDictation`); this splices its text at the prompt's cursor,
/// keeps what the user typed, and draws the mic button. System dictation (Fn Fn) is untouched:
/// the prompt stays a plain textarea. While idle nothing runs: no timer, no key listener, only
/// the bridge hook and the prompt's passive composition listeners.

type Call = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

const listeners = new Set<(update: DictationUpdate) => void>();
/// The host's `cmuxAcpmuxBridge.dictation(update)`.
export function deliverDictation(update: DictationUpdate): void {
  for (const listener of listeners) listener(update);
}

let autoSend = false;
/// `layout.json` `{"dictation": {"autoSend": true}}` sends the prompt when a session ends with
/// words. Off by default: dictated text waits for the user.
export function configureDictation(layout: Record<string, unknown> | undefined): void {
  const dictation = layout?.dictation as { autoSend?: unknown } | undefined;
  autoSend = dictation?.autoSend === true;
}

/// The last few input levels, oldest first, read only by the mic button's waveform: it moves
/// about 12 times a second without re-rendering the pane.
const WAVE_BARS = 5;
const silence: readonly number[] = Array(WAVE_BARS).fill(0);
const level = { samples: silence, listeners: new Set<() => void>() };
/// Adds the latest level while a session runs; anything else clears the waveform.
function setLevel(value: number, active: boolean): void {
  if (!active && level.samples === silence) return;
  level.samples = active ? [...level.samples.slice(1), value] : silence;
  for (const listener of level.listeners) listener();
}
const subscribeLevel = (listener: () => void) => {
  level.listeners.add(listener);
  return () => {
    level.listeners.delete(listener);
  };
};
const readLevel = () => level.samples;

const isActive = (state: DictationState) => state === "starting" || state === "listening" || state === "finalizing";

/// Writes the prompt the way typing does: as one undoable edit of the changed span when the
/// prompt has focus, so Cmd-Z works, and an input event either way.
function writePrompt(node: HTMLTextAreaElement, value: string): void {
  const old = node.value;
  if (old === value) return;
  let head = 0;
  while (head < old.length && head < value.length && old[head] === value[head]) head += 1;
  let tail = 0;
  while (
    tail < old.length - head &&
    tail < value.length - head &&
    old[old.length - 1 - tail] === value[value.length - 1 - tail]
  )
    tail += 1;
  if (node.ownerDocument.activeElement === node && typeof node.ownerDocument.execCommand === "function") {
    node.setSelectionRange(head, old.length - tail);
    const inserted = value.slice(head, value.length - tail);
    const done = inserted
      ? node.ownerDocument.execCommand("insertText", false, inserted)
      : node.ownerDocument.execCommand("delete");
    if (done && node.value === value) return;
  }
  const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(node), "value")?.set;
  if (setter) setter.call(node, value);
  else node.value = value;
  node.dispatchEvent(new Event("input", { bubbles: true }));
}

export type Dictation = {
  state: DictationState;
  /// The denied or failed state the composer shows until dismissed or the next start.
  notice: DictationUpdate | null;
  toggle(): void;
  cancel(): void;
  openSettings(): void;
  dismiss(): void;
};

export function useDictation(prompt: React.RefObject<HTMLTextAreaElement | null>, call: Call): Dictation {
  const [state, setState] = useState<DictationState>("idle");
  const [notice, setNotice] = useState<DictationUpdate | null>(null);
  const anchor = useRef<DictationAnchor | null>(null);
  /// Updates that arrived while an input method was composing; applied in order when it ends, so
  /// a splice never breaks the user's composition. Level-only repeats replace the last one.
  const pending = useRef<DictationUpdate[]>([]);
  /// A toggle went to the host and no update came back yet.
  const requested = useRef(false);

  useEffect(() => {
    let composing = false;
    /// The last update spliced; a repeat (a level-only tick) leaves the prompt and caret alone.
    let applied: DictationUpdate | null = null;
    const apply = (update: DictationUpdate) => {
      const node = prompt.current;
      if (!node) return;
      if (applied && applied.state === update.state && applied.text === update.text && !update.cancelled) return;
      applied = isActive(update.state) ? update : null;
      // A session the shortcut started writes where the user will type, as undoable edits.
      if (update.state === "starting" && node.ownerDocument.hasFocus() && node.ownerDocument.activeElement !== node)
        node.focus();
      const splice = applyDictation(
        { value: node.value, selectionStart: node.selectionStart, selectionEnd: node.selectionEnd },
        anchor.current,
        update,
      );
      if (!splice) return;
      anchor.current = splice.anchor;
      writePrompt(node, splice.value);
      node.setSelectionRange(splice.selectionStart, splice.selectionEnd);
      // Submit on the next task, once the composer's state holds the dictated text.
      if (update.state === "idle" && !update.cancelled && autoSend && splice.placed)
        setTimeout(() => node.form?.requestSubmit(), 0);
    };
    const receive = (update: DictationUpdate) => {
      requested.current = false;
      setState(update.state);
      setLevel(update.level, isActive(update.state));
      if (update.state === "failed" || update.state === "denied") setNotice(update);
      else if (update.state === "starting") setNotice(null);
      if (!composing) apply(update);
      else {
        const queue = pending.current;
        const last = queue.at(-1);
        if (last && isActive(last.state) && last.state === update.state && !update.cancelled)
          queue[queue.length - 1] = update;
        else queue.push(update);
      }
    };
    const node = prompt.current;
    const compositionStart = () => {
      composing = true;
    };
    const compositionEnd = () => {
      composing = false;
      const queue = pending.current;
      pending.current = [];
      for (const update of queue) apply(update);
    };
    node?.addEventListener("compositionstart", compositionStart);
    node?.addEventListener("compositionend", compositionEnd);
    listeners.add(receive);
    return () => {
      listeners.delete(receive);
      node?.removeEventListener("compositionstart", compositionStart);
      node?.removeEventListener("compositionend", compositionEnd);
    };
  }, [prompt]);

  // Esc cancels, only while a session runs; idle composers keep every key.
  const active = isActive(state);
  useEffect(() => {
    if (!active) return;
    const onKey = (event: KeyboardEvent) => {
      // Esc that closes an input method's candidates is the input method's.
      if (event.key !== "Escape" || event.isComposing || event.keyCode === 229) return;
      event.preventDefault();
      event.stopPropagation();
      void call("dictation.cancel").catch(() => {});
    };
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [active, call]);

  // A closed composer must not leave the microphone on.
  const latest = useRef(state);
  latest.current = state;
  useEffect(
    () => () => {
      if (isActive(latest.current) || requested.current) void call("dictation.cancel").catch(() => {});
    },
    [call],
  );

  return {
    state,
    notice,
    toggle() {
      if (!active) prompt.current?.focus();
      requested.current = true;
      void call("dictation.toggle").catch((error: unknown) => {
        requested.current = false;
        setNotice({
          state: "failed",
          text: "",
          level: 0,
          cancelled: false,
          message: error instanceof Error && error.message ? error.message : "Dictation is not available.",
        });
      });
    },
    cancel() {
      void call("dictation.cancel").catch(() => {});
    },
    openSettings() {
      if (notice?.permission) void call("dictation.openSettings", { permission: notice.permission }).catch(() => {});
    },
    dismiss() {
      setNotice(null);
    },
  };
}

/// The mic next to Send: a microphone while idle, a live waveform while listening.
export function DictationButton({ dictation }: { dictation: Dictation }) {
  const { state } = dictation;
  const listening = state === "listening" || state === "finalizing";
  const label = isActive(state) ? "Stop dictation" : "Dictate";
  return (
    <button
      type="button"
      className="acpmux-mic"
      data-state={state}
      aria-label={label}
      aria-pressed={isActive(state)}
      title={label}
      // Keep focus and the selection in the prompt: that is where the words go.
      onMouseDown={(event) => event.preventDefault()}
      onClick={dictation.toggle}
    >
      {listening ? (
        <LevelMeter />
      ) : (
        <svg aria-hidden="true" viewBox="0 0 16 16" width="18" height="18">
          <rect x="5.5" y="1.5" width="5" height="8.5" rx="2.5" fill="none" stroke="currentColor" strokeWidth="1.4" />
          <path
            d="M3 7.5a5 5 0 0 0 10 0M8 12.5V15"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.4"
            strokeLinecap="round"
          />
        </svg>
      )}
    </button>
  );
}

/// The recent input levels as bars, newest on the right.
function LevelMeter() {
  const samples = useSyncExternalStore(subscribeLevel, readLevel);
  return (
    <span className="acpmux-mic-meter" aria-hidden="true">
      {samples.map((sample, index) => (
        <span key={index} style={{ transform: `scaleY(${Math.max(0.18, Math.min(1, sample * 1.4))})` }} />
      ))}
    </span>
  );
}

/// Why dictation did not run, with a way to fix it.
export function DictationNotice({ dictation }: { dictation: Dictation }) {
  const notice = dictation.notice;
  if (!notice?.message) return null;
  return (
    <div className="acpmux-dictation-notice" role="alert">
      <span>{notice.message}</span>
      {notice.state === "denied" && notice.permission && (
        <button type="button" onClick={dictation.openSettings}>
          {notice.settingsLabel ?? "Open System Settings"}
        </button>
      )}
      <button type="button" className="acpmux-dictation-dismiss" aria-label="Dismiss" onClick={dictation.dismiss}>
        ×
      </button>
    </div>
  );
}
