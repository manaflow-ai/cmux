// The agent pane does not load ui/ui.css (main.tsx), so a ui/Menu popup draws only what the pane's
// own stylesheets give it. A MenuPopup without a class of the pane's shows its rows bare: the
// browser's font at its size, no row insets or hover, the check run into the name (Leo 2026-10-20,
// Retry's model menu: "why the FUCK is this still unstyled???"; the preview card's Open in menu too).
// Every MenuPopup in the pane names its look (.acpmux-quick-menu is the composer menus' one), a
// class the bundled pane's stylesheet styles (scripts/cmux-next/build-agent-pane-web.sh writes it;
// the gallery frame loads ui.css too, so a gallery shot never shows a bare menu); a Submenu wears
// its parent's unless it names its own.
import { beforeAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import ts from "typescript";

const webviews = path.resolve(import.meta.dir, "..");
const pane = path.join(webviews, "src/agent-session");

/** The page derives its sheets from dev.tsx's imports, just as the dev server does. */
let shippedCss: string;
beforeAll(() => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "pane-menus-styled-"));
  try {
    const list = path.join(work, "sheets.txt");
    const bundle = spawnSync(
      "bun",
      [
        "scripts/agent-pane/bundle.mjs",
        "src/agent-session/acpmux/dev.tsx",
        "src/agent-session/acpmux/shiki",
        path.join(work, "pane.js"),
        "--split",
        "--css-inputs",
        list,
        "--css-inputs-only",
      ],
      { cwd: webviews, encoding: "utf8", timeout: 120_000 },
    );
    expect(bundle.status, bundle.stderr).toBe(0);
    const sheets = fs.readFileSync(list, "utf8").split("\n").filter(Boolean);
    expect(sheets.length).toBeGreaterThan(0);
    shippedCss = sheets.map((sheet) => fs.readFileSync(path.join(webviews, sheet), "utf8")).join("\n");
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}, 130_000);
const styled = (name: string) => new RegExp(`\\.${name}(?![\\w-])`).test(shippedCss);

const sources = (dir: string): string[] =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) return sources(file);
    return entry.name.endsWith(".tsx") && !/\.(gallery|test)\.tsx$/.test(entry.name) ? [file] : [];
  });

/** Whether a className's literal classes include one the pane styles; a computed one is trusted. */
function namesStyledClass(initializer: ts.JsxAttributeValue | undefined): boolean {
  const literals: string[] = [];
  const collect = (node: ts.Node) => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) literals.push(node.text);
    else if (ts.isTemplateExpression(node)) {
      literals.push(node.head.text, ...node.templateSpans.map((span) => span.literal.text));
      node.templateSpans.forEach((span) => collect(span.expression));
    } else ts.forEachChild(node, collect);
  };
  if (initializer) collect(initializer);
  const classes = literals.flatMap((literal) => literal.split(/\s+/)).filter(Boolean);
  return classes.length === 0 || classes.some(styled);
}

/** Each `<MenuPopup …>` with no `className`, or none of whose classes the pane styles, as "file:line". */
function barePopups(file: string): string[] {
  const text = fs.readFileSync(file, "utf8");
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const found: string[] = [];
  const visit = (node: ts.Node) => {
    if (
      (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) &&
      node.tagName.getText(source) === "MenuPopup" &&
      !node.attributes.properties.some(
        (attribute) =>
          ts.isJsxSpreadAttribute(attribute) ||
          (attribute.name.getText(source) === "className" && namesStyledClass(attribute.initializer)),
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
  test("the bundled pane gives a ui/Menu its rows: insets, highlight, check, submenu chevron", () => {
    for (const rule of [
      ":where(.ui-menu-item)",
      ":where(.ui-menu-item[data-highlighted])",
      ":where(.ui-menu-check)",
      ":where(.ui-submenu-chevron)",
    ])
      expect(shippedCss).toContain(rule);
    expect(styled("acpmux-quick-menu")).toBe(true);
    expect(styled("acpmux-quick-item")).toBe(true);
  });

  test("every MenuPopup names a look the bundled pane styles", () => {
    const files = sources(pane);
    expect(files.length).toBeGreaterThan(0);
    expect(files.flatMap(barePopups)).toEqual([]);
  });
});
