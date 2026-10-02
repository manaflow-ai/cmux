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
/// The prompt after an update: its value and selection, and the session's anchor (null once it ended).
export type Splice = { value: string; selectionStart: number; selectionEnd: number; anchor: DictationAnchor | null };

/// Scripts written without spaces between words: no space goes next to them.
const unspaced = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}、。，．！？「」『』（）]/u;
const startsWord = (text: string) => /^[^\s.,;:!?)\]}'"’”]/u.test(text) && !unspaced.test(text[0] ?? "");
const endsWord = (text: string) => /[^\s([{<"'‘“/\\@#-]$/u.test(text) && !unspaced.test(text.at(-1) ?? "");

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
  const fresh = !anchor;
  if (!anchor) {
    if (!active || update.cancelled) return null;
    anchor = anchorAt(prompt);
  } else if (prompt.value !== anchor.written) {
    // The user edited mid-session. An edit around the session's words moves them; one inside
    // them makes what is there theirs, and later words go at the caret.
    anchor = moved(anchor, prompt.value) ?? anchorAt({ ...prompt, selectionEnd: prompt.selectionStart }, anchor.covered);
  }
  const own = update.text.slice(anchor.consumed).replace(/^\s+/u, "");
  // A cancel drops the text; a session that ends with no words (denied, failed) changes nothing.
  if (update.cancelled || (!active && !own && anchor.length === 0)) {
    const value = anchor.written.slice(0, anchor.start) + anchor.replaced + anchor.written.slice(anchor.start + anchor.length);
    const caret = anchor.start + anchor.replaced.length;
    return { value, selectionStart: caret, selectionEnd: caret, anchor: null };
  }
  const lead = own && anchor.leadingSpace && startsWord(own) ? " " : "";
  const trail = own && anchor.trailingSpace && endsWord(own) ? " " : "";
  const inserted = lead + own + trail;
  const value = anchor.written.slice(0, anchor.start) + inserted + anchor.written.slice(anchor.start + anchor.length);
  // A caret at the session's words follows them; one the user moved elsewhere stays where they
  // put it, shifted if the words before it grew or shrank.
  const end = anchor.start + anchor.length;
  const following = fresh || (prompt.selectionStart === prompt.selectionEnd
    && prompt.selectionStart > anchor.start - (anchor.length === 0 ? 1 : 0) && prompt.selectionStart <= end);
  const shift = (position: number) => (position >= end ? position + inserted.length - anchor.length : position);
  const caret = anchor.start + lead.length + own.length;
  return {
    value,
    selectionStart: following ? caret : shift(prompt.selectionStart),
    selectionEnd: following ? caret : shift(prompt.selectionEnd),
    anchor: active ? { ...anchor, length: inserted.length, written: value, covered: update.text.length } : null,
  };
}

/// The anchor after an edit that left the session's words intact (typed before or after them).
function moved(anchor: DictationAnchor, value: string): DictationAnchor | null {
  const owned = anchor.written.slice(anchor.start, anchor.start + anchor.length);
  const before = anchor.written.slice(0, anchor.start);
  const after = anchor.written.slice(anchor.start + anchor.length);
  // Typed after the words: everything up to their end is unchanged.
  if (value.startsWith(before + owned)) return { ...anchor, written: value };
  // Typed before them: everything from their start is unchanged.
  if (value.endsWith(owned + after)) return { ...anchor, start: value.length - owned.length - after.length, written: value };
  return null;
}
