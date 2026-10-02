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
  /// Session text that is the user's now (they edited inside it mid-session); later updates add
  /// only what comes after it.
  handed: string;
  /// The session text the last splice placed.
  seen: string;
  /// The text follows a word (a space goes before it) or precedes one (a space goes after it).
  leadingSpace: boolean;
  trailingSpace: boolean;
};

export type PromptState = { value: string; selectionStart: number; selectionEnd: number };
/// The prompt after an update: its value and selection, the session's anchor (null once it
/// ended), and whether this update put session words in the prompt.
export type Splice = { value: string; selectionStart: number; selectionEnd: number; anchor: DictationAnchor | null; placed: boolean };

/// Scripts written without spaces between words: no space goes next to them.
const unspaced = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}、。，．！？「」『』（）]/u;
const startsWord = (text: string) => /^[^\s.,;:!?)\]}'"’”]/u.test(text) && !unspaced.test(text[0] ?? "");
const endsWord = (text: string) => /[^\s([{<"'‘“/\\@#-]$/u.test(text) && !unspaced.test(text.at(-1) ?? "");
const wordChar = /[\p{L}\p{N}]/u;

/// Starts a session at the prompt's selection. The selection is replaced, like system dictation.
export function anchorAt(prompt: PromptState, handed = ""): DictationAnchor {
  const start = Math.min(prompt.selectionStart, prompt.selectionEnd);
  const end = Math.max(prompt.selectionStart, prompt.selectionEnd);
  const before = prompt.value.slice(0, start);
  const after = prompt.value.slice(end);
  return {
    start, length: 0, written: before + after, replaced: prompt.value.slice(start, end), handed, seen: handed,
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
    // them makes what is there theirs.
    anchor = moved(anchor, prompt.value) ?? handOver(anchor, prompt);
  }
  const { rest, glued } = remainder(update.text, anchor.handed);
  const own = glued ? rest : rest.replace(/^\s+/u, "");
  const keep = { selectionStart: prompt.selectionStart, selectionEnd: prompt.selectionEnd };
  // A cancel drops the text; a session that ends with no words (denied, failed, or nothing new
  // after the user took the words over) leaves the prompt and its selection alone.
  if (update.cancelled || (!active && !own && anchor.length === 0)) {
    if (!update.cancelled && !anchor.replaced) return { value: prompt.value, ...keep, anchor: null, placed: false };
    const value = anchor.written.slice(0, anchor.start) + anchor.replaced + anchor.written.slice(anchor.start + anchor.length);
    const caret = anchor.start + anchor.replaced.length;
    return { value, selectionStart: caret, selectionEnd: caret, anchor: null, placed: false };
  }
  const lead = own && !glued && anchor.leadingSpace && startsWord(own) ? " " : "";
  const trail = own && anchor.trailingSpace && endsWord(own) ? " " : "";
  const inserted = lead + own + trail;
  const value = anchor.written.slice(0, anchor.start) + inserted + anchor.written.slice(anchor.start + anchor.length);
  // A caret at the end of the session's words follows them; one the user put anywhere else, even
  // inside the words, stays there, shifted if the words before it grew or shrank.
  const end = anchor.start + anchor.length;
  const following = fresh || (prompt.selectionStart === prompt.selectionEnd && prompt.selectionStart === end);
  const shift = (position: number) => (position >= end ? position + inserted.length - anchor.length : position);
  const caret = anchor.start + lead.length + own.length;
  return {
    value,
    selectionStart: following ? caret : shift(prompt.selectionStart),
    selectionEnd: following ? caret : shift(prompt.selectionEnd),
    anchor: active ? { ...anchor, length: inserted.length, written: value, seen: update.text } : null,
    placed: own.length > 0,
  };
}

/// The session text past what the user took over. A word the engine was still spelling when they
/// took it continues it (`glued`); when the engine revises words they already have, theirs stay and
/// only the words past them are new.
function remainder(text: string, handed: string): { rest: string; glued: boolean } {
  if (!handed) return { rest: text, glued: false };
  if (text.startsWith(handed)) {
    const rest = text.slice(handed.length);
    return { rest, glued: wordChar.test(handed.at(-1) ?? "") && wordChar.test(rest[0] ?? "") };
  }
  if (unspaced.test(handed) || unspaced.test(text)) return { rest: text.slice(handed.length), glued: false };
  const words = handed.trim().split(/\s+/u).length;
  return { rest: text.trim().split(/\s+/u).slice(words).join(" "), glued: false };
}

/// The anchor after an edit that left the session's words intact (typed before or after them).
function moved(anchor: DictationAnchor, value: string): DictationAnchor | null {
  // No words yet: where typing went is ambiguous; the hand-over puts later words after it.
  if (anchor.length === 0) return null;
  const owned = anchor.written.slice(anchor.start, anchor.start + anchor.length);
  const before = anchor.written.slice(0, anchor.start);
  const after = anchor.written.slice(anchor.start + anchor.length);
  // Typed after the words: everything up to their end is unchanged.
  if (value.startsWith(before + owned)) return { ...anchor, written: value };
  // Typed before them: everything from their start is unchanged.
  if (value.endsWith(owned + after)) return { ...anchor, start: value.length - owned.length - after.length, written: value };
  return null;
}

/// An edit inside the session's words: what is there now is the user's, and later words go where
/// the session's words ended, or at the caret when the edit reached past them.
function handOver(anchor: DictationAnchor, prompt: PromptState): DictationAnchor {
  const before = anchor.written.slice(0, anchor.start);
  const after = anchor.written.slice(anchor.start + anchor.length);
  const value = prompt.value;
  const intact = value.length >= before.length + after.length && value.startsWith(before) && value.endsWith(after);
  let at = intact ? value.length - after.length : prompt.selectionStart;
  // The space the session put before the following word stays after the new words.
  if (intact && anchor.trailingSpace && anchor.length > 0 && value[at - 1] === " ") at -= 1;
  return anchorAt({ value, selectionStart: at, selectionEnd: at }, anchor.seen);
}
