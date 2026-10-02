import React, { useEffect, useRef, useState } from "react";
import { applyDictation, type DictationAnchor, type DictationState, type DictationUpdate } from "./dictationText";

/// Native dictation for the composer. Swift owns the microphone and speech engine
/// (CmuxNextAgentPane `AgentPaneDictation`); this splices its text at the prompt's cursor,
/// keeps what the user typed, and draws the mic button. System dictation (Fn Fn) is untouched:
/// the prompt stays a plain textarea and nothing here listens while idle.

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

const isActive = (state: DictationState) => state === "starting" || state === "listening" || state === "finalizing";

/// Writes the prompt the way typing does, so React and anything listening for input see it.
function writePrompt(node: HTMLTextAreaElement, value: string): void {
  if (node.value === value) return;
  const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(node), "value")?.set;
  if (setter) setter.call(node, value);
  else node.value = value;
  node.dispatchEvent(new Event("input", { bubbles: true }));
}

export type Dictation = {
  state: DictationState;
  level: number;
  /// The denied or failed state the composer shows until dismissed or the next start.
  notice: DictationUpdate | null;
  toggle(): void;
  cancel(): void;
  openSettings(): void;
  dismiss(): void;
};

export function useDictation(prompt: React.RefObject<HTMLTextAreaElement | null>, call: Call): Dictation {
  const [state, setState] = useState<DictationState>("idle");
  const [level, setLevel] = useState(0);
  const [notice, setNotice] = useState<DictationUpdate | null>(null);
  const anchor = useRef<DictationAnchor | null>(null);

  useEffect(() => {
    const receive = (update: DictationUpdate) => {
      setState(update.state);
      setLevel(isActive(update.state) ? update.level : 0);
      if (update.state === "failed" || update.state === "denied") setNotice(update);
      else if (update.state === "starting") setNotice(null);
      const node = prompt.current;
      if (!node) return;
      const splice = applyDictation({ value: node.value, selectionStart: node.selectionStart, selectionEnd: node.selectionEnd }, anchor.current, update);
      if (!splice) return;
      anchor.current = splice.anchor;
      writePrompt(node, splice.value);
      node.setSelectionRange(splice.caret, splice.caret);
      if (update.state === "idle" && !update.cancelled && autoSend && update.text.trim()) node.form?.requestSubmit();
    };
    listeners.add(receive);
    return () => { listeners.delete(receive); };
  }, [prompt]);

  // Esc cancels, only while a session runs; idle composers keep every key.
  const active = isActive(state);
  useEffect(() => {
    if (!active) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
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
  useEffect(() => () => { if (isActive(latest.current)) void call("dictation.cancel").catch(() => {}); }, [call]);

  return {
    state,
    level,
    notice,
    toggle() {
      if (!active) prompt.current?.focus();
      void call("dictation.toggle").catch(() => setNotice({ state: "failed", text: "", level: 0, cancelled: false, message: "Dictation is not available in this build." }));
    },
    cancel() { void call("dictation.cancel").catch(() => {}); },
    openSettings() { if (notice?.permission) void call("dictation.openSettings", { permission: notice.permission }).catch(() => {}); },
    dismiss() { setNotice(null); },
  };
}

const METER_BARS = [0.55, 0.85, 1, 0.7];

/// The mic next to Send: a microphone while idle, a live level meter while listening.
export function DictationButton({ dictation }: { dictation: Dictation }) {
  const { state, level } = dictation;
  const listening = state === "listening" || state === "finalizing";
  const label = isActive(state) ? "Stop dictation" : "Dictate";
  return <button
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
    {listening
      ? <span className="acpmux-mic-meter" aria-hidden="true">{METER_BARS.map((weight, index) => <span key={index} style={{ transform: `scaleY(${Math.max(0.18, Math.min(1, level * weight * 1.4))})` }} />)}</span>
      : <svg aria-hidden="true" viewBox="0 0 16 16" width="16" height="16"><rect x="5.5" y="1.5" width="5" height="8.5" rx="2.5" fill="none" stroke="currentColor" strokeWidth="1.4" /><path d="M3 7.5a5 5 0 0 0 10 0M8 12.5V15" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" /></svg>}
  </button>;
}

/// Why dictation did not run, with a way to fix it.
export function DictationNotice({ dictation }: { dictation: Dictation }) {
  const notice = dictation.notice;
  if (!notice?.message) return null;
  return <div className="acpmux-dictation-notice" role="alert">
    <span>{notice.message}</span>
    {notice.state === "denied" && notice.permission && <button type="button" onClick={dictation.openSettings}>{notice.settingsLabel ?? "Open System Settings"}</button>}
    <button type="button" className="acpmux-dictation-dismiss" aria-label="Dismiss" onClick={dictation.dismiss}>×</button>
  </div>;
}
