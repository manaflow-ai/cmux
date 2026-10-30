import type React from "react";
import { useEffect, useRef, useState } from "react";
import {
  applyDictation,
  type DictationAnchor,
  type DictationRecording,
  type DictationState,
  type DictationUpdate,
} from "./dictationText";
import type { MarkdownFieldHandle } from "./MarkdownField";
import { useT } from "./i18n";
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
/// words. Off by default: dictated text waits for the user. The host gates it, not this page:
/// every session/prompt needs a real key or click in the pane within 30 s (AgentPaneUserGestures),
/// which page script cannot make. A session the user stops in the pane (the mic, or its shortcut
/// while the pane has focus) sends. One that ends by itself (sleep, the engine, a push-to-talk hold
/// past 30 s) or from the palette, a menu or the CLI is refused, and its prompt stays in the
/// composer with "Not sent. Send it again." (cx-w2p8r).
export function configureDictation(layout: Record<string, unknown> | undefined): void {
  const dictation = layout?.dictation as { autoSend?: unknown } | undefined;
  autoSend = dictation?.autoSend === true;
}

/// The last few input levels, oldest first, read only by the waveform beside the mic
/// (DictationWave): it moves about 12 times a second without re-rendering the pane.
const WAVE_BARS = 11;
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

/// A session is starting or listening, with no words to show yet: the prompt it writes into says
/// "Listening…" (italic, as Claude's does) while empty. Composers read it from their pane's
/// dictation (App.tsx passes `dictating`), not from page-wide state.
export const isWaitingForWords = (state: DictationState) => state === "starting" || state === "listening";

export const isActive = (state: DictationState) =>
  state === "starting" || state === "listening" || state === "finalizing";

export type Dictation = {
  state: DictationState;
  /// The denied or failed state the composer shows until dismissed or the next start.
  notice: DictationUpdate | null;
  toggle(): void;
  /// Ends the session and keeps its words (the finish key beside the waveform).
  finish(): void;
  cancel(): void;
  openSettings(): void;
  dismiss(): void;
};

/// What dictation drives a prompt with: the composer's Markdown field, or a plain field (the New
/// Tab page's) that sends with `submit` (it is in no form).
export type DictationField = Pick<MarkdownFieldHandle, "focus" | "text" | "writeText" | "focused" | "element"> & {
  submit?(): void;
};

/// Voice input for a harness that takes it. While `accepts` (the chat's ACP
/// `promptCapabilities.audio`), the host keeps each session's audio (`dictation.audio`), and the
/// session's last update hands it to `attach` before its words land, so the recording goes with
/// the prompt the transcript is in, or tells `omitted` why it was left out. Otherwise the session
/// is dictation alone.
export type DictationAudio = {
  accepts: boolean;
  chat?(): string | undefined;
  elsewhere?(): void;
  attach(audio: DictationRecording): void;
  omitted(reason: NonNullable<DictationUpdate["audioOmitted"]>): void;
};

/// Dictation into the composer's prompt, which `prompt` holds once the composer mounts.
export function useDictation(
  prompt: React.RefObject<DictationField | null>,
  call: Call,
  audio?: DictationAudio,
): Dictation {
  const t = useT();
  const [state, setState] = useState<DictationState>("idle");
  const [notice, setNotice] = useState<DictationUpdate | null>(null);
  const anchor = useRef<DictationAnchor | null>(null);
  /// Updates that arrived while an input method was composing; applied in order when it ends, so
  /// a splice never breaks the user's composition. Level-only repeats replace the last one.
  const pending = useRef<DictationUpdate[]>([]);
  /// A toggle went to the host and no update came back yet.
  const requested = useRef(false);
  const attachAudio = useRef(audio?.attach);
  attachAudio.current = audio?.attach;
  const omitAudio = useRef(audio?.omitted);
  omitAudio.current = audio?.omitted;
  const shownChat = useRef(audio?.chat);
  shownChat.current = audio?.chat;
  const audioElsewhere = useRef(audio?.elsewhere);
  audioElsewhere.current = audio?.elsewhere;
  const acceptsAudio = audio?.accepts === true;
  /// A session that ends after the chat moved to a harness without audio keeps its words only.
  const acceptsAudioNow = useRef(acceptsAudio);
  acceptsAudioNow.current = acceptsAudio;

  // The host decides for every start (the mic, its shortcut, the palette), so it hears each change.
  useEffect(() => {
    void call("dictation.audio", { enabled: acceptsAudio }).catch(() => {});
  }, [acceptsAudio, call]);

  useEffect(() => {
    let composing = false;
    /// The last update spliced; a repeat (a level-only tick) leaves the prompt and caret alone.
    let applied: DictationUpdate | null = null;
    /// The field element the session writes into.
    let owner: Element | null = null;
    const apply = (update: DictationUpdate) => {
      const field = prompt.current;
      if (!field) return;
      // The session's field went away (New Tab became the chat): its words and offsets belong to
      // that field, so the session ends rather than splicing into, or sending, another one.
      if (anchor.current && owner && owner !== field.element()) {
        anchor.current = null;
        applied = null;
        owner = null;
        if (isActive(update.state)) void call("dictation.cancel").catch(() => {});
        return;
      }
      if (applied && applied.state === update.state && applied.text === update.text && !update.cancelled) return;
      applied = isActive(update.state) ? update : null;
      // The final recording and transcript belong to the chat where recording began.
      // Never splice or auto-send either into a chat the pane navigated to while closing.
      if (update.session !== undefined && shownChat.current && update.session !== (shownChat.current() ?? "")) {
        anchor.current = null;
        owner = null;
        if (update.state === "idle" && !update.cancelled) audioElsewhere.current?.();
        return;
      }
      // The recording joins the composer before the words do, so an auto-send takes both.
      if (update.state === "idle" && !update.cancelled && acceptsAudioNow.current) {
        if (update.audio) attachAudio.current?.(update.audio);
        else if (update.audioOmitted) omitAudio.current?.(update.audioOmitted);
      }
      // A session the shortcut started writes where the user will type, as undoable edits.
      if (update.state === "starting" && document.hasFocus() && !field.focused()) field.focus();
      const splice = applyDictation(field.text(), anchor.current, update);
      if (!splice) return;
      anchor.current = splice.anchor;
      owner = splice.anchor ? field.element() : null;
      field.writeText(splice.value, splice.selectionStart, splice.selectionEnd);
      // Submit on the next task, once the composer's state holds the dictated text.
      if (update.state === "idle" && !update.cancelled && autoSend && splice.placed)
        setTimeout(() => (field.submit ? field.submit() : field.element()?.closest("form")?.requestSubmit()), 0);
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
  }, [prompt, call]);

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
    finish() {
      // The finish key goes away with the session: the keyboard returns to the prompt, where the words are.
      prompt.current?.focus();
      void call("dictation.stop").catch(() => {});
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
