// Copy Last Code Block (cx-ncc.72): the app reads it from the page (`chat.lastCodeBlock`) and writes
// the pasteboard. Its own module: the markdown parser pulls in the diff renderer's web components.
import type { AcpmuxRow } from "../model";
import { type MdBlock, parseMarkdown } from "./Markdown";

/// The last fenced block of the latest answer that has one,
/// including one inside a quote or a list; undefined when no answer has code.
export function lastCodeBlock(rows: readonly AcpmuxRow[]): string | undefined {
  for (let index = rows.length - 1; index >= 0; index--) {
    const row = rows[index]!;
    if (row.kind !== "assistant") continue;
    const code = lastCode(parseMarkdown(row.text?.trim() ?? ""));
    if (code !== undefined) return code;
  }
  return undefined;
}

function lastCode(blocks: readonly MdBlock[]): string | undefined {
  for (let index = blocks.length - 1; index >= 0; index--) {
    const block = blocks[index]!;
    const code =
      block.type === "code"
        ? block.code
        : block.type === "blockquote"
          ? lastCode(block.children)
          : block.type === "list"
            ? block.items.reduceRight<string | undefined>((found, item) => found ?? lastCode(item.children), undefined)
            : undefined;
    if (code !== undefined) return code;
  }
  return undefined;
}
