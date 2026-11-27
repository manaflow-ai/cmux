import { useEffect, useInsertionEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from "react";
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
// as one undo step; Esc closes it for that token; only the focused prompt shows it; the `:` that closes a known `:code:`
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
  /// Closes the list for the token it shows for (Esc, focus leaving).
  dismiss(): void;
  /// The list's keys (arrows, Ctrl-N/P/J/K, Return, Tab, Esc); true when it took the key.
  keyDown(event: ListKey): boolean;
  /// The field's `onBeforeInput` for the closing `:`; true when it wrote the emoji.
  beforeInput(data: string, state: { composing: boolean; paste: boolean }): boolean;
  /// Writes the highlighted row (a Return an input method passed on); false with none.
  pickSelected(): boolean;
  /// The menu, for the prompt's list layer; undefined with no list.
  menu: ReactNode;
}

/// Whether the token `closed` (the one Esc closed the list on) is still `now`: the same start, and
/// what was typed then still all there (typing on keeps it closed; Backspace past it does not).
export function stillDismissed(closed: EmojiTrigger | undefined, now: EmojiTrigger): boolean {
  return closed !== undefined && closed.start === now.start && now.token.startsWith(closed.token);
}

export function useEmojiCompletion({
  field,
  off = false,
}: {
  field: RefObject<MarkdownFieldHandle | null>;
  /// Another list or mode owns the prompt's keys (the `/` or `@` list, shell mode).
  off?: boolean;
}): EmojiCompletion {
  const [data, setData] = useState<EmojiShortcodes | undefined>();
  const dataNow = useRef(data);
  const requested = useRef(false);
  const [active, setActive] = useState<string | undefined>();
  const [recents, setRecents] = useState(loadRecentEmoji);
  const toneNow = useRef(recents.tone);
  // The token the field reads at its caret, on whichever line it is (MarkdownField `onEmoji`).
  const [caret, setCaret] = useState<EmojiTrigger | undefined>();
  // The token Esc closed the list on: it stays closed for that token, more letters typed on it and
  // the caret off it and back included; another token, or one shortened (Backspace), opens it again.
  const [dismissed, setDismissed] = useState<EmojiTrigger | undefined>();
  // Only the prompt with the keyboard shows a list. A pane whose draft ends in `:plead` drew its
  // list while the person typed in the next pane (Leo's two panes, 2026-11-22): the list belongs to
  // the caret being typed at, so a field without focus shows none.
  const [focused, setFocused] = useState(false);
  // What the field's callbacks read, written as the render commits.
  useInsertionEffect(() => {
    dataNow.current = data;
    toneNow.current = recents.tone;
  });
  const typed = !off && focused && caret && !stillDismissed(dismissed, caret) ? caret : undefined;
  const key = typed ? `${typed.start}:${typed.token}` : undefined;
  const rows = useMemo(() => (typed && data ? emojiMatches(data, typed, recents) : []), [typed, data, recents]);
  const at = rows.length > 0 ? typed : undefined;
  const chosen = active === undefined ? -1 : rows.findIndex((row) => row.key === active);
  const selected = rows.length === 0 ? -1 : Math.max(0, chosen);
  useEffect(() => setActive(undefined), [key]);
  // Focus in and out of the field. Another pane's web view taking the keyboard blurs this window,
  // never the prompt (WebKit keeps the element focused), so the window's blur counts as leaving
  // too. Back in the field with the caret on the token, the list shows again.
  useEffect(() => {
    const inside = (node: EventTarget | null) => {
      const element = field.current?.element();
      return Boolean(element && node instanceof Node && element.contains(node));
    };
    const away = () => setFocused(false);
    const focusIn = (event: FocusEvent) => setFocused(inside(event.target));
    const focusOut = (event: FocusEvent) => {
      if (inside(event.target) && !inside(event.relatedTarget)) away();
    };
    const focusedNow = () => inside(document.activeElement);
    // The window back: the element WebKit kept focused has the keyboard again.
    const back = () => setFocused(focusedNow());
    back();
    document.addEventListener("focusin", focusIn);
    document.addEventListener("focusout", focusOut);
    window.addEventListener("blur", away);
    window.addEventListener("focus", back);
    return () => {
      document.removeEventListener("focusin", focusIn);
      document.removeEventListener("focusout", focusOut);
      window.removeEventListener("blur", away);
      window.removeEventListener("focus", back);
    };
  }, [field]);
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
      onEmoji: (trigger: EmojiTrigger | undefined) => {
        setCaret(trigger);
        // Another token, or this one shortened, ends what Esc closed.
        setDismissed((closed) => (!trigger || stillDismissed(closed, trigger) ? closed : undefined));
      },
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
    dismiss: () => setDismissed(at),
    keyDown: (event) => {
      if (!at) return false;
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        setDismissed(at);
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
