// The header of a fenced code card (HighlightedCode.tsx, StreamingCode.tsx PlainCode). A fence with a
// language keeps its row: the brackets, the language's name, and the actions. An unlabeled fence (no
// language, or `text`) has no row (Leo 2026-11-01, on a reply's tree diagram under a loud
// "</> Plain text": "could we render this type of thing better in cmux-next"): its actions float in
// the card's top-right corner and show while the pointer is on the card or focus is inside it, as
// Claude and ChatGPT draw a plain block. The gallery (CodeBlockDiagram.gallery.tsx) compares this
// with a muted label row and the old row; design/chat-transcript.md "Code blocks" records the pick.
import { type ReactNode } from "react";
import { useT } from "../i18n";
import { languageLabel } from "./codeBlockModel";

import { CodeBrackets } from "./icons";
import { type UnlabeledHeaderLook } from "./codeHeaderModel";
export function CodeHeader({
  look,
  lang,
  label,
  children,
}: {
  look: UnlabeledHeaderLook;
  lang: string;
  label?: string;
  children: ReactNode;
}) {
  const t = useT();
  return (
    <div className="cv-codeblock__header">
      {look === "row" && <CodeBrackets size={16} />}
      {look !== "corner" && <span>{label ?? languageLabel(lang, t)}</span>}
      <span className="cv-codeblock__actions">{children}</span>
    </div>
  );
}
