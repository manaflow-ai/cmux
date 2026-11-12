// One set of glass levels (Leo, 2026-11-06: "we have, like, a ton of varying glassiness on stuff for
// some reason"). Every web glass surface frosts through a level of the design scale (chrome, popover,
// menu, chip), never a blur of its own: scripts/check-glass-levels.ts says what counts.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import designScale from "../../schemas/design-scale/design-scale.json";
import {
  findRawBlurs,
  findRawNativeGlass,
  rawBlursInCss,
  rawBlursInScript,
  rawNativeGlass,
} from "../scripts/check-glass-levels";

const source = (file: string) => readFileSync(new URL(`../src/${file}`, import.meta.url), "utf8");

test("every blur in the page code names a glass level", () => {
  expect(findRawBlurs()).toEqual([]);
});

test("the levels are chrome, popover, menu and chip, each with its tint, blur and radius in desktop.css", () => {
  const levels = designScale.glass.filter((level) => level.kind === "level");
  expect(levels.map((level) => level.name)).toEqual(["chrome", "popover", "menu", "chip"]);
  const desktop = source("pages/shared/desktop.css");
  for (const level of levels) {
    expect(desktop).toContain(`--ds-glass-${level.name}-tint: ${level.tint}%;`);
    expect(desktop).toContain(`--ds-glass-${level.name}-blur: ${level.blur};`);
    expect(desktop).toMatch(new RegExp(`--ds-glass-${level.name}-radius: [\\d.]+px;`));
  }
  // The shared tokens every surface reads are the levels: panes the chrome, tooltips the chip.
  expect(desktop).toContain("--surface-blur: var(--ds-glass-chrome-blur);");
  expect(desktop).toContain("--tooltip-blur: var(--ds-glass-chip-blur);");
});

