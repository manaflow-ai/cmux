// The scanner behind test/pane-english.test.ts: user-visible English written in the agent pane's
// sources instead of its string table (acpmux/i18n.ts, Localizable.xcstrings). It parses each file
// with the TypeScript compiler and reports string literals that render: JSX text, string values of
// text attributes (placeholder, aria-label, title, label, alt), text fields of UI objects (label,
// title, name, text, rule, placeholder, hint, description, userMessage and the like), a function's
// result (`return "text"` or `() => "text"`: a label helper's text renders wherever it is called,
// unless it is a class list), the text shown when an error has no message, any text in a label table (a constant named *_LABELS, *_TITLES, *_TEXT or *_MESSAGES,
// or a camelCase *Strings table), a sentence given to a call or as a `message` parameter's
// default, and sentences given to an Error's constructor. Template literals count by their fixed
// text. A line (or the comment line above it) marked `l10n-allow: <reason>` is exempt, and so is
// a file whose header says `l10n-allow-file: <reason>`: product names, symbols, a caller's bug.
// A file exempt as not shipped (a header whose reason says "not shipped" or "prototype", or a file
// under prototype/) stays exempt only while no scanned file imports it: shipped code importing it
// is a finding at the import.
import fs from "node:fs";
import path from "node:path";
import * as ts from "typescript";

export const PANE = path.resolve(import.meta.dir, "../src/agent-session/acpmux");

const TEXT_ATTRIBUTES = new Set(["placeholder", "aria-label", "title", "label", "alt", "aria-description"]);
const TEXT_FIELDS = new Set([
  "label",
  "title",
  "placeholder",
  "hint",
  "description",
  "userMessage",
  "text",
  "name",
  "rule",
  "detail",
  "subtitle",
  "tooltip",
  "caption",
  "summary",
  "heading",
]);
/** Files that are not shipped pane UI: the dev loop, fixtures, measurement and automation. */
const SKIP =
  /\.test\.|\.d\.ts$|^(mock|mockFixture|mockFiles|mockGit|devHost|devRecents|dev|synthetic|workedTurn|debug|automation|perf|streamDebug|promptFieldTesting)\.tsx?$/;
const SKIP_DIRS = new Set(["prototype", "shiki", "generated"]);
const ALLOW = /l10n-allow:\s*\S/;
/** A file whose header says `l10n-allow-file: <reason>` is exempt as a whole (a wire validator). */
const ALLOW_FILE = /l10n-allow-file:\s*\S/;
const LABEL_TABLE = /^([A-Z_]*(LABELS?|TITLES?|TEXT|MESSAGES)|[a-z]\w*Strings)$/;

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

/** A function's result: `return "text"`, `() => "text"`, or one branch of either. A label helper
 * such as `toolCalls(n)` or `optionLabel(option)` hands its text straight to the UI. */
function returned(node: ts.Node): boolean {
  const current = valueRoot(node);
  return (
    ts.isReturnStatement(current.parent) || (ts.isArrowFunction(current.parent) && current.parent.body === current)
  );
}

