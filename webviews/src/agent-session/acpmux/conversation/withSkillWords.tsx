import type { ReactNode } from "react";
import { splitSkillWords, type SkillPiece } from "./skillWords";
import { SkillWord } from "./SkillWord";

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
