/// The host's dictation update (`cmuxAcpmuxBridge.dictation`, Swift `AgentPaneDictation.payload`).
export type DictationState = "idle" | "starting" | "listening" | "finalizing" | "failed" | "denied";
export type DictationUpdate = {
  state: DictationState;
  /// The session's whole text so far: committed segments, then the live hypothesis.
  text: string;
  /// Input level, 0...1.
  level: number;
  /// The session was cancelled (Esc): drop its text.
  cancelled: boolean;
  permission?: "microphone" | "speechRecognition";
  message?: string;
  settingsLabel?: string;
};

/// Where one session's text sits in the prompt. The session owns `value[start, start + length)`;
/// everything around it is the user's.
export type DictationAnchor = {
  start: number;
  length: number;
  /// What the prompt read after the last splice; a different value means the user edited it.
  written: string;
  /// The selection the session replaced, put back on cancel.
  replaced: string;
  /// Session text that belongs to the user now (they edited mid-session); later updates add only
  /// what follows it, at the caret.
  consumed: number;
  /// How much session text the last splice placed.
  covered: number;
  /// The text follows a word (a space goes before it) or precedes one (a space goes after it).
  leadingSpace: boolean;
  trailingSpace: boolean;
};

export type PromptState = { value: string; selectionStart: number; selectionEnd: number };
export type Splice = { value: string; caret: number; anchor: DictationAnchor | null };

const startsWord = (text: string) => /^[^\s.,;:!?)\]}'"’”、。，．！？]/u.test(text);
const endsWord = (text: string) => /\S$/u.test(text);

/// Starts a session at the prompt's selection. The selection is replaced, like system dictation.
export function anchorAt(prompt: PromptState, consumed = 0): DictationAnchor {
  const start = Math.min(prompt.selectionStart, prompt.selectionEnd);
  const end = Math.max(prompt.selectionStart, prompt.selectionEnd);
  const before = prompt.value.slice(0, start);
  const after = prompt.value.slice(end);
  return {
    start, length: 0, written: before + after, replaced: prompt.value.slice(start, end), consumed, covered: consumed,
    leadingSpace: endsWord(before), trailingSpace: startsWord(after),
  };
}

/// Applies one update to the prompt. Returns null when the update changes nothing there.
export function applyDictation(prompt: PromptState, anchor: DictationAnchor | null, update: DictationUpdate): Splice | null {
  const active = update.state === "starting" || update.state === "listening" || update.state === "finalizing";
  if (!anchor) {
    if (!active || update.cancelled) return null;
    anchor = anchorAt(prompt);
  } else if (prompt.value !== anchor.written) {
    // The user typed or deleted mid-session: what is there is theirs. Later words go at the caret.
    anchor = anchorAt({ ...prompt, selectionEnd: prompt.selectionStart }, anchor.covered);
  }
  const own = update.text.slice(anchor.consumed).replace(/^\s+/u, "");
  // A cancel drops the text; a session that ends with no words (denied, failed) changes nothing.
  if (update.cancelled || (!active && !own && anchor.length === 0)) {
    const value = anchor.written.slice(0, anchor.start) + anchor.replaced + anchor.written.slice(anchor.start + anchor.length);
    return { value, caret: anchor.start + anchor.replaced.length, anchor: null };
  }
  const lead = own && anchor.leadingSpace && startsWord(own) ? " " : "";
  const trail = own && anchor.trailingSpace && endsWord(own) ? " " : "";
  const inserted = lead + own + trail;
  const value = anchor.written.slice(0, anchor.start) + inserted + anchor.written.slice(anchor.start + anchor.length);
  const caret = anchor.start + lead.length + own.length;
  return { value, caret, anchor: active ? { ...anchor, length: inserted.length, written: value, covered: update.text.length } : null };
}
