// Leo (2026-10-15): the diff viewer was too bold. Every diff surface of cmux NEXT, the diff
// viewer page and the agent pane's diff cards, draws code and line numbers at the regular weight
// even inside a bold container, and tints changed rows the same calm amount, with the changed
// word a step above its row (diffWeight.ts).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html>");
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    customElements: dom.window.customElements,
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

async function surfaces(): Promise<Record<string, string>> {
  const { codeViewUnsafeCSS } = await import("../src/pierre-options");
  const { diffUnsafeCSS } = await import("../src/agent-session/acpmux/diffTheme");
  return { "diff viewer page": codeViewUnsafeCSS(), "agent pane diff cards": diffUnsafeCSS };
}

/** A diff's rows under a bold container, styled by one surface's injected CSS. */
function renderRows(css: string) {
  const doc = dom.window.document;
  doc.head.innerHTML = "";
  const style = doc.createElement("style");
  style.textContent = css;
  doc.head.append(style);
  doc.body.innerHTML = `<div style="font-weight: 700">
    <div data-diffs-header>src/app.ts</div>
    <div data-column-number data-line-type="change-addition">12</div>
    <div data-line data-line-type="change-addition"><span data-diff-span>retry</span>(task)</div>
    <div data-line data-line-type="change-deletion">return task();</div>
  </div>`;
  const weight = (selector: string) => dom.window.getComputedStyle(doc.querySelector(selector)!).fontWeight;
  return { weight };
}

describe("diffs draw at the regular weight with calm tints", () => {
  test("code, line numbers and the file header compute to the normal weight", async () => {
    for (const [name, css] of Object.entries(await surfaces())) {
      const { weight } = renderRows(css);
      for (const selector of ["[data-line]", "[data-column-number]", "[data-diffs-header]"]) {
        expect(`${name} ${selector}: ${weight(selector)}`).toBe(`${name} ${selector}: 400`);
      }
    }
  });

  test("intra-line diff highlights compute to the emphasis weight", async () => {
    for (const [name, css] of Object.entries(await surfaces())) {
      const { weight } = renderRows(css);
      expect(`${name} [data-diff-span]: ${weight("[data-diff-span]")}`).toBe(`${name} [data-diff-span]: 600`);
    }
  });

  test("both surfaces tint a changed row the same low amount, the changed word a step above", async () => {
    const all = Object.values(await surfaces());
    const rows = all.map((css) =>
      drawnTintPercent(
        css,
        '(?:--diffs-bg-addition-override|\\[data-line\\]\\[data-line-type="change-addition"\\] \\{ --diffs-line-bg)',
      ),
    );
    const words = all.map((css) => drawnTintPercent(css, "--diffs-bg-addition-emphasis-override"));
    expect(new Set(rows).size).toBe(1);
    expect(new Set(words).size).toBe(1);
    expect(rows[0]).toBeLessThanOrEqual(16);
    expect(words[0]).toBeGreaterThan(rows[0]);
    expect(words[0]).toBeLessThanOrEqual(24);
  });
});

describe("Diff Colors stays ordered under the calmer tints", () => {
  test("Muted's change color sits nearer the page than Theme's, so its row tint stays quieter", async () => {
    const { applyDiffViewerAppearance, setDiffChangeColors } = await import("../src/appearance");
    const style = dom.window.document.documentElement.style;
    applyDiffViewerAppearance({
      themes: {
        dark: { background: "#000000", foreground: "#ffffff", palette: { "2": "#50e050" } },
      },
    });
    const green = () => style.getPropertyValue("--cmux-diff-addition-fg-dark");
    setDiffChangeColors("theme");
    const theme = green();
    setDiffChangeColors("muted");
    const muted = green();
    setDiffChangeColors("theme");
    const channel = (hex: string) => Number.parseInt(hex.slice(3, 5), 16);
    expect(theme).toBe("#50e050");
    // Both modes take the same row tint (diffWeight.ts) of their own color: Muted's dimmer green
    // makes the quieter row, and Theme, the default, draws the calmer 14% tint itself.
    expect(channel(muted)).toBeLessThan(channel(theme));
  });
});

/** A tint's percent as drawn: a `var(--x, N%)` percent resolves against the page root first. */
function drawnTintPercent(css: string, variable: string): number {
  const match = css.match(
    new RegExp(`${variable}:\\s*color-mix\\(in srgb, [^;]*? (\\d+%|var\\((--[\\w-]+), (\\d+)%\\)), transparent\\)`),
  );
  if (!match) throw new Error(`no tint for ${variable}`);
  if (!match[2]) return Number.parseFloat(match[1]);
  const set = dom.window.document.documentElement.style.getPropertyValue(match[2]).trim();
  return Number.parseFloat(set || match[3]);
}

describe("Muted is clearly quieter than Theme", () => {
  // Leo (2026-10-15): with Theme's calmer 14% row tint, Muted (its color 40% toward the page)
  // read almost like Theme. Muted's own row and word tints sit a fixed margin under Theme's on
  // the diff viewer page and the agent pane's diff cards alike.
  const MARGIN = 5;
  const ROW =
    '(?:--diffs-bg-addition-override|\\[data-line\\]\\[data-line-type="change-addition"\\] \\{ --diffs-line-bg)';
  const WORD = "--diffs-bg-addition-emphasis-override";

  test("on the diff viewer page", async () => {
    const { applyDiffViewerAppearance, setDiffChangeColors } = await import("../src/appearance");
    const { codeViewUnsafeCSS } = await import("../src/pierre-options");
    applyDiffViewerAppearance({
      themes: {
        dark: { background: "#000000", foreground: "#ffffff", palette: { "2": "#50e050" } },
      },
    });
    const css = codeViewUnsafeCSS();
    setDiffChangeColors("theme");
    const theme = { row: drawnTintPercent(css, ROW), word: drawnTintPercent(css, WORD) };
    setDiffChangeColors("muted");
    const muted = { row: drawnTintPercent(css, ROW), word: drawnTintPercent(css, WORD) };
    setDiffChangeColors("theme");
    expect(theme).toEqual({ row: 14, word: 22 });
    expect(muted.row).toBeLessThanOrEqual(theme.row - MARGIN);
    expect(muted.word).toBeLessThanOrEqual(theme.word - MARGIN);
    expect(muted.word).toBeGreaterThan(muted.row);
  });

  test("on the agent pane's diff cards", async () => {
    const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
    const { diffUnsafeCSS } = await import("../src/agent-session/acpmux/diffTheme");
    applyHostEvent({ kind: "diffColors", value: "theme" });
    const theme = {
      row: drawnTintPercent(diffUnsafeCSS, ROW),
      word: drawnTintPercent(diffUnsafeCSS, WORD),
    };
    applyHostEvent({ kind: "diffColors", value: "muted" });
    const muted = {
      row: drawnTintPercent(diffUnsafeCSS, ROW),
      word: drawnTintPercent(diffUnsafeCSS, WORD),
    };
    applyHostEvent({ kind: "diffColors", value: "theme" });
    expect(theme).toEqual({ row: 14, word: 22 });
    expect(muted.row).toBeLessThanOrEqual(theme.row - MARGIN);
    expect(muted.word).toBeLessThanOrEqual(theme.word - MARGIN);
    expect(muted.word).toBeGreaterThan(muted.row);
  });
});
