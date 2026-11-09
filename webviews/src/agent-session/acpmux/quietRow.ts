import { createContext } from "react";

/// True inside the quiet row (ComposerFoot.tsx): controls rendered here stay in the footer and
/// never move into the box. Kept out of ComposerFoot.tsx so an edit there swaps in place: a
/// component module that also exports a context can't take a Fast Refresh update.
export const InQuietRow = createContext(false);
