// Hide imports ("..." menu): the diff leaves out each hunk whose changes are all import lines, so
// a reader sees the code that changed. A hunk that mixes imports and code stays whole, and a
// file whose only changes are imports leaves the diff. The page does this to each file's patch
// text before it parses it (diff-stream.ts `filterFileText`): every hunk it keeps is the hunk git
// printed, so hunk Stage and Revert still match the host's own diff of the file.

/**
 * One language's import line, the lines inside a multi-line import it continues, and the lines
 * that open and close an import block (Go's `import (` and `)`): inside one, every line is an
 * import, also when the block opens in the hunk's context.
 */
type ImportSyntax = { line: RegExp; continuation?: RegExp; blockStart?: RegExp; blockEnd?: RegExp };

const JAVASCRIPT: ImportSyntax = {
  line: /^\s*(import\b|export\s+(\*|type\s+\{|\{)[^;]*\bfrom\b|export\s+\*\s+from\b|(const|let|var)\s+[\w${},\s]+=\s*require\()/,
  // `import {`, then `  a,` lines, then `} from "x";`.
  continuation: /^\s*([\w$]+(\s+as\s+[\w$]+)?,?|type\s+[\w$]+,?|\}\s*from\s+["'][^"']+["'];?|\};?)\s*$/,
  blockStart: /^\s*(import|export)\s+(type\s+)?\{\s*$/,
  blockEnd: /^\s*\}\s*from\s+["'][^"']+["'];?\s*$/,
};

const SYNTAX_BY_EXTENSION: Record<string, ImportSyntax> = {
  js: JAVASCRIPT,
  jsx: JAVASCRIPT,
  mjs: JAVASCRIPT,
  cjs: JAVASCRIPT,
  ts: JAVASCRIPT,
  tsx: JAVASCRIPT,
  mts: JAVASCRIPT,
  cts: JAVASCRIPT,
  vue: JAVASCRIPT,
  svelte: JAVASCRIPT,
  py: {
    line: /^\s*(import\s+\S|from\s+\S+\s+import\b)/,
    // `from x import (`, then `    a,` lines, then `)`.
    continuation: /^\s*([\w.]+(\s+as\s+\w+)?,?|\))\s*$/,
    blockStart: /^\s*from\s+\S+\s+import\s*\(\s*$/,
    blockEnd: /^\s*\)\s*$/,
  },
  go: {
    line: /^\s*import\b/,
    // The lines of an `import ( ... )` block.
    continuation: /^\s*([\w.]+\s+)?"[^"]+"\s*$|^\s*\)\s*$/,
    blockStart: /^\s*import\s*\(\s*$/,
    blockEnd: /^\s*\)\s*$/,
  },
  rs: {
    line: /^\s*(pub(\([^)]*\))?\s+)?(use\s|extern\s+crate\s)/,
    continuation: /^\s*([\w:]+(\s+as\s+\w+)?,?|\{|\};?)\s*$/,
    blockStart: /^\s*(pub(\([^)]*\))?\s+)?use\s+[\w:]*\{\s*$/,
    blockEnd: /^\s*\};\s*$/,
  },
  swift: { line: /^\s*(@testable\s+|@_exported\s+|@preconcurrency\s+)*import\s/ },
  java: { line: /^\s*import\s/ },
  kt: { line: /^\s*import\s/ },
  kts: { line: /^\s*import\s/ },
  scala: { line: /^\s*import\s/ },
  dart: { line: /^\s*(import|export|part)\s+["']/ },
  c: { line: /^\s*#\s*(include|import)\b/ },
  h: { line: /^\s*#\s*(include|import)\b/ },
  cc: { line: /^\s*#\s*(include|import)\b/ },
  cpp: { line: /^\s*#\s*(include|import)\b/ },
  cxx: { line: /^\s*#\s*(include|import)\b/ },
  hpp: { line: /^\s*#\s*(include|import)\b/ },
  hh: { line: /^\s*#\s*(include|import)\b/ },
  m: { line: /^\s*(#\s*(include|import)\b|@import\s)/ },
  mm: { line: /^\s*(#\s*(include|import)\b|@import\s)/ },
  cs: { line: /^\s*(global\s+)?using\s+(static\s+)?[\w.]+(\s*=\s*[\w.<>]+)?\s*;/ },
  php: { line: /^\s*(use\s+[\w\\]+|require(_once)?\b|include(_once)?\b)/ },
  rb: { line: /^\s*require(_relative)?\s/ },
};

/** The import syntax of a file's language, by its extension; undefined when cmux knows none. */
export function importSyntaxFor(path: string): ImportSyntax | undefined {
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? SYNTAX_BY_EXTENSION[name.slice(dot + 1).toLowerCase()] : undefined;
}

/** The new path of a file's patch (`+++ b/<path>`), or its old one for a deletion. */
function patchPath(header: string): string | undefined {
  const next = /^\+\+\+ (?:b\/)?(.+)$/m.exec(header)?.[1];
  if (next && next !== "/dev/null") return next;
  const previous = /^--- (?:a\/)?(.+)$/m.exec(header)?.[1];
  return previous && previous !== "/dev/null" ? previous : undefined;
}

/**
 * Whether a hunk's changes are all imports: every changed line is an import line, a line inside
 * a multi-line import, or blank, and at least one is an import line. A line shaped like the
 * inside of an import (`a,`) with no block open in view counts only when the hunk then shows the
 * block's end before any other line: a block opened above the context. Else it is code.
 */
export function isImportOnlyHunk(hunk: string, syntax: ImportSyntax): boolean {
  let imports = 0;
  let inBlock = false;
  // Changed lines shaped like the inside of a block whose start is out of view.
  let unopened = 0;
  for (const line of hunk.split("\n").slice(1)) {
    const kind = line[0];
    if (kind !== "+" && kind !== "-" && kind !== " ") continue;
    const text = line.slice(1).replace(/\r$/, "");
    const blank = text.trim() === "";
    const opens = syntax.blockStart?.test(text) === true;
    const closes = syntax.blockEnd?.test(text) === true;
    if (inBlock || opens) {
      if (kind !== " " && !blank) imports += 1;
    } else if (closes && unopened > 0) {
      imports += unopened + (kind !== " " ? 1 : 0);
      unopened = 0;
    } else if (syntax.line.test(text)) {
      if (unopened > 0) return false;
      if (kind !== " ") imports += 1;
    } else if (!blank && syntax.continuation?.test(text) === true) {
      if (kind !== " ") unopened += 1;
    } else if (!blank) {
      if (kind !== " " || unopened > 0) return false;
    }
    if (opens) inBlock = true;
    else if (inBlock && closes) inBlock = false;
  }
  return unopened === 0 && imports > 0;
}

/**
 * A file's patch text without its import-only hunks: the same text when it has none (or cmux
 * knows no import syntax for its language), null when every hunk is one (the file leaves the
 * diff), else the header and the hunks that stay.
 */
export function withoutImportOnlyHunks(fileText: string): string | null {
  const firstHunk = fileText.startsWith("@@") ? 0 : fileText.indexOf("\n@@");
  if (firstHunk < 0) return fileText;
  const header = fileText.slice(0, firstHunk === 0 ? 0 : firstHunk + 1);
  const path = patchPath(header);
  const syntax = path ? importSyntaxFor(path) : undefined;
  if (!syntax) return fileText;
  const hunks = fileText.slice(header.length).split(/\n(?=@@ )/);
  const kept = hunks.filter((hunk) => !isImportOnlyHunk(hunk, syntax));
  if (kept.length === hunks.length) return fileText;
  if (kept.length === 0) return null;
  const body = kept.join("\n");
  return header + (body.endsWith("\n") ? body : `${body}\n`);
}
