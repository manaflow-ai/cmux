// The scanner behind test/pane-english.test.ts: user-visible English written in the agent pane's
// sources instead of its string table (acpmux/i18n.ts, Localizable.xcstrings). It parses each file
// with the TypeScript compiler and reports string literals that render: JSX text, string values of
// text attributes (placeholder, aria-label, title, label, alt), text fields of UI objects (label,
// title, placeholder, hint, description, userMessage), the text shown when an error has no message, any text in a label table (a constant named
// *_LABELS, *_TITLES, *_TEXT or *_MESSAGES), and English sentences given to an Error's constructor. Template
// literals count by their fixed text.
// A line (or the comment line above it) marked `l10n-allow: <reason>` is exempt, and so is a file
// whose header says `l10n-allow-file: <reason>`: protocol
// validation text that never shows, product names, symbols.
import fs from "node:fs";
import path from "node:path";
import * as ts from "typescript";

export const PANE = path.resolve(import.meta.dir, "../src/agent-session/acpmux");

const TEXT_ATTRIBUTES = new Set(["placeholder", "aria-label", "title", "label", "alt", "aria-description"]);
const TEXT_FIELDS = new Set(["label", "title", "placeholder", "hint", "description", "userMessage"]);
/** Files that are not shipped pane UI: the dev loop, fixtures, measurement and automation. */
const SKIP =
  /\.test\.|\.d\.ts$|^(mock|mockFixture|mockFiles|mockGit|devHost|devRecents|dev|synthetic|workedTurn|debug|automation|perf|streamDebug|promptFieldTesting)\.tsx?$/;
const SKIP_DIRS = new Set(["prototype", "shiki", "generated"]);
const ALLOW = /l10n-allow:\s*\S/;
/** A file whose header says `l10n-allow-file: <reason>` is exempt as a whole (a wire validator). */
const ALLOW_FILE = /l10n-allow-file:\s*\S/;
const LABEL_TABLE = /^[A-Z_]*(LABELS?|TITLES?|TEXT|MESSAGES)$/;

/** Text a person reads: two letters in a row, and a space or a capitalized word. */
export function looksEnglish(text: string): boolean {
  const value = text.trim();
  return /[A-Za-z]{2}/.test(value) && (/[A-Za-z] [A-Za-z]/.test(value) || /^[A-Z][a-z]{2,}[.…!?]?$/.test(value));
}

export interface Finding {
  file: string;
  line: number;
  text: string;
}

function files(dir: string): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) out.push(...files(full));
    } else if (/\.(ts|tsx)$/.test(entry.name) && !SKIP.test(entry.name)) out.push(full);
  }
  return out;
}

function inTextAttribute(node: ts.Node): boolean {
  for (let current: ts.Node | undefined = node.parent; current; current = current.parent) {
    if (ts.isJsxAttribute(current)) return TEXT_ATTRIBUTES.has(current.name.getText());
    if (ts.isJsxElement(current) || ts.isJsxSelfClosingElement(current) || ts.isFunctionLike(current)) return false;
  }
  return false;
}

/** The value of a text field of a UI object, possibly one branch of a condition. */
function inTextField(node: ts.Node): boolean {
  const current = valueRoot(node);
  return ts.isPropertyAssignment(current.parent) && TEXT_FIELDS.has(current.parent.name.getText().replace(/["']/g, ""));
}

/** The outermost expression whose value can be `node`: through conditions, `??`/`||` and parentheses. */
function valueRoot(node: ts.Node): ts.Node {
  let current: ts.Node = node;
  while (
    (ts.isConditionalExpression(current.parent) && current.parent.condition !== current) ||
    (ts.isBinaryExpression(current.parent) &&
      [ts.SyntaxKind.QuestionQuestionToken, ts.SyntaxKind.BarBarToken, ts.SyntaxKind.AmpersandAmpersandToken].includes(
        current.parent.operatorToken.kind,
      )) ||
    ts.isParenthesizedExpression(current.parent)
  )
    current = current.parent;
  return current;
}

/** A string rendered as a JSX child: `{"text"}` or `{cond ? "a" : "b"}`. */
function inJsxChild(node: ts.Node): boolean {
  const current = valueRoot(node);
  return ts.isJsxExpression(current.parent) && !ts.isJsxAttribute(current.parent.parent);
}

/** Inside the value of a label table constant (`const MARK_LABELS = { ... }`), unless the comment
 * above the table marks all of it `l10n-allow:` (a table of language names). */
function inLabelTable(node: ts.Node, text: string): boolean {
  for (let current: ts.Node | undefined = node.parent; current; current = current.parent)
    if (ts.isVariableDeclaration(current)) {
      if (!ts.isIdentifier(current.name) || !LABEL_TABLE.test(current.name.text)) return false;
      const statement = current.parent.parent;
      const comments = ts.getLeadingCommentRanges(text, statement.getFullStart()) ?? [];
      return !comments.some((range) => ALLOW.test(text.slice(range.pos, range.end)));
    }
  return false;
}

/** The other branch of `error instanceof Error ? error.message : "text"`: shown in its place. */
function fallsBackForMessage(node: ts.Node): boolean {
  const parent = node.parent;
  if (!ts.isConditionalExpression(parent) || parent.condition === node) return false;
  const other = parent.whenTrue === node ? parent.whenFalse : parent.whenTrue;
  return ts.isPropertyAccessExpression(other) && other.name.text === "message";
}

/** A template literal's fixed text, with each substitution as `{}`. */
function templateText(node: ts.TemplateExpression): string {
  return node.head.text + node.templateSpans.map((span) => `{}${span.literal.text}`).join("");
}

export function scan(): Finding[] {
  const findings: Finding[] = [];
  for (const file of files(PANE)) {
    const text = fs.readFileSync(file, "utf8");
    if (ALLOW_FILE.test(text.slice(0, 2000))) continue;
    const lines = text.split("\n");
    const source = ts.createSourceFile(
      file,
      text,
      ts.ScriptTarget.Latest,
      true,
      file.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
    );
    const report = (node: ts.Node, value: string) => {
      const line = source.getLineAndCharacterOfPosition(node.getStart()).line;
      if (
        ALLOW.test(lines[line] ?? "") ||
        (line > 0 && /^\s*(\/\/|\{\/\*|\*)/.test(lines[line - 1] ?? "") && ALLOW.test(lines[line - 1] ?? ""))
      )
        return;
      findings.push({ file: path.relative(PANE, file), line: line + 1, text: value.trim().slice(0, 100) });
    };
    const visit = (node: ts.Node) => {
      if (ts.isJsxText(node) && looksEnglish(node.text)) report(node, node.text);
      const value = ts.isStringLiteralLike(node)
        ? node.text
        : ts.isTemplateExpression(node)
          ? templateText(node)
          : undefined;
      if (value !== undefined && looksEnglish(value)) {
        const parent = node.parent;
        if (
          inTextAttribute(node) ||
          inJsxChild(node) ||
          inTextField(node) ||
          (ts.isNewExpression(parent) &&
            parent.expression.getText().endsWith("Error") &&
            parent.arguments?.includes(node as ts.Expression)) ||
          fallsBackForMessage(node) ||
          inLabelTable(node, text)
        )
          report(node, value);
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  return findings;
}
