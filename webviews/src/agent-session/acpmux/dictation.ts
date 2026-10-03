import type React from "react";
import { useEffect, useRef, useState } from "react";
import { applyDictation, type DictationAnchor, type DictationState, type DictationUpdate } from "./dictationText";
import type { MarkdownFieldHandle } from "./MarkdownField";
import { t } from "./i18n";
import { NativeError } from "./nativeError";

/// Native dictation for the composer. Swift owns the microphone and speech engine
/// (CmuxNextAgentPane `AgentPaneDictation`); this splices its text at the prompt's cursor,
/// keeps what the user typed, and drives the mic button (DictationButton). While idle nothing
/// runs: no timer, no key listener, only the bridge hook and passive composition listeners.

type Call = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

const listeners = new Set<(update: DictationUpdate) => void>();
/// The host's `cmuxAcpmuxBridge.dictation(update)`. The waveform takes one sample per update,
/// however many composers listen.
export function deliverDictation(update: DictationUpdate): void {
  setLevel(update.level, isActive(update.state));
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
export const subscribeLevel = (listener: () => void) => {
  level.listeners.add(listener);
  return () => {
    level.listeners.delete(listener);
  };
};
export const readLevel = () => level.samples;

export const isActive = (state: DictationState) =>
  state === "starting" || state === "listening" || state === "finalizing";

export type Dictation = {
  state: DictationState;
  /// The denied or failed state the composer shows until dismissed or the next start.
  notice: DictationUpdate | null;
  toggle(): void;
  cancel(): void;
  openSettings(): void;
  dismiss(): void;
};

/// Dictation into the composer's prompt, which `prompt` holds once the composer mounts.
export function useDictation(prompt: React.RefObject<MarkdownFieldHandle | null>, call: Call): Dictation {
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
      const field = prompt.current;
      if (!field) return;
      if (applied && applied.state === update.state && applied.text === update.text && !update.cancelled) return;
      applied = isActive(update.state) ? update : null;
      // A session the shortcut started writes where the user will type, as undoable edits.
      if (update.state === "starting" && document.hasFocus() && !field.focused()) field.focus();
      const splice = applyDictation(field.text(), anchor.current, update);
      if (!splice) return;
      anchor.current = splice.anchor;
      field.writeText(splice.value, splice.selectionStart, splice.selectionEnd);
      // Submit on the next task, once the composer's state holds the dictated text.
      if (update.state === "idle" && !update.cancelled && autoSend && splice.placed)
        setTimeout(() => field.element()?.closest("form")?.requestSubmit(), 0);
    };
    const receive = (update: DictationUpdate) => {
      requested.current = false;
      setState(update.state);
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
    // The composer mounts and unmounts with the pane's state, so composition is heard where it
    // passes on its way to the prompt: in the capture phase, from the prompt's field only.
    const inPrompt = (event: Event) => {
      const element = prompt.current?.element();
      return !!element && event.target instanceof Node && element.contains(event.target);
    };
    const compositionStart = (event: Event) => {
      if (inPrompt(event)) composing = true;
    };
    const compositionEnd = (event: Event) => {
      if (!inPrompt(event)) return;
      composing = false;
      const queue = pending.current;
      pending.current = [];
      for (const update of queue) apply(update);
    };
    document.addEventListener("compositionstart", compositionStart, true);
    document.addEventListener("compositionend", compositionEnd, true);
    listeners.add(receive);
    return () => {
      listeners.delete(receive);
      document.removeEventListener("compositionstart", compositionStart, true);
      document.removeEventListener("compositionend", compositionEnd, true);
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
          // A page with no host to ask says so plainly rather than "Request failed".
          message:
            error instanceof Error &&
            error.message &&
            !(error instanceof NativeError && error.code === "native.not_connected")
              ? error.message
              : t("dictation.unavailable"),
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
