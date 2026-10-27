// l10n-allow-file: test fixture asks and chat names, not shipped UI.
// The header's Needs you list (needsYou/NeedsYou.tsx, needsYou.css), restyled after Leo 2026-10-21
// ("styling is shit on the top right bit"): the shared popup glass with native list metrics. These
// hold the shape: no pin glyph in the title, the ask in two lines at most, the kind as plain text
// (no chip), and Go to source and Ask about this as plain icon tools that show on hover and on
// keyboard focus, never bordered buttons, never only reachable by pointer.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import { needsYouItems } from "../src/agent-session/acpmux/needsYou/model";
import { NeedsYouPanel, type NeedsYouMode } from "../src/agent-session/acpmux/needsYou/NeedsYou";

const css = fs.readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/needsYou/needsYou.css"), "utf8");
/** The sheet's top-level rules: comments and `@media` blocks (a touch screen's, Reduce Motion's) dropped. */
const topLevel = css.replace(/\/\*[\s\S]*?\*\//g, "").replace(/@media[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/g, "");
/** Every top-level declaration block whose selector list names `selector` exactly (a whole selector,
 * not a part); a comma inside `:is(...)` or `:has(...)` does not split the list. */
const rules = (selector: string) =>
  [...topLevel.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .filter((rule) =>
      rule[1]
        .split(/,(?![^(]*\))/)
        .map((part) => part.trim())
        .includes(selector),
    )
    .map((rule) => rule[2]);
const declared = (selector: string, property: string) =>
  rules(selector).flatMap((body) =>
    [...body.matchAll(new RegExp(`(?:^|;)\\s*${property}\\s*:\\s*([^;]+)`, "g"))].map((match) => match[1]!.trim()),
  );

const options: AcpmuxPermission["options"] = [
  { id: "allow", name: "Allow", kind: "allow_once", allow: true },
  { id: "deny", name: "Deny", kind: "reject_once", allow: false },
];
const items = needsYouItems({
  sessions: [{ sessionId: "s1", name: "lane-host-rev", harness: "claude" }],
  asks: [{ sessionId: "s1", at: 1, permission: { permissionId: "p1", pending: true, options, title: "Run it" } }],
});
const render = (mode: NeedsYouMode = "pinned") =>
  renderToStaticMarkup(
    <NeedsYouPanel
      items={items}
      mode={mode}
      actions={{ answer: async () => undefined, goTo: () => undefined, ask: async () => "" }}
    />,
  );

test("the title has no pin glyph, and the count is plain text", () => {
  const html = render();
  const head = html.match(/<header class="acpmux-needs-you-head">([\s\S]*?)<\/header>/)?.[1] ?? "";
  expect(head).toContain(translate("needsYou.title"));
  expect(head).not.toContain("data-icon");
  expect(declared(".acpmux-needs-you-total", "background")).toEqual([]);
  expect(declared(".acpmux-needs-you-total", "border-radius")).toEqual([]);
});

test("the ask shows two lines at most, one in compact mode", () => {
  expect(declared(".acpmux-needs-you-ask", "-webkit-line-clamp")).toEqual(["2"]);
  expect(declared('.acpmux-needs-you-panel[data-mode="compact"] .acpmux-needs-you-ask', "-webkit-line-clamp")).toEqual([
    "1",
  ]);
});

test("the kind is plain muted text, not a chip", () => {
  for (const property of ["background", "padding", "border-radius", "box-shadow", "border"])
    expect({ property, values: declared(".acpmux-needs-you-kind", property) }).toEqual({ property, values: [] });
});

test("Go to source and Ask about this are plain icon tools, named, in the row's meta line", () => {
  const html = render();
  const meta = html.match(/<div class="acpmux-needs-you-meta">([\s\S]*?)<\/div>/)?.[1] ?? "";
  expect(meta).toContain(`aria-label="${translate("needsYou.goToSource")}"`);
  expect(meta).toContain(`aria-label="${translate("needsYou.askAbout")}"`);
  for (const tool of [".acpmux-needs-you-go", ".acpmux-needs-you-ask-about"]) {
    expect(declared(tool, "border")).toEqual(["0"]);
    expect(declared(tool, "background")).toEqual(["none"]);
    expect(declared(tool, "box-shadow")).toEqual([]);
  }
  // Compact keeps Go to source; it has no side question.
  const compact = render("compact");
  expect(compact).toContain("acpmux-needs-you-go");
  expect(compact).not.toContain("acpmux-needs-you-ask-about");
});

test("the tools hide at rest and show on row hover and on keyboard focus inside the row", () => {
  expect(declared(".acpmux-needs-you-tools", "opacity")).toEqual(["0"]);
  const shown = rules(".acpmux-needs-you-item:is(:hover, :focus-within) .acpmux-needs-you-tools");
  expect(shown.join(";")).toMatch(/opacity:\s*1/);
  // Hidden by opacity only: never display:none or visibility:hidden, which would drop them from Tab.
  expect(declared(".acpmux-needs-you-tools", "display")).not.toContain("none");
  expect(declared(".acpmux-needs-you-tools", "visibility")).toEqual([]);
  expect(declared(".acpmux-needs-you-go:focus-visible", "outline").length).toBe(1);
});

test("the list paints no fill of its own: the popover's glass is its only surface", () => {
  for (const selector of [".acpmux-needs-you", ".acpmux-needs-you-panel", ".acpmux-needs-you-head"])
    for (const property of ["background", "background-color", "backdrop-filter"])
      expect({ selector, property, values: declared(selector, property) }).toEqual({ selector, property, values: [] });
});
