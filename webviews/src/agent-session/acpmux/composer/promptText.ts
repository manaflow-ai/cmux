import { useSyncExternalStore } from "react";
import type { MentionTrigger } from "./emojiTokens";

/// The composer's prompt text and caret, outside React state (Leo: "we need typing in the gui to be
/// fast too and smootha nd stuff"). Before, `ComposerFrame` held the text as state, so every key
/// rendered the whole frame (render, commit and its effects: about 1.15 ms a key at 1,500 rows,
/// bench/composer-typing.bench.ts --profile). Now a key writes here; the frame renders only when one
/// of `PromptFacts` changes (the prompt empties or fills, a `/` or `@` word opens or moves), and
/// the box around the field (ComposerBox) reads the text itself. The `:` emoji list keeps its own
/// token (composer/useEmojiCompletion.tsx), as the field reads it on any line.

/// A list Esc closed for the text it was pressed on: it stays closed until the text changes.
export type PromptDismissal = "slash" | "mention";

/// What the frame's render reads of the prompt. Each key recomputes it; the frame renders only when
/// one field differs.
export type PromptFacts = {
  /// The prompt text and caret in the frame's last drawn snapshot.
  text: string;
  caret: number;
  /// Exactly empty, as the field draws its placeholder.
  blank: boolean;
  /// Only white space: Send is Stop, Esc stops.
  empty: boolean;
  /// The prompt's leading `/word` (cliOnlyCommands.ts commandWaitsForTurn reads only that).
  command: string | undefined;
  /// The `@word` the caret ends, on any line, as the field reads it (emojiTokens.ts
  /// mentionTriggerAt). It read the markdown with a caret counted in the first paragraph before, so
  /// `@` and `:` past the first line opened nothing (Leo's `:plead`, 2026-11-22).
  mention: MentionTrigger | undefined;
  /// The prompt still shows what ↑ brought back (promptHistory.ts).
  recalling: boolean;
  slashDismissed: boolean;
  mentionDismissed: boolean;
};

/// Whether the prompt as typed still shows a prompt ↑ recalled.
export type RecallProbe = (text: string) => boolean;

const sameFacts = (left: PromptFacts, right: PromptFacts) =>
  left.blank === right.blank &&
  left.empty === right.empty &&
  left.command === right.command &&
  left.mention?.start === right.mention?.start &&
  left.mention?.query === right.mention?.query &&
  left.recalling === right.recalling &&
  left.slashDismissed === right.slashDismissed &&
  left.mentionDismissed === right.mentionDismissed;

export class PromptText {
  #text: string;
  #caret = 0;
  #mention: MentionTrigger | undefined;
  #dismissed = new Set<PromptDismissal>();
  #listeners = new Set<() => void>();
  #textListeners = new Set<() => void>();
  #facts: PromptFacts | undefined;
  #factsFor:
    | { text: string; caret: number; mention: MentionTrigger | undefined; dismissed: number; probe: RecallProbe }
    | undefined;
  /// Bumped on each dismissal change, so cached facts know to recompute.
  #dismissedVersion = 0;

  constructor(text: string) {
    this.#text = text;
  }

  get text() {
    return this.#text;
  }

  get caret() {
    return this.#caret;
  }

  /// The prompt's new text (and caret). A changed text ends every dismissal, as the text compare did;
  /// `undismiss` ends them even when it is the same (an edit that comes back to the same text).
  set(text: string, caret?: number, undismiss = false) {
    const changed = text !== this.#text;
    const moved = caret !== undefined && caret !== this.#caret;
    this.#text = text;
    if (caret !== undefined) this.#caret = caret;
    const cleared = (changed || undismiss) && this.#dismissed.size > 0;
    if (cleared) {
      this.#dismissed.clear();
      this.#dismissedVersion += 1;
    }
    if (changed) for (const listener of Array.from(this.#textListeners)) listener();
    if (changed || moved || cleared) this.#notify();
  }

  setCaret = (caret: number) => {
    if (caret === this.#caret) return;
    this.#caret = caret;
    this.#notify();
  };

  /// The `@word` the field reads at its caret (MarkdownField `onMention`).
  setMention = (mention: MentionTrigger | undefined) => {
    if (mention?.start === this.#mention?.start && mention?.query === this.#mention?.query) return;
    this.#mention = mention;
    // The field tells the `@word` before the text it is in (its view update reports the change
    // after); a render now would build facts with the old text and give the field its old value,
    // erasing the `@` just typed. The change's own `set` renders it; this covers a caret-only one.
    queueMicrotask(() => this.#notify());
  };

  dismiss(kind: PromptDismissal) {
    if (this.#dismissed.has(kind)) return;
    this.#dismissed.add(kind);
    this.#dismissedVersion += 1;
    this.#notify();
  }

  /// React's subscription: text, caret or a dismissal changed.
  subscribe = (listener: () => void) => {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  };

  /// Called synchronously on each text change (not caret moves).
  subscribeText(listener: () => void) {
    this.#textListeners.add(listener);
    return () => {
      this.#textListeners.delete(listener);
    };
  }

  getText = () => this.#text;

  /// The facts for the current text, the same object while none of them changed.
  facts(probe: RecallProbe): PromptFacts {
    const text = this.#text;
    const caret = this.#caret;
    const dismissed = this.#dismissedVersion;
    const cached = this.#factsFor;
    if (
      this.#facts &&
      cached &&
      cached.text === text &&
      cached.caret === caret &&
      cached.mention === this.#mention &&
      cached.dismissed === dismissed &&
      cached.probe === probe
    )
      return this.#facts;
    this.#factsFor = { text, caret, mention: this.#mention, dismissed, probe };
    const next: PromptFacts = {
      text,
      caret,
      blank: text === "",
      empty: !text.trim(),
      command: /^\/\S+/.exec(text.trim())?.[0],
      mention: this.#mention,
      recalling: probe(text),
      slashDismissed: this.#dismissed.has("slash"),
      mentionDismissed: this.#dismissed.has("mention"),
    };
    if (!this.#facts || !sameFacts(this.#facts, next)) this.#facts = next;
    return this.#facts;
  }

  #notify() {
    for (const listener of Array.from(this.#listeners)) listener();
  }

  /// The frame draws the current prompt, including text that changed without changing its controls.
  draw() {
    if (!this.#facts || (this.#facts.text === this.#text && this.#facts.caret === this.#caret)) return;
    this.#facts = { ...this.#facts, text: this.#text, caret: this.#caret };
    this.#notify();
  }
}

/// The frame's view of the prompt: renders only when a fact changes.
export function usePromptFacts(prompt: PromptText, probe: RecallProbe): PromptFacts {
  return useSyncExternalStore(prompt.subscribe, () => prompt.facts(probe));
}
