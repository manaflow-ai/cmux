// The scanner behind test/tooltip-rules.test.ts (Leo, 2026-10-13; revised 2026-10-20): a tooltip
// only names a control that shows no text of its own, an icon-only button, or carries a keyboard
// shortcut. A row, chip, link, path or thought whose text is on screen gets no tooltip. A pull
// request's or link's cut-off title gets a styled hover card instead (ui/Tooltip.tsx AnchoredCard:
// chips/PullRequestCard.tsx, the link chips' preview card), with what the text can't show: the
// full title and the facts behind it. Plain decorative text gets neither. It reads the page code's
// JSX: an HTML element with `title` or `data-tooltip` and text inside it, and a ui/Tooltip around
// such an element; a hover card is no tooltip.
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";

export const SRC = path.resolve(import.meta.dir, "../src");

/** A line (or the line above it) marked `tooltip-allow: <reason>` is exempt. */
const ALLOW = /tooltip-allow:\s*\S/;
/** An expression child named like an icon draws no text. */
const ICON = /icon|glyph|svg|mark|spinner|avatar|dot|image|img/i;
/** A label only screen readers read. */
const HIDDEN = /hidden-label|visually-hidden|sr-only/;
/** The page's developer tools, not the app's. */
const TOOLS = new Set(["gallery", "optchat-inspector"]);
/** A component's props that hold the text it draws. */
const TEXT_PROPS = new Set(["text", "label"]);

export interface TooltipViolation {
  file: string;
  line: number;
  text: string;
}

function pageFiles(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "generated" || TOOLS.has(entry.name) ? [] : pageFiles(full);
    return entry.name.endsWith(".tsx") && !/\.(test|gallery)\.tsx$/.test(entry.name) ? [full] : [];
  });
}

const intrinsic = (tag: ts.JsxTagNameExpression) => /^[a-z]/.test(tag.getText());

/** Whether `node`, a JSX child or an expression in one, puts text on screen. */
function showsText(node: ts.Node): boolean {
  // A lone glyph such as × or ↺ draws a symbol, not words.
  if (ts.isJsxText(node)) return /[\p{L}\p{N}]/u.test(node.text);
  if (ts.isJsxExpression(node)) return node.expression !== undefined && showsText(node.expression);
  if (ts.isParenthesizedExpression(node)) return showsText(node.expression);
  if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node)) {
    const open = ts.isJsxElement(node) ? node.openingElement : node;
    const attrs = open.attributes.properties.filter(ts.isJsxAttribute);
    const children = ts.isJsxElement(node) ? node.children : ts.factory.createNodeArray<ts.JsxChild>();
    if (!intrinsic(open.tagName)) {
      // A component draws text it is handed (`<Highlight text=…>`) or holds, unless it is an icon.
      if (ICON.test(open.tagName.getText())) return false;
      return attrs.some((attr) => TEXT_PROPS.has(attr.name.getText())) || children.some(showsText);
    }
    const className = attrs.find((attr) => attr.name.getText() === "className");
    return !(className && HIDDEN.test(className.getText())) && children.some(showsText);
  }
  if (ts.isJsxFragment(node)) return node.children.some(showsText);
  if (ts.isConditionalExpression(node)) return showsText(node.whenTrue) || showsText(node.whenFalse);
  if (ts.isBinaryExpression(node)) {
    const op = node.operatorToken.kind;
    if (op === ts.SyntaxKind.AmpersandAmpersandToken) return showsText(node.right);
    if (op === ts.SyntaxKind.BarBarToken || op === ts.SyntaxKind.QuestionQuestionToken)
      return showsText(node.left) || showsText(node.right);
    return op === ts.SyntaxKind.PlusToken;
  }
  if (ts.isStringLiteralLike(node) || ts.isTemplateExpression(node) || ts.isNumericLiteral(node)) return true;
  if (ts.isIdentifier(node) || ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node))
    return !ICON.test(node.getText());
  if (ts.isCallExpression(node)) {
    // `.map(...)` of rows renders whatever its callback returns.
    const callee = node.expression;
    if (ts.isPropertyAccessExpression(callee) && callee.name.text === "map") {
      const fn = node.arguments[0];
      if (fn && (ts.isArrowFunction(fn) || ts.isFunctionExpression(fn)))
        return ts.isBlock(fn.body) ? false : showsText(fn.body);
      return false;
    }
    return !ICON.test(callee.getText());
  }
  return false;
}

const TOOLTIP_ATTRS = new Set(["title", "data-tooltip"]);

export function scan(): TooltipViolation[] {
  const violations: TooltipViolation[] = [];
  for (const file of pageFiles(SRC)) {
    const source = fs.readFileSync(file, "utf8");
    const lines = source.split("\n");
    const sf = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
    const report = (at: ts.Node) => {
      const line = sf.getLineAndCharacterOfPosition(at.getStart()).line;
      if (ALLOW.test(lines[line]) || (line > 0 && ALLOW.test(lines[line - 1]))) return;
      violations.push({ file: path.relative(SRC, file), line: line + 1, text: lines[line].trim() });
    };
    const walk = (node: ts.Node) => {
      if (ts.isJsxElement(node)) {
        const open = node.openingElement;
        if (intrinsic(open.tagName) && node.children.some(showsText)) {
          const attrs = open.attributes.properties.filter(ts.isJsxAttribute);
          const tooltip = attrs.find((attr) => TOOLTIP_ATTRS.has(attr.name.getText()));
          const shortcut = attrs.some((attr) => attr.name.getText() === "data-tooltip-shortcut");
          if (tooltip && !shortcut) report(tooltip);
        }
        // A ui/Tooltip around an element whose own text already shows.
        if (open.tagName.getText() === "Tooltip") {
          const shortcut = open.attributes.properties.some(
            (attr) => ts.isJsxAttribute(attr) && attr.name.getText() === "shortcut",
          );
          if (!shortcut && node.children.some((child) => ts.isJsxElement(child) && child.children.some(showsText)))
            report(open);
        }
      }
      ts.forEachChild(node, walk);
    };
    walk(sf);
  }
  return violations;
}
