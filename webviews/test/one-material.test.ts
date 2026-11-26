// One material per surface (design/glass-system.md): every floating web surface draws the App's host
// glass or the page's one .ui-glass, never both and never neither. scripts/check-one-material.ts says
// what counts; test/one-material-browser.test.ts reads the computed styles.
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  backdropRules,
  checkOneMaterial,
  hostFills,
  hostGlassRule,
  translucent,
  unmarkedSurfaces,
} from "../scripts/check-one-material";

const glassCss = readFileSync(new URL("../src/ui/glass/glass.css", import.meta.url), "utf8");

test("every floating surface in the page code draws one material", () => {
  expect(checkOneMaterial().errors).toEqual([]);
});

test("the HOST GLASS rule clears a drawn surface's whole material, the same way in either engine", () => {
  expect(hostGlassRule(glassCss)).toEqual([]);
});

// Leo, 2026-11-21, the prompt rail's hover preview as an opaque box: "shietttt this web thing got
// disconnected from its glass... where is our proper glass redesign?". The card painted a glass of its
// own outside .ui-glass and carried no host-glass mark. Both halves fail on the card as it was.
test("the rail's preview card as it was fails twice: a private glass, and no decided material", () => {
  const css = [
    ".acpmux-minimap__card {",
    "  background: color-mix(in srgb, var(--glass-surface, var(--acpmux-minimap-base)) var(--ds-glass-popover-tint), transparent);",
    "  -webkit-backdrop-filter: var(--ds-glass-popover-blur);",
    "  backdrop-filter: var(--ds-glass-popover-blur);",
    "}",
  ].join("\n");
  const { errors } = backdropRules(css, "threadMinimap.css");
  expect(errors).toHaveLength(1);
  expect(errors[0]).toContain("[material]");
  const tsx = [
    "const card = (",
    '  <div ref={own} id={id} className="acpmux-minimap__card" style={cardStyle}>',
    "  </div>",
    ");",
  ].join("\n");
  expect(unmarkedSurfaces(tsx).map((found) => found.line)).toEqual([2]);
});

test("the backdrop rule passes the painter, a token on .ui-glass and a stated reason, and fails the rest", () => {
  const css = [
    ".a { backdrop-filter: blur(var(--ds-glass-chrome-radius)); }",
    ".b.ui-glass { backdrop-filter: var(--glass-backdrop); }",
    ".c.ui-glass { backdrop-filter: var(--ds-glass-popover-blur); }",
    ".d { backdrop-filter: none; -webkit-backdrop-filter: none; }",
    "/* one-material-allow: the scroll edge's masked fade, no surface's material */",
    ".e { backdrop-filter: blur(var(--ds-glass-chrome-radius)); }",
    ".f { background: rgba(0, 0, 0, 0.4); backdrop-filter: var(--surface-blur); }",
    ".g {",
    "  /* one-material-allow: a scrim */",
    "  backdrop-filter: var(--surface-blur);",
    "}",
  ].join("\n");
  const { errors, allowed } = backdropRules(css, "x.css");
  expect(errors.map((line) => line.split(" [")[0])).toEqual(["x.css:1: .a", "x.css:3: .c.ui-glass", "x.css:7: .f"]);
  expect(errors[2]).toContain("[material]");
  expect(allowed).toEqual(["x.css:6: .e", "x.css:8: .g"]);
});

test("a translucent fill is a mix to transparent, an alpha or a tint token", () => {
  expect(translucent("color-mix(in srgb, var(--x) 70%, transparent)")).toBe(true);
  expect(translucent("rgba(0, 0, 0, 0.5)")).toBe(true);
  expect(translucent("rgb(0 0 0 / 50%)")).toBe(true);
  expect(translucent("var(--chief-glass-fill)")).toBe(true);
  expect(translucent("var(--surface-popup)")).toBe(false);
  expect(translucent("Canvas")).toBe(false);
});

