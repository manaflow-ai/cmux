// A cmux script's tokens for its opened row (CmuxExecDetails.tsx): keywords, strings and template
// literals, numbers and literals, comments and the functions it calls, each in the code color of
// its role (syntax-theme.ts), as a fenced ```js block reads. Synchronous and small, like the Shell
// block's lexer (shellHighlight.ts): a script is a few lines an agent wrote, and the row draws it
// at once, with no highlight worker to wait on. Every character is in exactly one token, in order,
// so the drawn text, its copy and Find in Chat read the script unchanged. It runs once per script
// (the details memoize on it), only while the row is open, and only over the first
// MAX_HIGHLIGHTED_SCRIPT characters; a longer tail draws plain.
import { agentSyntaxColor, SYNTAX_ROLES, type SyntaxRoleName } from "../../../syntax-theme";

export type CodeRole = "keyword" | "string" | "constant" | "comment" | "function" | "attribute";
export type CodeToken = { text: string; role?: CodeRole };

export const MAX_HIGHLIGHTED_SCRIPT = 20_000;

/// Each role's color: the pane's lifted ANSI slot, the default palette behind it.
export const CODE_ROLE_COLOR: Record<CodeRole, string> = Object.fromEntries(
  (["keyword", "string", "constant", "comment", "function", "attribute"] as const).map((role) => [
    role,
    agentSyntaxColor(SYNTAX_ROLES[role satisfies SyntaxRoleName], "dark", "inherit"),
  ]),
) as Record<CodeRole, string>;

const KEYWORDS = new Set(
  (
    "await async break case catch class const continue default delete do else export extends finally for " +
    "function if import in instanceof let new of return switch this throw try typeof var void while yield"
  ).split(" "),
);
const LITERALS = new Set(["true", "false", "null", "undefined", "NaN", "Infinity"]);

function push(out: CodeToken[], text: string, role?: CodeRole) {
  if (!text) return;
  const last = out[out.length - 1];
  if (last && last.role === role) last.text += text;
  else out.push(role ? { text, role } : { text });
}

/** The script's tokens, adjacent ones of one role merged. */
export function jsTokens(source: string): CodeToken[] {
  const src = source.slice(0, MAX_HIGHLIGHTED_SCRIPT);
  const out: CodeToken[] = [];
  let i = 0;
  while (i < src.length) {
    const c = src[i]!;
    const next = src[i + 1];
    if (c === "/" && next === "/") {
      const end = src.indexOf("\n", i);
      const stop = end < 0 ? src.length : end;
      push(out, src.slice(i, stop), "comment");
      i = stop;
    } else if (c === "/" && next === "*") {
      const end = src.indexOf("*/", i + 2);
      const stop = end < 0 ? src.length : end + 2;
      push(out, src.slice(i, stop), "comment");
      i = stop;
    } else if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < src.length && src[j] !== c && (c === "`" || src[j] !== "\n")) j += src[j] === "\\" ? 2 : 1;
      const stop = Math.min(j + 1, src.length);
      push(out, src.slice(i, stop), "string");
      i = stop;
    } else if (/[0-9]/.test(c) || (c === "." && next !== undefined && /[0-9]/.test(next))) {
      const match = /^(?:0[xXbBoO][\da-fA-F_]+|\d[\d_]*(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+)n?/.exec(src.slice(i));
      const text = match?.[0] || c;
      push(out, text, "constant");
      i += text.length;
    } else if (/[A-Za-z_$]/.test(c)) {
      const word = /^[A-Za-z_$][\w$]*/.exec(src.slice(i))![0];
      const after = /^\s*(\(|:(?!:))/.exec(src.slice(i + word.length));
      const prev = src.slice(0, i).trimEnd().slice(-1);
      const role: CodeRole | undefined = KEYWORDS.has(word)
        ? "keyword"
        : LITERALS.has(word)
          ? "constant"
          : after?.[1] === "("
            ? "function"
            : after?.[1] === ":" && (prev === "{" || prev === ",")
              ? "attribute"
              : undefined;
      push(out, word, role);
      i += word.length;
    } else {
      push(out, c);
      i += 1;
    }
  }
  if (src.length < source.length) push(out, source.slice(src.length));
  return out;
}
