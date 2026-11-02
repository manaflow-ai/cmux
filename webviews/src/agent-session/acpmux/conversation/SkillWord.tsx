// A skill's `/name` in a sent prompt (PromptText.tsx, ComposerQueue.tsx): the composer's command
// blue, and with a description, a dotted underline on hover and the description as the app's
// tooltip above it (ui/titleTooltips.ts reads `data-tooltip`); assistive tech hears it as the word's
// description. The word is not a control, so it takes no focus.
import type { ReactNode } from "react";
import { splitSkillWords, type SkillPiece } from "./skillWords";

export function SkillWord({ word, description }: { word: string; description: string }) {
  return description ? (
    <span className="cv-skill-word" data-tooltip={description} data-tooltip-side="top" aria-description={description}>
      {word}
    </span>
  ) : (
    <span className="cv-skill-word">{word}</span>
  );
}

/// `text` with its skill words drawn as SkillWord, each other piece through `rest` (plain text by
/// default).
export function withSkillWords(
  text: string,
  words: ReadonlyMap<string, string>,
  rest: (piece: string, key: string) => ReactNode = (piece) => piece,
): ReactNode[] {
  return splitSkillWords(text, words).map((piece: SkillPiece, index) =>
    typeof piece === "string" ? rest(piece, `p${index}`) : <SkillWord key={`s${index}`} {...piece} />,
  );
}
