// l10n-allow-file: test fixture diagram sources, not shipped UI.
// User 2026-11-03 ("every single theme, all the UI elements are colored properly"): with
// `markdown.theme` set to a light or dark paper, the diagrams took their colors from the App Theme's
// light or dark (`prefers-color-scheme` follows the window's appearance), so a light paper under a dark
// App Theme drew Mermaid's dark theme: light lines and labels on white. The paper's scheme wins when
// it is fixed; the app's paper follows the App Theme as before.
import { afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type * as Diagrams from "../src/pages/markdown/diagrams";

let diagrams: typeof Diagrams;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeAll(async () => {
  const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  for (const key of ["window", "document", "DOMParser", "Node", "Element", "HTMLElement", "SVGElement"]) {
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  }
  for (const key of ["ondine", "mermaid", "matchMedia"]) saved.set(key, scope[key]);
  diagrams = await import("../src/pages/markdown/diagrams");
});

afterEach(() => {
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  delete document.documentElement.dataset.cmuxMdTheme;
  document.body.replaceChildren();
});

/** The Mermaid theme a render on `paper` picks while the App Theme is dark or light. */
async function mermaidTheme(paper: string, appDark: boolean): Promise<string | undefined> {
  delete scope.ondine; // Mermaid draws, as for a source Ondine refuses.
  const themes: string[] = [];
  scope.mermaid = {
    initialize: (config: { theme?: string }) => themes.push(config.theme ?? ""),
    render: async () => ({ svg: '<svg xmlns="http://www.w3.org/2000/svg"></svg>' }),
  };
  scope.matchMedia = (query: string) => ({ matches: query.includes("dark") === appDark });
  document.documentElement.dataset.cmuxMdTheme = paper;
  const target = document.createElement("div");
  document.body.append(target);
  await diagrams.renderMermaid(new diagrams.DiagramLibraries(() => null), "graph TD; A-->B", target);
  return themes.at(-1);
}

test("a light paper draws light diagrams under a dark App Theme", async () => {
  // The first render initializes Mermaid; a later one re-initializes only when the scheme changes.
  expect((await mermaidTheme("dark", false)) ?? "dark").toBe("dark");
  expect(await mermaidTheme("light", true)).toBe("default");
});

test("a dark paper draws dark diagrams under a light App Theme", async () => {
  expect((await mermaidTheme("light", true)) ?? "default").toBe("default");
  expect(await mermaidTheme("dark", false)).toBe("dark");
});

test("the app's paper follows the App Theme", async () => {
  expect((await mermaidTheme("app", false)) ?? "default").toBe("default");
  expect(await mermaidTheme("app", true)).toBe("dark");
  expect(await mermaidTheme("app", false)).toBe("default");
});