test("the surface rule passes a host-glass mark with .ui-glass and a stated page glass, and fails the rest", () => {
  const tsx = [
    'const shell = cx("ui-popup ui-glass ui-held", extra);',
    "export function A() {",
    "  return (",
    "    <>",
    '      <div className="ui-popup ui-glass ui-menu" data-host-glass="menu" data-host-glass-cover="" />',
    '      <div className={cx("ui-tooltip ui-glass", x)} {...{ "data-host-glass": "chip" }} />',
    '      <div className="ui-notice ui-glass" />',
    '      <div className="ui-dialog" data-host-glass="popover" />',
    '      <div className="ui-dialog ui-glass" data-page-glass="inline in the page\'s flow: nothing floats" />',
    "      <div className={shell} />",
    '      <Popover hostGlass={false} className="nt-popover" />',
    '      <Popover hostGlass={false} data-page-glass="rows the App\'s glass cannot follow" />',
    '      <div className="acpmux-composer-box-row" />',
    '      <Popover className="nt-composer-surface nt-popover" />',
    "    </>",
    "  );",
    "}",
  ].join("\n");
  expect(unmarkedSurfaces(tsx).map((found) => found.line)).toEqual([7, 8, 10, 11]);
  expect(unmarkedSurfaces(tsx)[1]!.message).toContain("without .ui-glass");
});

test("the host rule fails a drawn surface that keeps a fill, a blur or its rim, and a second veil", () => {
  const rule = (body: string) =>
    [
      '@media x { :root[data-host-glass-on][data-cmux-see-through] [data-host-glass][data-host-glass-drawn="1"]:not([data-glass-keeps-underlay]):is(:not([data-host-glass-cover]), [data-glass-over]).ui-glass.ui-glass {',
      body,
      "} }",
      ':root[data-host-glass-engines="all"][data-host-glass-on][data-cmux-see-through] [data-host-glass][data-host-glass-drawn="1"]:not([data-glass-keeps-underlay]):is(:not([data-host-glass-cover]), [data-glass-over]):is(.ui-glass, .ui-tooltip) {',
      "background: transparent; -webkit-backdrop-filter: none; backdrop-filter: none; box-shadow: none; border-color: transparent;",
      "}",
    ].join("\n");
  expect(
    hostGlassRule(
      rule(
        "background: var(--host-glass-fill, transparent); -webkit-backdrop-filter: none; backdrop-filter: none; box-shadow: var(--host-glass-edge, none); border-color: transparent;",
      ),
    ),
  ).toEqual([]);
  const kept = hostGlassRule(
    rule("background: var(--glass-tint); backdrop-filter: var(--glass-backdrop); box-shadow: none;"),
  );
  expect(kept.length).toBeGreaterThanOrEqual(3);
  expect(
    hostFills(".ui-popup.ui-glass { --host-glass-fill: color-mix(in srgb, Canvas 40%, transparent); }", "x.css"),
  ).toHaveLength(1);
  expect(hostFills(".ui-card.ui-glass { --host-glass-fill: transparent; }", "x.css")).toEqual([]);
});

test("the allowlist only shrinks: one more allowed blur than the pin fails, one fewer asks to lower it", () => {
  const root = mkdtempSync(join(tmpdir(), "one-material-"));
  try {
    mkdirSync(join(root, "ui"), { recursive: true });
    writeFileSync(
      join(root, "ui/x.css"),
      "/* one-material-allow: a scrim */\n.a { backdrop-filter: var(--surface-blur); }\n/* one-material-allow: a fade */\n.b { backdrop-filter: var(--surface-blur); }\n",
    );
    expect(checkOneMaterial(root, { pin: 1, pending: {} }).errors.some((line) => line.startsWith("[allowlist]"))).toBe(
      true,
    );
    expect(
      checkOneMaterial(root, { pin: 2, pending: {} }).errors.filter((line) => line.startsWith("[allowlist]")),
    ).toEqual([]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
