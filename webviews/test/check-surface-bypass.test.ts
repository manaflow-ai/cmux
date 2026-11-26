// The surface-bypass ratchet (scripts/check-surface-bypass.ts): the four kinds it counts, what it exempts,
// and how the baseline compares.
import { expect, test } from "bun:test";
import {
  counts,
  exempt,
  findCssBypasses,
  findJsxBypasses,
  isThemeFile,
  ratchetErrors,
  type Finding,
} from "../scripts/check-surface-bypass";

const kinds = (found: Finding[]) => found.map((f) => `${f.kind}:${f.line}`);

test("a raw <button is counted, a <Button> and a button in a string are not", () => {
  const source = [
    "export const A = () => (",
    "  <div>",
    "    <button onClick={go}>Go</button>",
    "    <Button onClick={go}>Go</Button>",
    '    <p>{"<button>"}</p>',
    "    <button />",
    "  </div>",
    ");",
  ].join("\n");
  expect(kinds(findJsxBypasses("a/A.tsx", source))).toEqual(["raw-button:3", "raw-button:6"]);
});

test("a title= attribute on an element is counted; a component prop and an svg <title> element are not", () => {
  const source = [
    "export const A = () => (",
    "  <div>",
    '    <span title="Copy">c</span>',
    '    <Card title="Heading" />',
    "    <svg><title>icon</title></svg>",
    '    <a href="#" title={label}>x</a>',
    "  </div>",
    ");",
  ].join("\n");
  expect(kinds(findJsxBypasses("a/A.tsx", source))).toEqual(["title-attribute:3", "title-attribute:6"]);
});

test("a rule with backdrop-filter, or box-shadow with border-radius and a background, builds its own shell", () => {
  const css = [
    ".a { backdrop-filter: blur(8px); }",
    ".b { -webkit-backdrop-filter: blur(8px); }",
    ".c {",
    "  background: var(--x);",
    "  border-radius: 8px;",
    "  box-shadow: 0 1px 2px black;",
    "}",
    "@media (prefers-contrast: more) { .d { background: red; border-radius: 4px; box-shadow: none; } }",
  ].join("\n");
  expect(kinds(findCssBypasses("a/a.css", css))).toEqual(["own-shell:1", "own-shell:2", "own-shell:6", "own-shell:8"]);
});

test("a rule that uses a --surface- variable, has no background, or turns the backdrop off is not an own shell", () => {
  const css = [
    ".a { backdrop-filter: blur(8px); background: var(--surface-card-fill); }",
    ".b { border-radius: 8px; box-shadow: 0 1px 2px black; }",
    ".c { backdrop-filter: none; }",
    ".d { background: transparent; border-radius: 8px; box-shadow: 0 1px 2px black; }",
    "@keyframes k { from { box-shadow: 0 0 1px red; border-radius: 1px; background: red; } }",
  ].join("\n");
  expect(findCssBypasses("a/a.css", css)).toEqual([]);
});

test("a --surface-<role>-* declaration or a .ui-surface selector outside a theme file is an override", () => {
  const css = [
    ".feature { --surface-card-radius: 4px; --surface-other: 1; }",
    ".feature .ui-surface { padding: 0; }",
    ".ui-surface-title { color: red; }",
    ".x { color: var(--surface-card-fill); }",
  ].join("\n");
  expect(kinds(findCssBypasses("feature/feature.css", css))).toEqual(["surface-override:1", "surface-override:2"]);
});

test("a theme file may override the role variables", () => {
  const css = ":root { --surface-card-radius: 4px; }\n.ui-surface { opacity: 1; }";
  expect(findCssBypasses("theme/messages.css", css)).toEqual([]);
  expect(findCssBypasses("apps/theme-dark.css", css)).toEqual([]);
  expect(isThemeFile("theme/appTheme.ts")).toBe(true);
  expect(isThemeFile("themes/x.css")).toBe(false);
  expect(isThemeFile("feature/feature.css")).toBe(false);
});

test("src/ui/, galleries and tests are exempt", () => {
  expect(exempt("ui/Button.tsx")).toBe(true);
  expect(exempt("ui/surface/surface.css")).toBe(true);
  expect(exempt("agent-session/Card.gallery.tsx")).toBe(true);
  expect(exempt("agent-session/Card.gallery.css")).toBe(true);
  expect(exempt("agent-session/Card.test.tsx")).toBe(true);
  expect(exempt("agent-session/Card.tsx")).toBe(false);
  expect(exempt("ui-kit/Card.tsx")).toBe(false);
});

test("a file over its baseline row names each finding, what to use and the override; under it, asks to lower", () => {
  const findings: Finding[] = [
    { file: "a/A.tsx", line: 3, kind: "raw-button" },
    { file: "a/A.tsx", line: 9, kind: "raw-button" },
  ];
  const over = ratchetErrors(counts(findings), new Map([["a/A.tsx\traw-button", 1]]), findings, () => true);
  expect(over[0]).toBe("new surface bypass (2 > 1): a/A.tsx raw-button");
  expect(over.join("\n")).toContain("a/A.tsx:9 raw-button: use <Button> from ui/Button");
  expect(over.join("\n")).toContain("bun scripts/check-surface-bypass.ts --update-baseline");
  const under = ratchetErrors(counts(findings.slice(0, 1)), new Map([["a/A.tsx\traw-button", 2]]), [], () => true);
  expect(under[0]).toContain("baseline can shrink (1 < 2)");
  expect(ratchetErrors(counts(findings), new Map([["a/A.tsx\traw-button", 2]]), findings, () => true)).toEqual([]);
});

test("a baseline row whose file is gone passes", () => {
  expect(ratchetErrors(new Map(), new Map([["gone/G.tsx\ttitle-attribute", 2]]), [], () => false)).toEqual([]);
});
