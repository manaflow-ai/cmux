// Leo, 2026-10-14: no dramatic shadows. Menus, popovers, cards, the composer, the New Tab box, the
// palette, sheets and find bars cast big, soft or dark drop shadows (0 16px 34px at 28%, 0 12px 40px
// at 22%, 0 8px 24px at 18%), each with its own numbers. Every web drop shadow now comes from one
// scale in pages/shared/desktop.css, the native one's (PopupStyle.swift, `elevation1`/`elevation2`):
// a tight, low-alpha drop under the surface, and the thin rim carries the edge.
//
//   --elevation-1  rows, cards and inline surfaces
//   --elevation-2  popovers, menus, the palette, hover cards, the composer, sheets, find bars
//
// The check reads the stylesheets. A drop layer (not inset) with any blur must be one of the two
// tokens, never a literal of its own; the tokens stay tight (blur at most 8px, alpha at most 16%,
// in light and dark), match the native values, and the surfaces the sweep covered name them.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const source = path.resolve(import.meta.dir, "../src");

const sheets = (dir: string): string[] =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) return sheets(file);
    return entry.name.endsWith(".css") ? [file] : [];
  });

// The OptChat Session Info is a standalone page bundled into optchat-chief (build-optchat-inspector-web.sh)
// with no desktop layer, so the scale's tokens are not defined there.
const STANDALONE = ["optchat-inspector/"];

const css = sheets(source)
  .filter((file) => !STANDALONE.some((dir) => path.relative(source, file).startsWith(dir)))
  .map((file) => ({
    file: path.relative(source, file),
    text: fs.readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, ""),
  }));

const ELEVATIONS = ["--elevation-1", "--elevation-2"] as const;
const MAX_BLUR = 8;
const MAX_ALPHA = 0.16;

// The top-level comma-separated layers of a shadow (commas inside calls do not split).
const layers = (value: string) => {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "(") depth++;
    else if (value[i] === ")") depth--;
    else if (value[i] === "," && depth === 0) {
      parts.push(value.slice(start, i).trim());
      start = i + 1;
    }
  }
  return [...parts, value.slice(start).trim()].filter(Boolean);
};

