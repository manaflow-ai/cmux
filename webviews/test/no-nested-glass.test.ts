// No nested glass (design/glass-system.md, rule R5). Leo, 2026-11-22, on the GitHub link hover card whose
// Open | chevron split drew as glass inside the card's glass: "ugh there's more like doubled up glass/wack
// looking glass all over the place....". scripts/check-no-nested-glass.ts says what counts.
import { expect, test } from "bun:test";

import {
  findNestedGlass,
  NESTED_ALLOWED_MAX,
  nestedGlassInCss,
  nestedGlassInTsx,
} from "../scripts/check-no-nested-glass";

test("nothing inside a floating surface in the page code is a material of its own", () => {
  const { errors, allowed } = findNestedGlass();
  expect(errors).toEqual([]);
  expect(allowed.length).toBeLessThanOrEqual(NESTED_ALLOWED_MAX);
});

test("CSS: a blur on a control inside a hover card fails; a plain control passes", () => {
  const blurred = ".ui-card .x-btn {\n  backdrop-filter: blur(12px);\n}";
  expect(nestedGlassInCss(blurred, "x.css")).toHaveLength(1);
  expect(nestedGlassInCss(blurred, "x.css")[0]).toContain("[nested]");
  // Through a child combinator, inside a :is(), and under the composer box.
  expect(nestedGlassInCss(":is(.ui-popup, .menu) > .row { -webkit-backdrop-filter: blur(4px) }", "x.css")).toHaveLength(
    1,
  );
  expect(
    nestedGlassInCss(".acpmux-composer-box .chip { backdrop-filter: var(--glass-backdrop) }", "x.css"),
  ).toHaveLength(1);
  // A translucent pane with its own rim and lift inside a popup is a glass of its own.
  const pane =
    ".ui-popup .pill { background: color-mix(in srgb, white 70%, transparent); box-shadow: inset 0 0 0 1px red, 0 1px 2px black }";
  expect(nestedGlassInCss(pane, "x.css")).toHaveLength(1);

  // A plain control: the hover fill and one hairline.
  expect(
    nestedGlassInCss(
      ".ui-card .x-btn { background: transparent; border: 0.5px solid var(--line) }\n.ui-card .x-btn:hover { background: color-mix(in srgb, currentColor 6%, transparent) }",
      "x.css",
    ),
  ).toEqual([]);
  // The surface itself, a blur turned off, a sibling (not a descendant), and a :not() are not nested.
  expect(nestedGlassInCss(".ui-popup.ui-glass { backdrop-filter: var(--glass-backdrop) }", "x.css")).toEqual([]);
  expect(nestedGlassInCss(".ui-popup .x { backdrop-filter: none }", "x.css")).toEqual([]);
  expect(nestedGlassInCss(".ui-popup + .x { backdrop-filter: blur(2px) }", "x.css")).toEqual([]);
  expect(nestedGlassInCss(":not(.ui-glass) .x { backdrop-filter: blur(2px) }", "x.css")).toEqual([]);
  // A content-layer card scrolls with the page: no floating surface.
  expect(nestedGlassInCss(".ui-glass.ui-glass-content .x { backdrop-filter: blur(2px) }", "x.css")).toEqual([]);
  // An allowed rule, in the rule or on the line before its selector.
  expect(
    nestedGlassInCss(
      ".ui-card .edge {\n  /* one-material-allow: a masked scroll fade */\n  backdrop-filter: blur(4px);\n}",
      "x.css",
    ),
  ).toEqual([]);
  expect(
    nestedGlassInCss(
      "/* one-material-allow: a masked scroll fade */\n.ui-card .edge { backdrop-filter: blur(4px) }",
      "x.css",
    ),
  ).toEqual([]);
});

test("TSX: a glass button inside a glass popup fails; a plain one, a portal and an allowed one pass", () => {
  const nested = `export function Menu() {
  return (
    <div className="ui-popup ui-glass">
      <button className="ui-glass">Open</button>
    </div>
  );
}`;
  const errors = nestedGlassInTsx(nested, "Menu.tsx");
  expect(errors).toHaveLength(1);
  expect(errors[0]).toContain("Menu.tsx:4: <button>");

  // A host-glass mark, a glass component, and a local component that draws glass, inside a card.
  const marked = `function Pill() {
  return <span className={cx("pill", glass ? "ui-glass" : "")} />;
}
export function Card() {
  return (
    <AnchoredCard anchor={a}>
      <div data-host-glass="chip" />
      <Glass />
      <Pill />
    </AnchoredCard>
  );
}`;
  expect(nestedGlassInTsx(marked, "Card.tsx").map((line) => line.split(" [")[0])).toEqual([
    "Card.tsx:7: <div>",
    "Card.tsx:8: <Glass>",
    "Card.tsx:9: <Pill>",
  ]);

  const plain = `export function Card() {
  // A comment that says it's fine, with a quote.
  return (
    <div className="ui-tooltip ui-card ui-glass" data-host-glass="popover">
      <span className="split">
        <button type="button" className="open" onClick={() => go(a > b)}>Open</button>
      </span>
      {open && <MenuPopup className="ui-popup ui-glass"><div className="row" /></MenuPopup>}
      <Menu.Portal><div className="ui-popup ui-glass" /></Menu.Portal>
      {createPortal(<div className="ui-glass" />, document.body)}
    </div>
  );
}`;
  expect(nestedGlassInTsx(plain, "Card.tsx")).toEqual([]);

  const allowed = `export function Menu() {
  return (
    <div className="ui-popup ui-glass">
      {/* one-material-allow: a submenu is a menu of its own beside its parent */}
      <div className="ui-popup ui-glass submenu" />
      <div
        // one-material-allow: the same, said inside the tag
        className="ui-popup ui-glass submenu"
      />
    </div>
  );
}`;
  expect(nestedGlassInTsx(allowed, "Menu.tsx")).toEqual([]);
});
