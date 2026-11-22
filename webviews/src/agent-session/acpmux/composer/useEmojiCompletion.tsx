import { useEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { EmojiMenu } from "../EmojiMenu";
import { emojiShortcodeLook } from "../emojiShortcodeLook.experiment";
import {
  closingShortcode,
  emojiMatches,
  loadEmojiShortcodes,
  loadRecentEmoji,
  rememberEmoji,
  replaceShortcodes,
  type EmojiMatch,
  type EmojiShortcodes,
  type EmojiTrigger,
} from "../emojiShortcodes";
import type { MarkdownFieldHandle } from "../MarkdownField";

// The `:` emoji list of every prompt that takes a draft (the chat composer, New Tab), one lifecycle:
// `:` and two letters at a word start, on any line, list emoji by shortcode, and a text emoticon
// (`:)`, `:DD`, `<3`) lists its face. Return, Tab or a click writes the highlighted row and a space
// as one undo step; Esc keeps the text until it changes; the `:` that closes a known `:code:`
// writes its emoji; a paste's `:code:`s go in as emoji (emojiShortcodes.ts, emojiTokens.ts). Leo,
// 2026-11-22: "for some reason i can't do :pleading_face: with the emoji here. we need to actually
// improve the ergonomics and lifecycle of that."

/// A key as the list reads it: the keys a prompt's own handler gets first.
interface ListKey {
  key: string;
  shiftKey: boolean;
  altKey: boolean;
  metaKey: boolean;
  ctrlKey: boolean;
  preventDefault(): void;
  stopPropagation(): void;
}

export interface EmojiCompletion {
  /// MarkdownField `onEmoji` (stable).
  onEmoji(trigger: EmojiTrigger | undefined): void;
  /// MarkdownField `transformPaste` (stable).
  transformPaste(text: string): string;
  /// Loads the table at the next idle moment (the prompt focused or edited).
  request(): void;
  /// The token the list shows for; undefined with no list.
  at: EmojiTrigger | undefined;
  /// The highlighted row's index, for `aria-activedescendant` (`acpmux-emoji-N`).
  selected: number;
  /// Closes the list until the text changes (Esc, focus leaving).
  dismiss(): void;
  /// The text changed: a dismissed list may show again.
  edited(): void;
  /// The list's keys (arrows, Ctrl-N/P/J/K, Return, Tab, Esc); true when it took the key.
  keyDown(event: ListKey): boolean;
  /// The field's `onBeforeInput` for the closing `:`; true when it wrote the emoji.
  beforeInput(data: string, state: { composing: boolean; paste: boolean }): boolean;
  /// Writes the highlighted row (a Return an input method passed on); false with none.
  pickSelected(): boolean;
  /// The menu, for the prompt's list layer; undefined with no list.
  menu: ReactNode;
}

export function useEmojiCompletion({
  field,
  text,
  off = false,
}: {
  field: RefObject<MarkdownFieldHandle | null>;
  /// The prompt's value: Esc closes the list for this text.
  text: string;
  /// Another list or mode owns the prompt's keys (the `/` or `@` list, shell mode).
  off?: boolean;
}): EmojiCompletion {
  const [data, setData] = useState<EmojiShortcodes | undefined>();
  const dataNow = useRef(data);
  dataNow.current = data;
  const requested = useRef(false);
  const [active, setActive] = useState<string | undefined>();
  const [dismissed, setDismissed] = useState<string | undefined>();
  const [recents, setRecents] = useState(loadRecentEmoji);
  const toneNow = useRef(recents.tone);
  toneNow.current = recents.tone;
  // The token the field reads at its caret, on whichever line it is (MarkdownField `onEmoji`).
  const [caret, setCaret] = useState<EmojiTrigger | undefined>();
  const textNow = useRef(text);
  textNow.current = text;
  const typed = !off && dismissed !== text ? caret : undefined;
  const key = typed ? `${typed.start}:${typed.token}` : undefined;
  const rows = useMemo(() => (typed && data ? emojiMatches(data, typed, recents) : []), [typed, data, recents]);
  const at = rows.length > 0 ? typed : undefined;
  const chosen = active === undefined ? -1 : rows.findIndex((row) => row.key === active);
  const selected = rows.length === 0 ? -1 : Math.max(0, chosen);
  useEffect(() => setActive(undefined), [key]);
  // Another pane's web view taking the keyboard blurs this window, never the prompt (WebKit keeps
  // the element focused), so the list stayed up over a prompt that no longer took its keys: Leo's
  // `:plead` list in the next pane while he typed here (2026-11-22). Closed as Esc closes it.
  useEffect(() => {
    const away = () => setDismissed(textNow.current);
    window.addEventListener("blur", away);
    return () => window.removeEventListener("blur", away);
  }, []);
  const look = experimentArm(emojiShortcodeLook);

  const pick = (match: EmojiMatch) => {
    if (!at || !field.current?.replaceBeforeCaret(at.token.length, match.emoji, true)) return;
    setRecents(rememberEmoji(match.key));
    // The person's own pick (a click on a row) gives the prompt its keyboard back, as the chat
    // composer's pick did.
    // focus-route: MarkdownFieldHandle.focus, the person's pick
    field.current.focus();
  };

  // Stable for the field's props (MarkdownField compares them).
  const stable = useMemo(
    () => ({
      onEmoji: (trigger: EmojiTrigger | undefined) => setCaret(trigger),
      transformPaste: (pasted: string) => {
        const table = dataNow.current;
        return table ? replaceShortcodes(table, pasted, toneNow.current) : pasted;
      },
      request: () => {
        if (requested.current) return;
        requested.current = true;
        // The table loads in its own chunk at an idle moment, never while a chat opens.
        const load = () =>
          void loadEmojiShortcodes().then(setData, () => {
            requested.current = false;
          });
        if (globalThis.requestIdleCallback) globalThis.requestIdleCallback(load, { timeout: 500 });
        else setTimeout(load, 0);
      },
    }),
    [],
  );

  return {
    ...stable,
    at,
    selected,
    dismiss: () => setDismissed(text),
    edited: () => setDismissed(undefined),
    keyDown: (event) => {
      if (!at) return false;
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        setDismissed(text);
        return true;
      }
      const plain = !event.shiftKey && !event.altKey && !event.metaKey && !event.ctrlKey;
      const control = event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;
      const step =
        (event.key === "ArrowDown" && plain) || (control && (event.key === "n" || event.key === "j"))
          ? 1
          : (event.key === "ArrowUp" && plain) || (control && (event.key === "p" || event.key === "k"))
            ? -1
            : 0;
      if (step) {
        event.preventDefault();
        setActive(rows[(selected + step + rows.length) % rows.length]!.key);
        return true;
      }
      const row = rows[selected];
      if ((event.key === "Enter" || event.key === "Tab") && plain && row) {
        event.preventDefault();
        pick(row);
        return true;
      }
      return false;
    },
    beforeInput: (input, state) => {
      // The `:` that closes a known `:code:` writes its emoji at once, as Slack and GitHub do; ⌘Z
      // gives back `:code:` as typed. `:skin-tone-N:` after a toned emoji re-tones it.
      if (input !== ":" || state.composing || state.paste || !data || !field.current) return false;
      const before = field.current.textBeforeCaret();
      const closed = before === undefined ? undefined : closingShortcode(data, before, recents.tone);
      if (!closed || !field.current.typeThenReplace(":", closed.back, closed.emoji)) return false;
      setRecents(rememberEmoji(closed.key, Date.now(), closed.tone));
      return true;
    },
    pickSelected: () => {
      const row = at ? rows[selected] : undefined;
      if (!row) return false;
      pick(row);
      return true;
    },
    menu: at ? (
      <EmojiMenu
        key={at.start}
        look={look}
        matches={rows}
        active={selected}
        back={at.token.length}
        onHover={(index) => setActive(rows[index]?.key)}
        onPick={pick}
      />
    ) : undefined,
  };
}
