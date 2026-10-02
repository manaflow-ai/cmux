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
  /// The space the session added after its words, before the next word (0 or 1); the caret sits before it.
  tail: number;
  /// The prompt before the anchor still ends with the half-spelled word `handed` ends in, so the
  /// engine's continuation of that word joins it.
  continues: boolean;
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
    start, length: 0, written: before + after, replaced: prompt.value.slice(start, end), handed, seen: handed, tail: 0,
    continues: !!handed && !!lastWord(handed) && before.endsWith(lastWord(handed)), leadingSpace: endsWord(before), trailingSpace: startsWord(after),
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
  const { rest, glued } = remainder(update.text, anchor);
  const own = glued ? rest : rest.replace(/^\s+/u, "");
  const keep = { selectionStart: prompt.selectionStart, selectionEnd: prompt.selectionEnd };
  // A cancel drops the text; a session that ends with no words (denied, failed, or nothing new
  // after the user took the words over) leaves the prompt and its selection alone.
  if (update.cancelled || (!active && !own && anchor.length === 0)) {
    if (anchor.length === 0 && !anchor.replaced) return { value: prompt.value, ...keep, anchor: null, placed: false };
    const value = anchor.written.slice(0, anchor.start) + anchor.replaced + anchor.written.slice(anchor.start + anchor.length);
    const caret = anchor.start + anchor.replaced.length;
    return { value, selectionStart: caret, selectionEnd: caret, anchor: null, placed: false };
  }
  // After a spaced word: a space before a word, and before another script when the engine put one there.
  const spaced = startsWord(own) || (/^\s/u.test(rest) && unspaced.test(own[0] ?? ""));
  const lead = own && !glued && anchor.leadingSpace && spaced ? " " : "";
  const trail = own && anchor.trailingSpace && endsWord(own) ? " " : "";
  const inserted = lead + own + trail;
  const value = anchor.written.slice(0, anchor.start) + inserted + anchor.written.slice(anchor.start + anchor.length);
  // A caret at the end of the session's words (before a space it added) follows them; one the
  // user put anywhere else, even inside the words, stays there, shifted if the words before it
  // grew or shrank.
  const end = anchor.start + anchor.length;
  const following = fresh || (prompt.selectionStart === prompt.selectionEnd && prompt.selectionStart === end - anchor.tail);
  const shift = (position: number) => (position >= end ? position + inserted.length - anchor.length : position);
  const caret = anchor.start + lead.length + own.length;
  return {
    value,
    selectionStart: following ? caret : shift(prompt.selectionStart),
    selectionEnd: following ? caret : shift(prompt.selectionEnd),
    anchor: active ? { ...anchor, length: inserted.length, written: value, seen: update.text, tail: trail.length } : null,
    placed: own.length > 0,
  };
}

const lastWord = (text: string) => /[\p{L}\p{N}]+$/u.exec(text)?.[0] ?? "";
const words = (text: string) => text.trim().split(/\s+/u).filter(Boolean);

/// The session text past what the user took over. A word the engine was still spelling when they
/// took it continues it (`glued`) if they left that word as it was, and is dropped if they changed
/// it. When the engine revises words they already have, theirs stay and only new words are added.
function remainder(text: string, anchor: DictationAnchor): { rest: string; glued: boolean } {
  const handed = anchor.handed;
  if (!handed) return { rest: text, glued: false };
  if (text.startsWith(handed)) {
    const rest = text.slice(handed.length);
    const midWord = wordChar.test(handed.at(-1) ?? "") && wordChar.test(rest[0] ?? "");
    if (!midWord) return { rest, glued: false };
    return anchor.continues ? { rest, glued: true } : { rest: rest.replace(/^[\p{L}\p{N}]+/u, ""), glued: false };
  }
  // Scripts without spaces: by character.
  if (unspaced.test(handed) && !/\s/u.test(handed.trim())) return { rest: text.slice(handed.length), glued: false };
  const old = words(handed), next = words(text);
  let common = 0;
  while (common < old.length && common < next.length && old[common] === next[common]) common += 1;
  // A revision that keeps the word count adds its last words; one that only grew adds the new ones.
  const skip = common === old.length ? common : Math.max(common, Math.min(old.length, next.length - 1));
  // Whole words: a word boundary goes before them.
  const added = next.slice(skip).join(" ");
  return { rest: added && " " + added, glued: false };
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
  if (intact && anchor.tail && value[at - 1] === " ") at -= 1;
  return anchorAt({ value, selectionStart: at, selectionEnd: at }, anchor.seen);
}
