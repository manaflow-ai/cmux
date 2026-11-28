// The Settings row shape every card shares: `.row > .row-main > (.row-label + .row-control)`, and a label's
// title stacked over its help. Regression (RFD 0222 vault card, then Slack awake time): a row put its label and
// its control straight in `.row`, so the control fell to its own line under the label; and a label's
// `<span className="row-title">` ran into a bare `<span className="row-help">` ("Austin9 messages"), because a
// span is inline. A help span that opens with a space or a "·" is an inline status line on purpose (Cloud
// Environments, Hosts, Customize library) and passes.
import { Glob } from "bun";
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const pages = join(dirname(fileURLToPath(import.meta.url)), "..");

type Element = ts.JsxElement | ts.JsxSelfClosingElement;

function opening(node: Element): ts.JsxOpeningLikeElement {
  return ts.isJsxElement(node) ? node.openingElement : node;
}

function tagName(node: Element): string {
  return opening(node).tagName.getText();
}

function classes(node: Element): string[] {
  for (const attribute of opening(node).attributes.properties) {
    if (!ts.isJsxAttribute(attribute) || attribute.name.getText() !== "className") continue;
    const value = attribute.initializer;
    if (value && ts.isStringLiteral(value)) return value.text.split(/\s+/);
  }
  return [];
}

// The elements a JSX child list renders directly, looking through `{cond && <x/>}` and fragments.
function elementChildren(children: ts.NodeArray<ts.JsxChild>): Element[] {
  const out: Element[] = [];
  const visit = (node: ts.Node) => {
    if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node)) out.push(node);
    else if (ts.isJsxFragment(node)) node.children.forEach(visit);
    else if (ts.isJsxExpression(node) && node.expression) visit(node.expression);
    else if (ts.isBinaryExpression(node)) visit(node.right);
    else if (ts.isConditionalExpression(node)) {
      visit(node.whenTrue);
      visit(node.whenFalse);
    } else if (ts.isParenthesizedExpression(node)) visit(node.expression);
  };
  children.forEach(visit);
  return out;
}

// The first characters an element renders: its leading text, or the first string of its first expression.
function leadingText(node: ts.JsxElement): string {
  for (const child of node.children) {
    if (ts.isJsxText(child)) {
      // A same-line space before an expression (`<span> {source}</span>`) renders: an inline separator.
      if (child.text.trim() === "") {
        if (!child.text.includes("\n")) return " ";
        continue;
      }
      return child.text.replace(/^\s*\n\s*/, "");
    }
    if (ts.isJsxExpression(child) && child.expression) {
      const expression = child.expression;
      if (ts.isStringLiteral(expression) || ts.isNoSubstitutionTemplateLiteral(expression)) return expression.text;
      if (ts.isTemplateExpression(expression)) return expression.head.text;
      return "";
    }
    return "";
  }
  return "";
}

function insideButton(node: ts.Node): boolean {
  for (let parent = node.parent; parent; parent = parent.parent) {
    if ((ts.isJsxElement(parent) || ts.isJsxSelfClosingElement(parent)) && tagName(parent) === "button") return true;
  }
  return false;
}

function findings(file: string): string[] {
  const text = readFileSync(file, "utf8");
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const where = (node: ts.Node) =>
    `${relative(pages, file)}:${source.getLineAndCharacterOfPosition(node.getStart()).line + 1}`;
  const out: string[] = [];
  const visit = (node: ts.Node) => {
    if (ts.isJsxElement(node)) {
      const own = classes(node);
      const kids = elementChildren(node.children);
      if (own.includes("row")) {
        const label = kids.find((kid) => classes(kid).includes("row-label"));
        // A lone control (a component, an `output`, a `.row-control` or `.row-value`) beside the label belongs on
        // the label's line. A block under the label (accounts buttons, a form's fields) stacks on purpose.
        const control = kids.find(
          (kid) =>
            kid !== label &&
            (/^[A-Z]/.test(tagName(kid)) ||
              tagName(kid) === "output" ||
              classes(kid).some((name) => name === "row-control" || name === "row-value")),
        );
        if (label && control) {
          out.push(`${where(control)}: a control sits beside .row-label straight in .row; wrap both in .row-main`);
        }
      }
      // Inside a <button> only phrasing content is valid, so its label keeps spans and stacks them in CSS
      // (`.chiefs-row .row-label` is a column).
      if (own.includes("row-label") && !insideButton(node)) {
        kids.forEach((kid, index) => {
          const next = kids[index + 1];
          if (!next || !ts.isJsxElement(next)) return;
          if (tagName(kid) !== "span" || !classes(kid).includes("row-title")) return;
          if (tagName(next) !== "span" || !classes(next).includes("row-help")) return;
          if (/^[\s·]/.test(leadingText(next))) return;
          out.push(`${where(kid)}: span .row-title runs into a bare span .row-help; make both divs`);
        });
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return out;
}

test("every Settings row keeps label and control in .row-main, and a label's title over its help", () => {
  const files = [
    ...new Glob("settings/**/*.tsx").scanSync({ cwd: pages, absolute: true }),
    join(pages, "shared/signIn/AccountSwitcher.tsx"),
  ].filter((file) => !/\.(test|gallery)\.tsx$/.test(file));
  expect(files.length).toBeGreaterThan(30);
  expect(files.flatMap(findings)).toEqual([]);
});
