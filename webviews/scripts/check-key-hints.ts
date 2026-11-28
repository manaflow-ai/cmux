// Every keyboard-shortcut hint in the web UI is drawn by one component: <KeyHint> (ui/KeyHint.tsx)
// in React, keyHintElement (ui/keyHintModel.ts) in DOM code. Leo 2026-11-22, on a tooltip's "^⌘M"
// plate: "fucking go pick the best and centralize our shit."
//
// This refuses ad-hoc key-hint markup anywhere else under src/:
//   a. a JSX <kbd> element;
//   b. createElement("kbd"), or a call with two or more arguments one of which is the literal "kbd"
//      (a local `make(doc, "kbd", ...)` helper); "kbd" inside an array (a sanitizer's allowed tags)
//      is fine;
//   c. a class string (className, class, `x.className =`, classList calls, cx/clsx/cn arguments) with
//      a keycap / kbd / keyhint / key-hint class other than the component's own;
//   d. a modifier glyph (⌘ ⌥ ⌃ ⇧) in JSX text, in a string that is a JSX child, or in a string
//      assigned to textContent / innerText (a shortcut drawn as raw text).
// And in stylesheets (not ui/keyHint.css, not the Markdown and GitHub pages, which style user
// content's <kbd>): a selector with such a class or a bare `kbd` type selector.
//
// A comment `key-hint-allow: <reason>` on the finding's line or the line above keeps one finding;
// the reason is required. test/check-key-hints.test.ts runs it; `bun scripts/check-key-hints.ts`
// runs it alone.
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../src");

/** The component's own files: the only places that may draw a key hint by hand. */
export const KEY_HINT_HOME = new Set(["ui/KeyHint.tsx", "ui/keyHintModel.ts"]);
const KEY_HINT_CSS = "ui/keyHint.css";
/** The component's own classes. */
const OWN_CLASSES = new Set(["ui-key-hint", "ui-key-hint-key", "ui-key-hint-then"]);
const HINT_CLASS = /(keycap|kbd|keyhint|key-hint)/i;
const MODIFIER = /[⌘⌥⌃⇧]/;
const CLASS_HELPERS = new Set(["cx", "clsx", "cn", "classNames", "classnames"]);
const ADVICE = "draw it with ui/KeyHint (or say key-hint-allow: <reason>)";

export type KeyHintFinding = { file: string; line: number; what: string };

/** True when `line` carries `key-hint-allow:` with a non-empty reason. */
function allows(line: string | undefined): boolean {
  const at = line?.indexOf("key-hint-allow:") ?? -1;
  if (at < 0) return false;
  const reason = line!
    .slice(at + "key-hint-allow:".length)
    .replace(/\*\/.*$/, "")
    .trim();
  return reason.length > 0;
}

function allowed(lines: string[], line: number): boolean {
  return allows(lines[line - 1]) || allows(lines[line - 2]);
}

function badClassTokens(text: string): string[] {
  return text.split(/\s+/).filter((token) => token && HINT_CLASS.test(token) && !OWN_CLASSES.has(token));
}

function isStringish(node: ts.Node): node is ts.StringLiteral | ts.NoSubstitutionTemplateLiteral {
  return ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node);
}

/** The literal text pieces (strings, template parts, object keys) anywhere inside a class expression. */
function classPieces(node: ts.Node): { node: ts.Node; text: string }[] {
  const pieces: { node: ts.Node; text: string }[] = [];
  const visit = (n: ts.Node) => {
    if (isStringish(n)) pieces.push({ node: n, text: n.text });
    else if (ts.isTemplateExpression(n)) {
      pieces.push({ node: n, text: n.head.text });
      for (const span of n.templateSpans) {
        visit(span.expression);
        pieces.push({ node: span.literal, text: span.literal.text });
      }
      return;
    } else if (ts.isPropertyAssignment(n) || ts.isShorthandPropertyAssignment(n)) {
      if (ts.isStringLiteral(n.name) || ts.isIdentifier(n.name)) pieces.push({ node: n.name, text: n.name.text });
    }
    ts.forEachChild(n, visit);
  };
  visit(node);
  return pieces;
}

