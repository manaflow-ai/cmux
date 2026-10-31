// The chat's pull requests (summary/PullRequestStack.tsx: the "N PRs" count and the chips it opens)
// are a part of the composer's own element in App.tsx, never a sibling of it: where the composer is
// not shown (a handoff review, `reviewing`; the Sandboxed run's receipt shown in the chat's place,
// `viewedSandbox`; a subagent's read-only pane) they are not either, so the bottom stack can never
// show pull requests without its composer. Read from the source's syntax tree: their provider is
// the `composer` constant's `!reviewing && (...)` branch itself, every part of them is inside it,
// and `composer` is drawn only under `!viewedSandbox`.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import ts from "typescript";

const file = path.resolve(import.meta.dir, "../src/agent-session/acpmux/App.tsx");
const source = ts.createSourceFile(file, readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

function all(node: ts.Node, match: (node: ts.Node) => boolean, found: ts.Node[] = []): ts.Node[] {
  if (match(node)) found.push(node);
  node.forEachChild((child) => void all(child, match, found));
  return found;
}
const jsxNamed = (name: string) => (node: ts.Node) =>
  (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) && node.tagName.getText() === name;
const bare = (node: ts.Expression): ts.Expression =>
  ts.isParenthesizedExpression(node) ? bare(node.expression) : node;
const within = (inner: ts.Node, outer: ts.Node) =>
  inner.getStart() >= outer.getStart() && inner.getEnd() <= outer.getEnd();

const stacks = all(source, jsxNamed("PullRequestStackProvider"));
const parts = ["PullRequestList", "PullRequestCountInStack"].flatMap((name) => all(source, jsxNamed(name)));
const composer = all(
  source,
  (node) => ts.isVariableDeclaration(node) && node.name.getText() === "composer" && node.initializer !== undefined,
) as ts.VariableDeclaration[];

test("the pull requests' provider is mounted once, inside the composer element, and holds every part of them", () => {
  expect(stacks.length).toBe(1);
  expect(composer.length).toBe(1);
  expect(within(stacks[0]!, composer[0]!.initializer!)).toBe(true);
  expect(parts.length).toBeGreaterThanOrEqual(3);
  const provider = stacks[0]!.parent;
  for (const part of parts) expect(within(part, provider)).toBe(true);
});

test("in a handoff review the composer element, and so the N PRs row, is not drawn", () => {
  // `readOnlySubagent ? <footer> : !reviewing && (<>…</>)`: the row sits in the `!reviewing` branch.
  const init = bare(composer[0]!.initializer!);
  expect(ts.isConditionalExpression(init)).toBe(true);
  const branch = bare((init as ts.ConditionalExpression).whenFalse);
  expect(ts.isBinaryExpression(branch) && branch.left.getText()).toBe("!reviewing");
  expect(within(stacks[0]!, (branch as ts.BinaryExpression).right)).toBe(true);
});

test("while the Sandboxed run's receipt shows, the composer element, and so the N PRs row, is not drawn", () => {
  // Every place the chat pane draws `composer` as a child is the right end of a chain that includes
  // `!viewedSandbox`. The Quick Composer takes it as a prop (QuickSurface), and the row is never
  // mounted there (`!quick`, next test).
  // Each read of `composer` (not its declaration), by the nearest JSX expression around it.
  const uses = all(
    source,
    (node) => ts.isIdentifier(node) && node.text === "composer" && !ts.isVariableDeclaration(node.parent),
  )
    .map((identifier) => {
      let node: ts.Node = identifier;
      while (node && !ts.isJsxExpression(node)) node = node.parent;
      return node as ts.JsxExpression | undefined;
    })
    .filter((use): use is ts.JsxExpression => use !== undefined && !ts.isJsxAttribute(use.parent));
  expect(uses.length).toBeGreaterThan(0);
  for (const use of uses) {
    const expression = bare(use.expression!);
    expect(ts.isBinaryExpression(expression) && expression.operatorToken.kind).toBe(
      ts.SyntaxKind.AmpersandAmpersandToken,
    );
    const chain = expression as ts.BinaryExpression;
    expect(chain.right.getText()).toBe("composer");
    expect(chain.left.getText()).toContain("!viewedSandbox");
  }
});

test("the Quick Composer, which takes the composer as a prop, gets no pull requests", () => {
  const prs = (stacks[0] as ts.JsxOpeningElement).attributes.properties.find(
    (attribute) => ts.isJsxAttribute(attribute) && attribute.name.getText() === "prs",
  );
  expect(prs?.getText()).toMatch(/^prs=\{quick \|\| /);
});
