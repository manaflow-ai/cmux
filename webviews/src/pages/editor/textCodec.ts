// Byte-exact text for the editor. The host sends the file decoded as UTF-8 with nothing removed;
// Monaco keeps lines and one line ending (LF or CRLF) and drops a BOM. This module splits a file into
// what Monaco holds (`body`) and what it would lose (the BOM, every line's own ending), and writes the
// file back from Monaco's lines: an unchanged line keeps its ending, a new line break gets the file's
// usual one. A final newline is an empty last line in Monaco, so it survives on its own.
//
// Uniform files (only LF, or only CRLF) need no per-line state: Monaco's EOL is the file's. Files with
// mixed endings or lone CR keep one ending per line, updated from Monaco's change events.

export const BOM = "﻿";
export type LineEnding = "\n" | "\r\n" | "\r";

export interface TextShape {
  bom: boolean;
  /** The ending a new line break gets: the most common one (LF for a file without any). */
  eol: LineEnding;
  /** Every ending in order when the file is not uniform LF or CRLF, else null. */
  endings: LineEnding[] | null;
  /** The text without the BOM. */
  body: string;
}

const BREAK = /\r\n|\r|\n/g;

/** Splits a file's text into Monaco's text and the endings Monaco would not keep. */
export function analyzeText(text: string): TextShape {
  const bom = text.startsWith(BOM);
  const body = bom ? text.slice(1) : text;
  let lf = 0;
  let crlf = 0;
  let cr = 0;
  for (const match of body.matchAll(BREAK)) {
    if (match[0] === "\n") lf++;
    else if (match[0] === "\r\n") crlf++;
    else cr++;
  }
  const eol: LineEnding = crlf > lf && crlf >= cr ? "\r\n" : cr > lf && cr > crlf ? "\r" : "\n";
  const uniform = cr === 0 && (lf === 0 || crlf === 0);
  const endings = uniform ? null : Array.from(body.matchAll(BREAK), (match) => match[0] as LineEnding);
  return { bom, eol, endings, body };
}

/** One content change as Monaco reports it (1-based lines), applied in the order given. */
export interface LineChange {
  startLineNumber: number;
  endLineNumber: number;
  text: string;
}

/** The count of line breaks in inserted text. */
function breaks(text: string): number {
  let count = 0;
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    if (code === 10) count++;
    else if (code === 13) {
      count++;
      if (text.charCodeAt(index + 1) === 10) index++;
    }
  }
  return count;
}

/**
 * The file's line endings while it is edited. `endings[i]` ends line i + 1. A change replacing lines
 * `start..end` removes the endings inside the range (start..end-1) and inserts one new ending (the
 * file's usual one) per inserted line break; the ending after the range's last line stays.
 */
export class LineEndings {
  readonly bom: boolean;
  readonly eol: LineEnding;
  private endings: LineEnding[] | null;

  constructor(shape: Pick<TextShape, "bom" | "eol" | "endings">) {
    this.bom = shape.bom;
    this.eol = shape.eol;
    this.endings = shape.endings ? [...shape.endings] : null;
  }

  /** Whether Monaco's own EOL reproduces the file (no per-line endings to keep). */
  get uniform(): boolean {
    return this.endings === null;
  }

  /** Applies Monaco's changes of one content event (ordered from the end of the document). */
  apply(changes: readonly LineChange[]): void {
    const endings = this.endings;
    if (!endings) return;
    for (const change of changes) {
      const removed = change.endLineNumber - change.startLineNumber;
      const added = breaks(change.text);
      if (removed === 0 && added === 0) continue;
      endings.splice(change.startLineNumber - 1, removed, ...Array.from({ length: added }, () => this.eol));
    }
  }

  /** The file's text from Monaco's lines (`lines` from `model.getLinesContent()`). */
  encode(lines: readonly string[]): string {
    const prefix = this.bom ? BOM : "";
    if (!this.endings) return prefix + lines.join(this.eol);
    const endings = this.endings;
    const parts: string[] = [];
    for (let index = 0; index < lines.length; index++) {
      parts.push(lines[index]);
      if (index < lines.length - 1) parts.push(endings[index] ?? this.eol);
    }
    return prefix + parts.join("");
  }
}

/** A short label of the file's endings for the status bar. */
export function lineEndingLabel(shape: Pick<TextShape, "eol" | "endings">): "LF" | "CRLF" | "CR" | "mixed" {
  if (shape.endings && new Set(shape.endings).size > 1) return "mixed";
  return shape.eol === "\r\n" ? "CRLF" : shape.eol === "\r" ? "CR" : "LF";
}