/** The string-ish expressions a JSX child or a text assignment resolves to (through ?:, &&, ||, ??). */
function textValues(node: ts.Expression): ts.Expression[] {
  if (ts.isParenthesizedExpression(node)) return textValues(node.expression);
  if (ts.isConditionalExpression(node)) return [...textValues(node.whenTrue), ...textValues(node.whenFalse)];
  if (
    ts.isBinaryExpression(node) &&
    [
      ts.SyntaxKind.AmpersandAmpersandToken,
      ts.SyntaxKind.BarBarToken,
      ts.SyntaxKind.QuestionQuestionToken,
      ts.SyntaxKind.PlusToken,
    ].includes(node.operatorToken.kind)
  )
    return [...textValues(node.left), ...textValues(node.right)];
  if (isStringish(node) || ts.isTemplateExpression(node)) return [node];
  return [];
}

function literalText(node: ts.Expression): string {
  if (isStringish(node)) return node.text;
  if (ts.isTemplateExpression(node)) return node.head.text + node.templateSpans.map((s) => s.literal.text).join("");
  return "";
}

function calleeName(expr: ts.Expression): string | undefined {
  if (ts.isIdentifier(expr)) return expr.text;
  if (ts.isPropertyAccessExpression(expr)) return expr.name.text;
  return undefined;
}

/** Ad-hoc key-hint markup in one .ts/.tsx file (`file` is its path under src/). */
export function keyHintFindings(file: string, text: string): KeyHintFinding[] {
  if (KEY_HINT_HOME.has(file)) return [];
  const kind = file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, kind);
  const lines = text.split("\n");
  const findings: KeyHintFinding[] = [];
  const seen = new Set<string>();
  const report = (node: ts.Node, what: string) => {
    const line = source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1;
    const key = `${line}:${what}`;
    if (seen.has(key) || allowed(lines, line)) return;
    seen.add(key);
    findings.push({ file, line, what });
  };
  const checkClasses = (node: ts.Node) => {
    for (const piece of classPieces(node))
      for (const token of badClassTokens(piece.text)) report(piece.node, `class "${token}"`);
  };
  const checkText = (node: ts.Expression, where: string) => {
    for (const value of textValues(node))
      if (MODIFIER.test(literalText(value)))
        report(value, `shortcut text ${JSON.stringify(literalText(value))} ${where}`);
  };

  const visit = (node: ts.Node) => {
    // a. <kbd>
    if (
      (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) &&
      ts.isIdentifier(node.tagName) &&
      node.tagName.text === "kbd"
    )
      report(node, "<kbd> element");

    if (ts.isCallExpression(node)) {
      const name = calleeName(node.expression);
      // b. createElement("kbd"), make(doc, "kbd", ...)
      const kbdArg = node.arguments.some((arg) => isStringish(arg) && arg.text.toLowerCase() === "kbd");
      if (kbdArg && (name === "createElement" || node.arguments.length >= 2)) report(node, `${name ?? "call"}("kbd")`);
      // c. classList.add("x-keycap"), cx("x-keycap", ...), setAttribute("class", ...)
      const target = ts.isPropertyAccessExpression(node.expression) ? node.expression.expression : undefined;
      if (
        name &&
        ["add", "toggle", "remove", "replace"].includes(name) &&
        target &&
        ts.isPropertyAccessExpression(target) &&
        target.name.text === "classList"
      )
        for (const arg of node.arguments) checkClasses(arg);
      else if (name && CLASS_HELPERS.has(name)) for (const arg of node.arguments) checkClasses(arg);
      else if (
        name === "setAttribute" &&
        node.arguments.length >= 2 &&
        isStringish(node.arguments[0]!) &&
        node.arguments[0].text === "class"
      )
        checkClasses(node.arguments[1]!);
    }

    // c. className="..." / class="..." / className={...}
    if (
      ts.isJsxAttribute(node) &&
      ts.isIdentifier(node.name) &&
      ["className", "class"].includes(node.name.text) &&
      node.initializer
    )
      checkClasses(node.initializer);
    // c. { className: "..." } (props objects, DOM builders)
    if (
      ts.isPropertyAssignment(node) &&
      (ts.isIdentifier(node.name) || ts.isStringLiteral(node.name)) &&
      ["className", "class"].includes(node.name.text)
    )
      checkClasses(node.initializer);

    if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
      const prop = ts.isPropertyAccessExpression(node.left) ? node.left.name.text : undefined;
      // c. el.className = "..."
      if (prop === "className") checkClasses(node.right);
      // d. el.textContent = "⌘K"
      if (prop === "textContent" || prop === "innerText") checkText(node.right, `assigned to ${prop}`);
    }

    // d. <span>⌘K</span>
    if (ts.isJsxText(node) && MODIFIER.test(node.text))
      report(node, `shortcut text ${JSON.stringify(node.text.trim())} in JSX`);
    // d. <span>{"⌃⌘M"}</span>
    if (ts.isJsxExpression(node) && node.expression && (ts.isJsxElement(node.parent) || ts.isJsxFragment(node.parent)))
      checkText(node.expression, "as a JSX child");

    ts.forEachChild(node, visit);
  };
  visit(source);
  return findings;
}

