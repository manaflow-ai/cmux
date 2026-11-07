import { createContext, useContext } from "react";
import { isUnlabeledLang } from "./codeShape";

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
