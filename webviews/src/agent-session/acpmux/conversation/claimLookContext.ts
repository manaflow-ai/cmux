import { createContext } from "react";

/// How a mark draws. `underline` ships; the others are the gallery's alternatives.
export type ClaimLook = "underline" | "glyph" | "chip";
export const ClaimLookContext = createContext<ClaimLook>("underline");