// The lengths of a literal layer (calls such as color-mix() and var() removed first).
const lengths = (layer: string) => {
  let bare = layer;
  for (let before = ""; before !== bare;) {
    before = bare;
    bare = bare.replace(/[\w-]+\([^()]*\)/g, " ");
  }
  return [...bare.matchAll(/(?<![\w.#-])(-?\d*\.?\d+)(px)?(?![\w%])/g)].map((match) => Number(match[1]));
};

// A layer that is only `var(--token[, fallback])`.
const tokenCall = (layer: string) => layer.match(/^var\(\s*(--[\w-]+)\s*(?:,\s*([\s\S]*))?\)(\s*!important)?$/);

// The preludes of the at-rule blocks still open at `index`.
const atRules = (text: string, index: number) => {
  const open: string[] = [];
  let start = 0;
  for (let i = 0; i < index; i++) {
    if (text[i] === "{") open.push(text.slice(start, i).trim().replace(/\s+/g, " "));
    else if (text[i] === "}") open.pop();
    if (text[i] === "{" || text[i] === "}" || text[i] === ";") start = i + 1;
  }
  return open.filter((prelude) => prelude.startsWith("@"));
};

// Every declaration of a shadow: `box-shadow`, and a custom property that holds one.
const declarations = css.flatMap(({ file, text }) =>
  [...text.matchAll(/(box-shadow|--[\w-]*(?:shadow|elevation|-drop)[\w-]*)\s*:\s*([^;{}]+)/g)].map((match) => {
    const open = text.lastIndexOf("{", match.index);
    const start = Math.max(text.lastIndexOf("}", open), text.lastIndexOf(";", open)) + 1;
    return {
      file,
      property: match[1],
      selector: text.slice(start, open).trim().replace(/\s+/g, " "),
      value: match[2].trim().replace(/\s*!important$/, ""),
      // The at-rules (`@media`, `@container`) the rule sits in, outermost first.
      at: () => atRules(text, open),
    };
  }),
);

// The definitions of each custom property, across every sheet.
const definitions = new Map<string, string[]>();
for (const { property, value } of declarations) {
  if (property.startsWith("--")) definitions.set(property, [...(definitions.get(property) ?? []), value]);
}

// The drop layers (not inset) that blur, after following tokens down to their literals.
const blurredDrops = (value: string, seen: string[] = []): string[] =>
  layers(value).flatMap((layer) => {
    if (/\binset\b/.test(layer) || layer === "none") return [];
    const call = tokenCall(layer);
    if (call) {
      const [, name, fallback] = call;
      if (seen.includes(name)) return [];
      const inner = (definitions.get(name) ?? []).flatMap((definition) => blurredDrops(definition, [...seen, name]));
      return fallback ? [...inner, ...blurredDrops(fallback, seen)] : inner;
    }
    return (lengths(layer)[2] ?? 0) > 0 ? [layer] : [];
  });

// The alpha of a literal layer's color: color-mix(… black N% …), rgb(… / a), rgba(…, a) or #rrggbbaa.
const alpha = (layer: string): number => {
  const mix = layer.match(/color-mix\(in \w+,\s*(?:black|#000)\s+([\d.]+)%/);
  if (mix) return Number(mix[1]) / 100;
  const slash = layer.match(/rgba?\([^)]*\/\s*([\d.]+)(%?)\)/);
  if (slash) return Number(slash[1]) / (slash[2] ? 100 : 1);
  const comma = layer.match(/rgba\(\s*[\d.]+\s*,\s*[\d.]+\s*,\s*[\d.]+\s*,\s*([\d.]+)\)/);
  if (comma) return Number(comma[1]);
  return Number.NaN;
};

const rootBlocks = (text: string, selector: RegExp) =>
  [...text.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .filter((match) => selector.test(match[1].trim()))
    .map((match) => match[2]);

const desktop = css.find(({ file }) => file === "pages/shared/desktop.css")!.text;
const tokenValue = (block: string, token: string) => block.match(new RegExp(`${token}\\s*:\\s*([^;}]+)`))?.[1].trim();

describe("one subtle elevation scale", () => {
  test("desktop.css defines --elevation-1 and --elevation-2, tight in light and dark", () => {
    const light = rootBlocks(desktop, /^:root$/).join(";");
    const dark = rootBlocks(desktop, /^:root(:not\(\[data-theme="light"\]\)|\[data-theme="dark"\])$/);
    expect(dark.length).toBe(2);
    for (const block of [light, ...dark]) {
      for (const token of ELEVATIONS) {
        const value = tokenValue(block, token);
        expect({ token, value: value ?? "missing" }).toEqual({ token, value: expect.stringMatching(/^0 /) });
        const parts = layers(value!);
        expect(parts.length).toBe(1);
        const [x, y, blur, spread = 0] = lengths(parts[0]);
        expect({ token, x, spread }).toEqual({ token, x: 0, spread: 0 });
        expect(y).toBeGreaterThan(0);
        expect(blur).toBeLessThanOrEqual(token === "--elevation-1" ? 2 : MAX_BLUR);
        expect(alpha(parts[0])).toBeLessThanOrEqual(MAX_ALPHA);
      }
    }
    // Dark mode may darken the same geometry, never widen it.
    for (const token of ELEVATIONS) {
      const geometry = (block: string) => lengths(tokenValue(block, token)!);
      for (const block of dark) expect(geometry(block)).toEqual(geometry(light));
    }
  });

  // The native scale (PopupStyle.elevation1/elevation2) is the same numbers in light.
  test("the web scale is the native scale", () => {
    const swift = fs.readFileSync(
      path.resolve(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/PopupStyle.swift"),
      "utf8",
    );
    const light = rootBlocks(desktop, /^:root$/).join(";");
    for (const [index, token] of ELEVATIONS.entries()) {
      const native = swift.match(
        new RegExp(
          `static let elevation${index + 1} = Elevation\\(offset: ([\\d.]+), blur: ([\\d.]+), alpha: ([\\d.]+)\\)`,
        ),
      );
      expect({ token, native: Boolean(native) }).toEqual({ token, native: true });
      const value = tokenValue(light, token)!;
      const [, y, blur] = lengths(value);
      expect([y, blur, alpha(value)]).toEqual([Number(native![1]), Number(native![2]), Number(native![3])]);
    }
  });

  test("no drop shadow blurs except through the scale", () => {
    const offenders = declarations
      .filter(({ property }) => !(ELEVATIONS as readonly string[]).includes(property))
      .flatMap((declaration) =>
        layers(declaration.value)
          .filter((layer) => !/\binset\b/.test(layer) && !tokenCall(layer))
          .filter((layer) => (lengths(layer)[2] ?? 0) > 0)
          .map((layer) => `${declaration.file} ${declaration.selector} { ${declaration.property}: ${layer} }`),
      );
    expect(offenders).toEqual([]);
  });

  test("every drop shadow a surface casts resolves to the scale", () => {
    const loose = declarations.flatMap((declaration) =>
      blurredDrops(declaration.value)
        .filter((layer) => {
          const [, , blur] = lengths(layer);
          return blur > MAX_BLUR || !(alpha(layer) <= MAX_ALPHA);
        })
        .map((layer) => `${declaration.file} ${declaration.selector}: ${layer}`),
    );
    expect(loose).toEqual([]);
  });

  test("no filter drop-shadow blurs past the scale", () => {
    const filters = css.flatMap(({ file, text }) =>
      [...text.matchAll(/drop-shadow\(([^()]*(?:\([^()]*\)[^()]*)*)\)/g)]
        .filter((match) => (lengths(match[1])[2] ?? 0) > MAX_BLUR || !(alpha(match[1]) <= MAX_ALPHA))
        .map((match) => `${file}: ${match[0]}`),
    );
    expect(filters).toEqual([]);
  });

  // The surfaces the sweep covered, and the step each takes.
  const surfaces: [file: string, selector: string, token: (typeof ELEVATIONS)[number]][] = [
    // A popup is liquid glass: its drop is the glass's --glass-elevation (ui/glass/glass.css draws it
    // into the box-shadow), set once on .ui-popup. The pane's menus and popovers (.nt-popover,
    // .acpmux-menu) are .ui-popup and cast that one.
    ["ui/popupSurface.css", ".ui-popup", "--elevation-2"],
    ["ui/ui.css", ".ui-sheet", "--elevation-2"],
    // A tooltip is small and close to its control: elevation 1 (--tooltip-shadow, TooltipSurface.shadow).
    ["pages/shared/desktop.css", ".ui-title-tooltip", "--elevation-1"],
    ["pages/shared/pageBase.css", ".page-menu", "--elevation-2"],
    // The link editor (.md-link-popover) is a ui/Popover, so .ui-popup casts its drop; the hover bubble is solid.
    ["pages/markdown/styles.css", ".md-link-bubble", "--elevation-2"],
    ["pages/cloud/styles.css", ".cloud-create-sheet", "--elevation-2"],
    ["pages/home-channels/ledger.css", ".lg-palette", "--elevation-2"],
    ["pages/home-channels/ledger.css", ".lg-form", "--elevation-2"],
    ["pages/home-channels/ledger.css", ".lg-sheet", "--elevation-2"],
    ["pages/home-channels/styles.css", ".hc-msg-toolbar", "--elevation-2"],
    ["icon-picker/styles.css", ".icon-bar-pill", "--elevation-2"],
    ["viewer-empty/styles.css", ".ve-picker", "--elevation-2"],
    ["styles.css", ".toolbar-menu", "--elevation-2"],
    ["styles.css", ".file-tree-context-menu", "--elevation-2"],
    ["styles.css", ".comment-card", "--elevation-1"],
    // The composer: --elevation-1 in a light theme, none in a dark one (newtab-quiet-focus.test.ts).
    ["agent-session/acpmux/composerLocation.css", ".acpmux-composer-box", "--elevation-1"],
    [
      "agent-session/acpmux/composerLocation.css",
      ".acpmux-permission-panel .acpmux-permission-card.acpmux-permission-surface",
      "--elevation-2",
    ],
    ["agent-session/acpmux/newtab/screen.css", ".nt-box", "--elevation-1"],
    ["agent-session/acpmux/styles.css", ".acpmux-newtab-box", "--elevation-2"],
    ["agent-session/acpmux/styles.css", ".acpmux-newtab-kind.is-selected", "--elevation-1"],
    ["agent-session/acpmux/styles.css", ".acpmux-file-search", "--elevation-2"],
    // Every find bar (Find in Chat, Find in Diff) is the shared find pill.
    ["ui/findPill.css", ".find-pill", "--elevation-2"],
    ["agent-session/acpmux/conversation/conversation.css", ".acpmux-jump-latest", "--elevation-2"],
    ["agent-session/acpmux/threadMinimap/threadMinimap.css", ".acpmux-minimap__card", "--elevation-2"],
    ["agent-session/acpmux/summary/summary.css", ".acpmux-summary-card", "--elevation-2"],
    ["agent-session/acpmux/addProject.css", ".acpmux-add-project-dialog", "--elevation-2"],
    ["agent-session/acpmux/composerAttachments.css", ".acpmux-pdf-viewer", "--elevation-2"],
    ["agent-session/acpmux/composerAttachments.css", ".acpmux-pdf-sheet", "--elevation-1"],
    ["agent-session/acpmux/composerControls.css", ".acpmux-effort-thumb", "--elevation-1"],
  ];

  // A surface that drops its shadow on purpose inside one at-rule, and only there.
  const flat: [file: string, selector: string, at: string][] = [
    // Lawrence, e111f3fcb3a4: below 720 px the ledger shows one pane and the sheet fills it edge to edge.
    ["pages/home-channels/ledger.css", ".lg-sheet", "@container lg-page (max-width: 719.98px)"],
  ];
  const isFlat = (file: string, selector: string, at: string[]) =>
    flat.some((entry) => entry[0] === file && entry[1] === selector && at.includes(entry[2]));

  // Follows a value's tokens and collects the elevation steps it reaches.
  const steps = (value: string, seen: string[] = []): string[] =>
    layers(value).flatMap((layer) => {
      const call = tokenCall(layer);
      if (!call) return [];
      const [, name] = call;
      if ((ELEVATIONS as readonly string[]).includes(name)) return [name];
      if (seen.includes(name)) return [];
      return (definitions.get(name) ?? []).slice(0, 1).flatMap((definition) => steps(definition, [...seen, name]));
    });

  for (const [file, selector, token] of surfaces) {
    test(`${selector} casts ${token}`, () => {
      const found = declarations.filter(
        (declaration) =>
          declaration.file === file &&
          // A glass surface names its drop in --glass-elevation; glass.css casts it.
          (declaration.property === "box-shadow" || declaration.property === "--glass-elevation") &&
          declaration.selector.split(/\s*,\s*/).includes(selector),
      );
      expect({ selector, rules: found.length > 0 }).toEqual({ selector, rules: true });
      for (const declaration of found) {
        if (isFlat(file, selector, declaration.at())) {
          expect({ selector, value: declaration.value }).toEqual({ selector, value: "none" });
          continue;
        }
        expect({ selector, steps: [...new Set(steps(declaration.value))] }).toEqual({ selector, steps: [token] });
      }
    });
  }
});
