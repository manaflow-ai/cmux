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

function tintPercent(css: string, variable: string): number {
  const match = css.match(new RegExp(`${variable}:\\s*color-mix\\(in srgb, [^;]*? (\\d+)%, transparent\\)`));
  if (!match) throw new Error(`no tint for ${variable}`);
  return Number(match[1]);
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

  test("both surfaces tint a changed row the same low amount, the changed word a step above", async () => {
    const all = Object.values(await surfaces());
    const rows = all.map((css) =>
      tintPercent(
        css,
        '(?:--diffs-bg-addition-override|\\[data-line\\]\\[data-line-type="change-addition"\\] \\{ --diffs-line-bg)',
      ),
    );
    const words = all.map((css) => tintPercent(css, "--diffs-bg-addition-emphasis-override"));
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
      themes: { dark: { background: "#000000", foreground: "#ffffff", palette: { "2": "#50e050" } } },
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
