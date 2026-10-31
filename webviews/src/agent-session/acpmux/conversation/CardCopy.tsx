// The copy button in an expanded card's top-right corner, inside the card (Leo, 2026-10-29:
// "wouldnt it be a little copy symbol on the top right within this card?"). One component for
// every expandable message or prompt card that draws in a DisclosureRow panel: a sub-session's
// prompt (SubsessionCallCard.tsx StartedCard), a wait's or list's reply, and a message another
// agent sent (IncomingMessageCard.tsx). It is the transcript's CopyButton, so it says Copied with a
// check only when the clipboard took the text, and goes back after COPIED_MS. It floats, so the
// card's first line wraps around it instead of running under it; faint at rest, full when the card
// is hovered (CardCopy.css). Its highlight is the button's own box, never the card's.
import { createContext, useContext } from "react";
import { useT } from "../i18n";
import { copyTextResult } from "./clipboard";
import { CopyButton } from "./CopyButton";
import "./CardCopy.css";

/// How the corner draws. `faint`, the default: a 14px glyph at 45% until the card is hovered, a
/// check when copied. The others are gallery versions kept beside it (CardCopy.gallery.tsx):
/// `quiet`, a 12px glyph at 30%; `word`, the default glyph that says "Copied" beside its check.
export type CardCopyLook = "faint" | "quiet" | "word";
export const CardCopyLookContext = createContext<CardCopyLook>("faint");
/// What puts the text on the clipboard: the page's clipboard, or a gallery stage's stand-in.
export const CardCopyWriterContext = createContext<(text: string) => Promise<boolean>>(copyTextResult);

export function CardCopy({
  text,
  copy,
}: {
  /// The card's raw text: a prompt's Markdown source, a message's words.
  text: string;
  copy?: (text: string) => Promise<boolean>;
}) {
  const t = useT();
  const look = useContext(CardCopyLookContext);
  const writer = useContext(CardCopyWriterContext);
  if (!text.trim()) return null;
  return (
    <span className="cv-card-copy" data-look={look} data-find-skip="">
      <CopyButton
        text={text}
        label={t("turn.copy")}
        className="cv-card-copy__button"
        copy={copy ?? writer}
        size={look === "quiet" ? 12 : 14}
        copiedWord={look === "word"}
      />
    </span>
  );
}
