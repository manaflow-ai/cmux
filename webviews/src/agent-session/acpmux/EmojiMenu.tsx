import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useEscapingList } from "../../ui/popupHost";
import { PickerOption, PickerOptionList } from "../../ui/PickerPrimitives";
import { useComposerListBox } from "./backdropLayer";
import type { EmojiMatch } from "./emojiShortcodes";
import type { emojiShortcodeLook } from "./emojiShortcodeLook.experiment";
import { useT } from "./i18n";

type Look = keyof (typeof emojiShortcodeLook)["arms"];

/// The compact list's width; the strip sizes to its glyphs.
const CARET_MENU_PX = 232;

/// The `:shortcode` menu (emojiShortcodes.ts) over the composer, styled as the @ and / menus. The
/// prompt keeps focus and its keys (Composer.tsx): arrows move, Return or Tab picks, Esc closes.
/// `active` -1: no row chosen (the arrows choose one), so Return still sends. It mounts open, once per typed
/// token (Composer keys it by the token's start), and reads the caret's place in that same layout
/// pass, so it opens where it stays and never moves while the word grows.
export function EmojiMenu({
  look,
  matches,
  active,
  back,
  onHover,
  onPick,
}: {
  look: Look;
  /** How many characters before the caret the typed token starts (its `:` or emoticon). */
  back: number;
  matches: readonly EmojiMatch[];
  active: number;
  onHover(index: number): void;
  onPick(match: EmojiMatch): void;
}) {
  const t = useT();
  const box = useComposerListBox();
  const escape = useEscapingList("top", 6, undefined, box);
  const list = useRef<HTMLDivElement | null>(null);
  // Composer keys the menu by the token's start, so the mount's offset names the token's `:`.
  const [startBack] = useState(back);
  const attach = useCallback(
    (node: HTMLDivElement | null) => {
      list.current = node;
      escape?.(node);
    },
    [escape],
  );
  // Over the typed `:` (caret and strip looks): the token's first character in the box, clamped
  // inside it. Read once at mount, when the token is `back` characters behind the caret.
  useLayoutEffect(() => {
    const node = list.current;
    if (!node || look === "wide") return;
    const frame = (box ?? node.offsetParent ?? node.parentElement)?.getBoundingClientRect();
    if (!frame) return;
    const anchor = tokenStartRect(node.ownerDocument, startBack);
    const width = node.offsetWidth || CARET_MENU_PX;
    const left = anchor ? anchor.left - frame.left - 14 : 0;
    node.style.left = `${Math.round(Math.max(0, Math.min(left, frame.width - width)))}px`;
  }, [box, look, startBack]);
  useEffect(() => {
    list.current?.querySelector(`#acpmux-emoji-${active}`)?.scrollIntoView?.({ block: "nearest" });
  }, [active]);
  const chosen = active >= 0 ? matches[active] : undefined;
  return (
    <PickerOptionList
      ref={attach}
      aria-label={t("composer.emoji")}
      className={`ui-popup ui-glass acpmux-slash-menu acpmux-emoji-menu is-${look}`}
      id="acpmux-emoji-menu"
      data-emoji-look={look}
    >
      <div className="acpmux-emoji-rows">
        {matches.map((match, index) => (
          <PickerOption
            key={match.key}
            id={`acpmux-emoji-${index}`}
            type="button"
            // The prompt keeps focus (aria-activedescendant), so no row is a tab stop.
            active={false}
            selected={index === active}
            aria-label={`${match.emoji} :${match.code}:`}
            className={
              index === active
                ? "acpmux-slash-row acpmux-emoji-row acpmux-slash-active"
                : "acpmux-slash-row acpmux-emoji-row"
            }
            onPointerMove={() => onHover(index)}
            // A mouse-down here would take focus from the prompt.
            onMouseDown={(event) => {
              event.preventDefault();
              onPick(match);
            }}
          >
            <span className="acpmux-emoji-glyph" aria-hidden="true">
              {match.emoji}
            </span>
            {look !== "strip" && <span className="acpmux-slash-name acpmux-emoji-code">{codeText(match)}</span>}
          </PickerOption>
        ))}
      </div>
      {look === "strip" && (
        <div className="acpmux-emoji-strip-code" aria-hidden="true">
          {codeText(chosen ?? matches[0]!)}
        </div>
      )}
    </PickerOptionList>
  );
}

/// `:teddy_bear:` with the typed letters bold.
function codeText(match: EmojiMatch) {
  const { code, matched, matchedAt } = match;
  if (!matched) return `:${code}:`;
  return (
    <>
      :{code.slice(0, matchedAt)}
      <b>{code.slice(matchedAt, matchedAt + matched)}</b>
      {code.slice(matchedAt + matched)}:
    </>
  );
}

/// The prompt's caret on screen, or undefined (no selection, or one the engine gives no box for).
function tokenStartRect(document: Document, back: number): DOMRect | undefined {
  const selection = document.getSelection();
  if (!selection || selection.rangeCount === 0) return undefined;
  const range = selection.getRangeAt(0).cloneRange();
  const node = range.startContainer;
  // The token's first character, when it sits in the caret's text node (it does while typing);
  // otherwise the caret itself.
  if (node.nodeType === Node.TEXT_NODE && range.startOffset >= back && back > 0) {
    range.setStart(node, range.startOffset - back);
    range.setEnd(node, range.startOffset + 1);
  }
  const rect = range.getClientRects()[0] ?? range.getBoundingClientRect();
  return rect && (rect.width || rect.height || rect.left) ? rect : undefined;
}
