// The agent pane does not load ui/ui.css (main.tsx), so a ui/Menu popup draws only what the pane's
// own stylesheets give it. A MenuPopup without a class of the pane's shows its rows bare: the
// browser's font at its size, no row insets or hover, the check run into the name (Leo 2026-10-20,
// Retry's model menu: "why the FUCK is this still unstyled???"; the preview card's Open in menu too).
// Every MenuPopup in the pane names its look (.acpmux-quick-menu is the composer menus' one); a
// Submenu wears its parent's unless it names its own.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";

const pane = path.resolve(import.meta.dir, "../src/agent-session");

const sources = (dir: string): string[] =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) return sources(file);
    return /\.tsx$/.test(entry.name) && !/\.(gallery|test)\.tsx$/.test(entry.name) ? [file] : [];
  });

/** Each `<MenuPopup …>` with no `className`, as "file:line". */
function barePopups(file: string): string[] {
  const text = fs.readFileSync(file, "utf8");
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const found: string[] = [];
  const visit = (node: ts.Node) => {
    if (
      (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) &&
      node.tagName.getText(source) === "MenuPopup" &&
      !node.attributes.properties.some(
        (attribute) => ts.isJsxSpreadAttribute(attribute) || attribute.name.getText(source) === "className",
      )
    ) {
      const { line } = source.getLineAndCharacterOfPosition(node.getStart(source));
      found.push(`${path.relative(pane, file)}:${line + 1}`);
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return found;
}

describe("agent pane menus", () => {
  test("every MenuPopup names the pane's menu look", () => {
    const files = sources(pane);
    expect(files.length).toBeGreaterThan(0);
    expect(files.flatMap(barePopups)).toEqual([]);
  });
});
