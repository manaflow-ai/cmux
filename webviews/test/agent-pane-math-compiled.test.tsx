// Math drawn before KaTeX loads typesets once it arrives, in the pane as the app ships it: with
// the React Compiler on (scripts/agent-pane/bundle.mjs), which memoizes what a component computes
// from its props. KaTeX loads only when math first appears (Math.tsx), so the first equation of a
// chat always draws before it.
import { afterAll, expect, test } from "bun:test";
import { build } from "esbuild";
import { JSDOM, VirtualConsole } from "jsdom";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { reactCompilerPlugin } from "../scripts/agent-pane/reactCompilerPlugin.mjs";
import { katexStylePlugin } from "../scripts/agent-pane/katexStylePlugin.mjs";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const out = mkdtempSync(path.join(tmpdir(), "math-compiled-"));

afterAll(() => {
  rmSync(out, { recursive: true, force: true });
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("math drawn before KaTeX loads typesets when it arrives, with the React Compiler on", async () => {
  const webviews = path.resolve(import.meta.dir, "..");
  const srcRoot = path.join(webviews, "src");
  const compiled = new Set<string>();
  await build({
    stdin: {
      contents: [
        'export { MathInline } from "./src/agent-session/acpmux/conversation/Math";',
        'export { createRoot } from "react-dom/client";',
        'export { act } from "react";',
      ].join("\n"),
      resolveDir: webviews,
      loader: "ts",
    },
    bundle: true,
    format: "esm",
    platform: "browser",
    define: { "process.env.NODE_ENV": '"development"' },
    outfile: path.join(out, "math.js"),
    logLevel: "silent",
    plugins: [
      reactCompilerPlugin({ mode: "babel", srcRoot, onCompiled: (id: string) => compiled.add(id) }),
      katexStylePlugin({ split: false }),
    ],
  });
  expect([...compiled].some((id) => id.includes("MathInline") || id.includes("Math.tsx"))).toBe(true);

  const { MathInline, createRoot, act } = await import(path.join(out, "math.js"));
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  act(() => root.render(<MathInline tex="x^2 + y^2" />));
  for (let i = 0; i < 1000 && !host.querySelector(".katex"); i++)
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  expect(host.querySelector(".cv-math-source")).toBeNull();
  expect(host.querySelector(".cv-math[data-tex] .katex")).not.toBeNull();
  act(() => root.unmount());
});
