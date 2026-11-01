// The header of a fenced code card (HighlightedCode.tsx, StreamingCode.tsx PlainCode). A fence with a
// language keeps its row: the brackets, the language's name, and the actions. An unlabeled fence (no
// language, or `text`) has no row (Leo 2026-11-01, on a reply's tree diagram under a loud
// "</> Plain text": "could we render this type of thing better in cmux-next"): its actions float in
// the card's top-right corner and show while the pointer is on the card or focus is inside it, as
// Claude and ChatGPT draw a plain block. The gallery (CodeBlockDiagram.gallery.tsx) compares this
// with a muted label row and the old row; design/chat-transcript.md "Code blocks" records the pick.
import { createContext, useContext, type ReactNode } from "react";
import { useT } from "../i18n";
import { languageLabel } from "./CodeBlock";
import { isUnlabeledLang } from "./codeShape";
import { CodeBrackets } from "./icons";

/// How an unlabeled card's header draws: `corner` (shipped) floats its actions over the card's corner
/// on hover; `muted` is a short quiet row with the label; `row` is the labeled row every fence had.
export type UnlabeledHeaderLook = "corner" | "muted" | "row";

/// The gallery sets it to compare the looks; the transcript reads the default.
export const UnlabeledHeaderLookContext = createContext<UnlabeledHeaderLook>("corner");

/** This card's header: `row` for a labeled fence, else the unlabeled look. */
export function useCodeHeaderLook(lang: string, label?: string): UnlabeledHeaderLook {
  const look = useContext(UnlabeledHeaderLookContext);
  return label === undefined && isUnlabeledLang(lang) ? look : "row";
}

/// The card's modifier class for its header look.
export const codeHeaderClass = (look: UnlabeledHeaderLook) =>
  look === "corner" ? " cv-codeblock--corner" : look === "muted" ? " cv-codeblock--muted" : "";

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
      {look === "row" && <CodeBrackets size={17} strokeWidth={1.2} />}
      {look !== "corner" && <span>{label ?? languageLabel(lang, t)}</span>}
      <span className="cv-codeblock__actions">{children}</span>
    </div>
  );
}
