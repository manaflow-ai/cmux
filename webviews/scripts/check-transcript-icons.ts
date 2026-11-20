// Transcript icons come from the shared pack. These are the remaining explicit inline-SVG
// exceptions, not permission to add another icon renderer. Counts may only shrink.
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";

const HERE = dirname(fileURLToPath(import.meta.url));
const TRANSCRIPT = join(HERE, "../src/agent-session/acpmux/conversation");

export const INLINE_SVG_EXCEPTIONS: Readonly<Record<string, { count: number; reason: string }>> = {
  "icons.tsx": {
    count: 3,
    reason: "The shared animated spinner and the GitHub/arXiv brand marks.",
  },
  "NoticeMark.tsx": { count: 1, reason: "Existing severity illustration; migrate separately." },
  "EditedFilesCard.tsx": { count: 1, reason: "Existing file-change mark; migrate separately." },
  "SelectionReply.tsx": { count: 1, reason: "Existing selection-reply mark; migrate separately." },
};

export interface InlineSvgFinding {
  file: string;
  line: number;
}

/** Parse JSX so SVG-looking strings and comments never consume a file's exception allowance. */
export function inlineSvgs(file: string, text: string): InlineSvgFinding[] {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const found: InlineSvgFinding[] = [];
  const visit = (node: ts.Node) => {
    if (
      (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) &&
      ts.isIdentifier(node.tagName) &&
      node.tagName.text === "svg"
    ) {
      found.push({
        file,
        line: source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1,
      });
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return found;
}

export function newInlineSvgs(file: string, text: string): InlineSvgFinding[] {
  return inlineSvgs(file, text).slice(INLINE_SVG_EXCEPTIONS[file]?.count ?? 0);
}

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (entry.isDirectory()) return entry.name === "gallery" ? [] : sourceFiles(join(dir, entry.name));
    return entry.name.endsWith(".tsx") && !/\.(?:test|gallery)\./.test(entry.name) ? [join(dir, entry.name)] : [];
  });
}

if (import.meta.main) {
  let errors = 0;
  for (const path of sourceFiles(TRANSCRIPT)) {
    const file = relative(TRANSCRIPT, path).replaceAll("\\", "/");
    for (const finding of newInlineSvgs(file, readFileSync(path, "utf8"))) {
      console.error(`transcript icons: ${file}:${finding.line}: use a shared pack icon instead of an inline SVG`);
      errors += 1;
    }
  }
  if (errors) process.exitCode = 1;
  else console.log("Transcript icons checked: no new inline SVG.");
}
