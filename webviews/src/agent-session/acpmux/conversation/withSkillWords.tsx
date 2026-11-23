import type { ReactNode } from "react";
import { splitSkillWords, type SkillPiece } from "./skillWords";
import { SkillWord } from "./SkillWord";

/// `text` with its skill words drawn as SkillWord, each other piece through `rest` (plain text by
/// default). With `leading`, the prompt's first word draws as one too when it names any command
/// (skillWords.ts leadCommand), as the composer draws it.
export function withSkillWords(
  text: string,
  words: ReadonlyMap<string, string>,
  rest: (piece: string, key: string) => ReactNode = (piece) => piece,
  leading?: ReadonlyMap<string, string>,
): ReactNode[] {
  return splitSkillWords(text, words, leading).map((piece: SkillPiece, index) =>
    typeof piece === "string" ? rest(piece, `p${index}`) : <SkillWord key={`s${index}`} {...piece} />,
  );
}