/** A class list (`"bg-transparent hover:bg-hover"`): lowercase tokens, one with `-`, `:` or `_`. */
function classList(value: string): boolean {
  const tokens = value.trim().split(/\s+/);
  return tokens.every((token) => /^[a-z0-9:_\-[\]/.{}%!]+$/.test(token)) && tokens.some((token) => /[-:_]/.test(token));
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

/** A sentence handed on as an error's text: the default of a `message` parameter, or a sentence
 * (ending in . ! ? or …) given to any call, such as a validator's `record(value, "Invalid item.")`. */
function messageArgument(node: ts.Node, value: string): boolean {
  const parent = node.parent;
  if (ts.isParameter(parent) && parent.initializer === node) return /message$/i.test(parent.name.getText());
  if (!ts.isCallExpression(parent) || !parent.arguments.includes(node as ts.Expression)) return false;
  if (parent.expression.getText().startsWith("console.")) return false;
  return /[A-Za-z] [A-Za-z]/.test(value) && /[.!?…]$/.test(value.trim());
}

const isMessage = (node: ts.Node) => ts.isPropertyAccessExpression(node) && node.name.text === "message";

/** Shown in place of an error's message: the other branch of `error instanceof Error ?
 * error.message : "text"`, or the right side of `error.message ?? "text"` (or `||`). */
function fallsBackForMessage(node: ts.Node): boolean {
  const parent = node.parent;
  if (ts.isBinaryExpression(parent))
    return (
      parent.right === node &&
      [ts.SyntaxKind.QuestionQuestionToken, ts.SyntaxKind.BarBarToken].includes(parent.operatorToken.kind) &&
      isMessage(parent.left)
    );
  if (!ts.isConditionalExpression(parent) || parent.condition === node) return false;
  return isMessage(parent.whenTrue === node ? parent.whenFalse : parent.whenTrue);
}

/** Text handed to an Error's constructor, possibly as one branch of `??`, `||` or a condition. */
function errorArgument(node: ts.Node): boolean {
  const value = valueRoot(node);
  const parent = value.parent;
  return (
    ts.isNewExpression(parent) &&
    parent.expression.getText().endsWith("Error") &&
    (parent.arguments?.includes(value as ts.Expression) ?? false)
  );
}

/** An `l10n-allow-file` reason that says the file is not shipped UI (a prototype, a design study),
 * as opposed to text that ships but is not for a person (an agent's prompt, a gallery note). */
const NOT_SHIPPED = /l10n-allow-file:[^\n]*\b(not shipped|prototype)\b/i;

/** A file that says it is not shipped: its exemption says so, or it sits under prototype/ (below
 * the scanned root, so a checkout's own path never counts). */
function exemptAsNotShipped(root: string, file: string): boolean {
  if (path.relative(root, file).split(path.sep).includes("prototype")) return true;
  return NOT_SHIPPED.test(fs.readFileSync(file, "utf8").slice(0, 2000));
}

/** The module an import that ships code names: `import`/`export ... from` that is not type-only,
 * or a dynamic `import("...")` (a lazy-loaded panel ships too). */
function shippedImport(node: ts.Node): string | undefined {
  if (ts.isImportDeclaration(node))
    return node.importClause?.isTypeOnly || !ts.isStringLiteral(node.moduleSpecifier)
      ? undefined
      : node.moduleSpecifier.text;
  if (ts.isExportDeclaration(node))
    return node.isTypeOnly || !node.moduleSpecifier || !ts.isStringLiteral(node.moduleSpecifier)
      ? undefined
      : node.moduleSpecifier.text;
  if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword) {
    const [argument] = node.arguments;
    return argument && ts.isStringLiteralLike(argument) ? argument.text : undefined;
  }
  return undefined;
}

/** The source file a relative import names, if there is one. */
function resolveImport(from: string, specifier: string): string | undefined {
  if (!specifier.startsWith(".")) return undefined;
  const base = path.resolve(path.dirname(from), specifier);
  const candidates = [base, ...[".ts", ".tsx", "/index.ts", "/index.tsx"].map((ending) => base + ending)];
  return candidates.find((candidate) => /\.tsx?$/.test(candidate) && fs.existsSync(candidate));
}

/** A template literal's fixed text, with each substitution as `{}`. */
function templateText(node: ts.TemplateExpression): string {
  return node.head.text + node.templateSpans.map((span) => `{}${span.literal.text}`).join("");
}

export function scan(root: string = PANE): Finding[] {
  const findings: Finding[] = [];
  for (const file of files(root)) {
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
      findings.push({ file: path.relative(root, file), line: line + 1, text: value.trim().slice(0, 100) });
    };
    // A gallery entry is not shipped either, so it may import a prototype.
    const ships = !/\.gallery\.tsx?$/.test(file);
    const visit = (node: ts.Node) => {
      if (ts.isJsxText(node) && looksEnglish(node.text)) report(node, node.text);
      const specifier = ships ? shippedImport(node) : undefined;
      if (specifier !== undefined) {
        const target = resolveImport(file, specifier);
        if (target && exemptAsNotShipped(root, target))
          report(node, `imports ${path.relative(root, target)}, which is exempt as not shipped`);
      }
      const value = ts.isStringLiteralLike(node)
        ? node.text
        : ts.isTemplateExpression(node)
          ? templateText(node)
          : undefined;
      if (value !== undefined && looksEnglish(value)) {
        if (
          inTextAttribute(node) ||
          inJsxChild(node) ||
          inTextField(node) ||
          errorArgument(node) ||
          fallsBackForMessage(node) ||
          messageArgument(node, value) ||
          inLabelTable(node, text) ||
          (returned(node) && !classList(value))
        )
          report(node, value);
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  return findings;
}
