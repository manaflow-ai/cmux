// The copy button in an expanded card's top-right corner, inside the card (Leo, 2026-10-29:
// "wouldnt it be a little copy symbol on the top right within this card?"). One component for
// every expandable message or prompt card that draws in a DisclosureRow panel: a sub-session's
// prompt (SubsessionCallCard.tsx StartedCard), a wait's or list's reply, and a message another
// agent sent (IncomingMessageCard.tsx). It is the transcript's CopyButton, so it says Copied with a
// check only when the clipboard took the text, and goes back after COPIED_MS. It floats, so the
// card's first line wraps around it instead of running under it; faint at rest, full when the card
// is hovered (CardCopy.css). Its highlight is the button's own box, never the card's.
import { useContext } from "react";
import { useT } from "../i18n";
import { CopyButton } from "./CopyButton";

import "./CardCopy.css";
import { CardCopyLookContext, CardCopyWriterContext } from "./cardCopyModel";
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