// Leo, 2026-11-11: "The point is, the styles mix and they don't look good. So they need to look good."
// Every floating popup and card (menus, popovers, pickers, hover cards, the context card) is one
// material: the menu level, and one veil on the App's glass. No surface keeps a tint of its own.
test("every popup and hover card is one material: the menu level and one veil on the App's glass", () => {
  const glass = source("ui/glass/glass.css").replace(/\/\*[\s\S]*?\*\//g, "");
  const at = glass.indexOf(".ui-popup.ui-glass,\n.ui-card.ui-glass {");
  expect(at).toBeGreaterThanOrEqual(0);
  const rule = glass.slice(at, glass.indexOf("}", at));
  expect(rule).toContain("var(--ds-glass-menu-tint)");
  expect(rule).toContain("--glass-backdrop: var(--ds-glass-menu-blur)");
  expect(rule).toContain("--host-glass-fill: color-mix(in srgb, var(--glass-surface) 40%, transparent)");
  // No popup names the popover level, and no menu a second rule of its own.
  expect(glass).not.toMatch(/\.ui-popup\.ui-glass[^{]*\{[^}]*--ds-glass-popover-tint/);
  // The surfaces that kept a tint of their own (the model menu's 92%, the + menu's and New Tab
  // suggestions' 86%) and a radius of their own (the model menu's 10) read the shared ones.
  for (const file of [
    "agent-session/acpmux/modelPicker.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/newtab/screen.css",
  ]) {
    // One rule at a time: a selector and its own declarations (the sheets hold no nested blocks there).
    const rules = source(file)
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .split("}")
      .map((rule) => rule.split("{"))
      .filter((parts) => parts.length >= 2)
      .map((parts) => ({ selector: parts.at(-2)!, body: parts.at(-1)! }));
    const own = rules.filter(
      ({ selector, body }) =>
        (/\.(acpmux-quick-menu|acpmux-composer-plus|nt-popover)\b/.test(selector) && /--glass-tint\s*:/.test(body)) ||
        (/\.ui-glass\b/.test(selector) && /--host-glass-fill\s*:/.test(body)),
    );
    expect(
      own.map(({ selector }) => selector.trim()),
      file,
    ).toEqual([]);
  }
  const quick = source("agent-session/acpmux/modelPicker.css");
  const menu = quick.slice(
    quick.indexOf(".acpmux-quick-menu {"),
    quick.indexOf("}", quick.indexOf(".acpmux-quick-menu {")),
  );
  expect(menu).toContain("border-radius: var(--ui-popup-radius);");
});

test("Session Info, the composer and the running tray share the popover level", () => {
  for (const file of [
    "agent-session/acpmux/session-info/sessionInfo.css",
    "agent-session/acpmux/composerStates.css",
    "agent-session/acpmux/subagents/subagents.css",
  ]) {
    const css = source(file);
    expect(css, file).toContain("var(--ds-glass-popover-blur)");
    expect(css, file).toContain("var(--ds-glass-popover-art-tint)");
  }
});

test("the check fails a raw blur and passes a level, an element filter and a stated exception", () => {
  const css = [
    ".a { backdrop-filter: blur(18px) saturate(1.08); }",
    ".b { --x-frost: blur(24px); }",
    ".c { --x-blur: 6px; }",
    ".d { backdrop-filter: var(--ds-glass-popover-blur); --y-blur: 0px; }",
    ".e { filter: blur(2px); backdrop-filter: blur(0); }",
    ".f { -webkit-backdrop-filter: blur(var(--ds-glass-chrome-radius)); }",
    "/* glass-raw-blur-allow: a scrim, not glass */",
    ".g { backdrop-filter: blur(2px); }",
  ].join("\n");
  expect(rawBlursInCss(css, "x.css")).toEqual([
    "x.css:1: backdrop-filter: blur(18px) saturate(1.08)",
    "x.css:2: --x-frost: blur(24px)",
    "x.css:3: --x-blur: 6px",
  ]);
  expect(rawBlursInScript('el.style.backdropFilter = "blur(12px)";\nconst ok = "blur(var(--r))";', "x.ts")).toEqual([
    'x.ts:1: el.style.backdropFilter = "blur(12px)";',
  ]);
});

test("every native glass view and tint is a glass level", () => {
  expect(findRawNativeGlass()).toEqual([]);
});

test("the native GlassLevel names the design scale's levels, and the roles map onto them", () => {
  const swift = readFileSync(
    new URL("../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/FloatingGlass/GlassLevel.swift", import.meta.url),
    "utf8",
  );
  const cases = [...swift.matchAll(/^\s*case (\w+)$/gm)].map((match) => match[1]);
  const levels = designScale.glass.filter((level) => level.kind === "level").map((level) => level.name);
  expect(cases).toEqual(levels);
  // The overlay tint tunable defaults to the popover level's strength.
  const popover = swift.match(/case \.popover, \.menu: ([\d.]+)/)?.[1];
  const tunables = readFileSync(
    new URL("../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Tunables/ChromeTunables.swift", import.meta.url),
    "utf8",
  );
  expect(tunables).toContain(
    `default: ${popover}, range: 0...3, step: 0.05, unit: .multiplier, code: "ChromeTunables.glassOverlayTintStrength"`,
  );
  const roles = readFileSync(
    new URL(
      "../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/FloatingGlass/SurfaceRole+GlassLevel.swift",
      import.meta.url,
    ),
    "utf8",
  );
  for (const role of ["popover", "menu", "card", "group", "toast", "sheet", "tooltip"])
    expect(roles, role).toMatch(new RegExp(`case [^:]*\\.${role}\\b[^:]*:`));
});

test("the native check fails a glass view or tint scale outside the levels and passes a stated reason", () => {
  const swift = [
    "let a = NSVisualEffectView()",
    "glass.tintColor = tint.withAlphaComponent(tint.alphaComponent * 1.5)",
    "let b = GlassPanelView(style: .regular) // glass-level-allow: a system control's untinted glass",
    "let c = Glass.makePanel(level: .chip)",
    "// let d = NSVisualEffectView()",
  ].join("\n");
  expect(rawNativeGlass(swift, "CmuxNextDemo/X.swift")).toEqual([
    "CmuxNextDemo/X.swift:1: let a = NSVisualEffectView()",
    "CmuxNextDemo/X.swift:2: glass.tintColor = tint.withAlphaComponent(tint.alphaComponent * 1.5)",
  ]);
  expect(rawNativeGlass(swift, "CmuxNextDesign/GlassPanelView.swift")).toEqual([]);
});

test("a level surface outside .ui-glass turns solid under Reduce Transparency: the New Tab box", () => {
  const css = source("agent-session/acpmux/styles.css");
  expect(css).toMatch(
    /:root\[data-reduce-transparency\] \.acpmux-newtab-box\{background:var\(--acpmux-composer-solid\b/,
  );
  expect(css).toMatch(
    /@media \(prefers-reduced-transparency:reduce\)\{\.acpmux-newtab-box\{background:var\(--acpmux-composer-solid\b/,
  );
});
