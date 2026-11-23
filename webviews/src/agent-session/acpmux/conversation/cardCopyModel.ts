import { createContext } from "react";
import { copyMarkdownResult } from "../richClipboard";

/// How the corner draws. `faint`, the default: a 14px glyph at 45% until the card is hovered, a
/// check when copied. The others are gallery versions kept beside it (CardCopy.gallery.tsx):
/// `quiet`, a 12px glyph at 30%; `word`, the default glyph that says "Copied" beside its check.
export type CardCopyLook = "faint" | "quiet" | "word";
export const CardCopyLookContext = createContext<CardCopyLook>("faint");
/// What puts the text on the clipboard: the page's clipboard, as a message's Copy does (its Markdown
/// and its HTML, richClipboard.ts), or a gallery stage's stand-in.
export const CardCopyWriterContext = createContext<(text: string) => Promise<boolean>>(copyMarkdownResult);