/** Key-hint selectors in one stylesheet (`file` is its path under src/). */
export function cssKeyHintFindings(file: string, text: string): KeyHintFinding[] {
  if (file === KEY_HINT_CSS) return [];
  const lines = text.split("\n");
  const lineOf = (index: number) => text.slice(0, index).split("\n").length;
  // Comments and strings go to spaces so offsets (and lines) stay; the allow comment is read raw.
  const plain = text
    .replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "))
    .replace(/"[^"\n]*"|'[^'\n]*'/g, (str) => str.replace(/[^\n]/g, " "));
  const findings: KeyHintFinding[] = [];
  const seen = new Set<string>();
  const prelude = /([^{};]+)\{/g;
  for (let match = prelude.exec(plain); match; match = prelude.exec(plain)) {
    const selector = match[1]!;
    if (selector.trim().startsWith("@")) continue;
    const hits: { index: number; what: string }[] = [];
    for (const cls of selector.matchAll(/\.(-?[_a-zA-Z][\w-]*)/g))
      if (HINT_CLASS.test(cls[1]!) && !OWN_CLASSES.has(cls[1]!))
        hits.push({ index: cls.index!, what: `selector class .${cls[1]}` });
    for (const type of selector.matchAll(/(^|[\s>+~,(])kbd(?![\w-])/gi))
      hits.push({ index: type.index! + type[1]!.length, what: "kbd type selector" });
    for (const hit of hits.sort((a, b) => a.index - b.index)) {
      const line = lineOf(match.index + hit.index);
      if (seen.has(`${line}:${hit.what}`) || allowed(lines, line)) continue;
      seen.add(`${line}:${hit.what}`);
      findings.push({ file, line, what: hit.what });
    }
  }
  return findings;
}

/** Stylesheets that style user content's <kbd> (rendered Markdown, GitHub HTML) keep their own. */
function userContentCss(file: string): boolean {
  return (
    file.startsWith("pages/markdown/") ||
    file.startsWith("pages/github/") ||
    /markdown/i.test(file) ||
    file.includes("githubHTML")
  );
}

function walk(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (entry.name === "node_modules") return [];
    const path = join(dir, entry.name);
    return entry.isDirectory() ? walk(path) : [path];
  });
}

/** Every finding under src/. */
export function findAllKeyHints(srcDir: string = SRC): KeyHintFinding[] {
  const findings: KeyHintFinding[] = [];
  for (const path of walk(srcDir)) {
    const file = relative(srcDir, path).replaceAll("\\", "/");
    const name = file.slice(file.lastIndexOf("/") + 1);
    if (/\.test\./.test(name) || name.endsWith(".d.ts")) continue;
    if (/\.tsx?$/.test(name)) findings.push(...keyHintFindings(file, readFileSync(path, "utf8")));
    else if (name.endsWith(".css") && !userContentCss(file))
      findings.push(...cssKeyHintFindings(file, readFileSync(path, "utf8")));
  }
  return findings;
}

if (import.meta.main) {
  const found = findAllKeyHints();
  for (const f of found) console.error(`key hints: ${f.file}:${f.line}: ${f.what} — ${ADVICE}`);
  if (found.length) process.exitCode = 1;
  else console.log("Key hints checked: every shortcut is drawn by ui/KeyHint.");
}
