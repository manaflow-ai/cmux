// The stale-icon bug the user-12922 screenshots found: compiled by the React Compiler (as every
// shipped page is), AgentMark kept the empty box it drew before the harness list arrived, because
// its output read the icon store outside the hook the compiler tracks. Uncompiled tests passed.
// This test bundles AgentMark through the same compiler plugin the shipped pages use
// (scripts/agent-pane/reactCompilerPlugin.mjs), draws a harness's mark before its icon is known,
// then delivers the icon: the compiled mark must redraw.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { reactCompilerPlugin } from "../../../scripts/agent-pane/reactCompilerPlugin.mjs";

const webviews = path.resolve(import.meta.dir, "../../..");
const src = path.join(webviews, "src");
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dir = "";
let dom: JSDOM;

beforeAll(() => {
  dir = mkdtempSync(path.join(tmpdir(), "harness-icons-compiled-"));
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
});

afterAll(() => {
  for (const [key, value] of saved) scope[key] = value;
  dom.window.close();
  rmSync(dir, { recursive: true, force: true });
});

test("a compiled AgentMark redraws when its harness's icon arrives after it first drew", async () => {
  const entry = path.join(dir, "entry.tsx");
  writeFileSync(
    entry,
    [
      `export { AgentMark } from ${JSON.stringify(path.join(src, "agent-session/shared/AgentMark.tsx"))};`,
      `export { rememberHarnessIcons } from ${JSON.stringify(path.join(src, "agent-session/shared/harnessIcons.ts"))};`,
      `export { act, createElement } from ${JSON.stringify(path.join(webviews, "node_modules/react/index.js"))};`,
      `export { createRoot } from ${JSON.stringify(path.join(webviews, "node_modules/react-dom/client.js"))};`,
    ].join("\n"),
  );
  const compiled: string[] = [];
  const built = await Bun.build({
    entrypoints: [entry],
    outdir: dir,
    target: "browser",
    format: "esm",
    define: { "process.env.NODE_ENV": '"development"' },
    plugins: [reactCompilerPlugin({ mode: "babel", srcRoot: src, onCompiled: (name: string) => compiled.push(name) })],
  });
  expect(built.success).toBe(true);
  // The mark really went through the compiler (the bug does not exist uncompiled).
  expect(compiled.some((name) => name.endsWith("AgentMark.tsx:AgentMark"))).toBe(true);
  const mod = await import(built.outputs[0]!.path);

  const root = mod.createRoot(dom.window.document.getElementById("root"));
  await mod.act(async () =>
    root.render(mod.createElement(mod.AgentMark, { agent: "late-harness", size: 16, reserve: true })),
  );
  expect(dom.window.document.querySelector(".agent-mark-emoji")).toBeNull();

  await mod.act(async () =>
    mod.rememberHarnessIcons([{ id: "late-harness", iconSpec: { kind: "emoji", text: "🦊", source: "profile" } }]),
  );
  expect(dom.window.document.querySelector(".agent-mark-emoji")?.textContent).toBe("🦊");

  await mod.act(async () =>
    mod.rememberHarnessIcons([
      { id: "late-harness", iconSpec: { kind: "monogram", text: "LH", hue: 90, source: "default" } },
    ]),
  );
  expect(dom.window.document.querySelector(".agent-mark-monogram")?.textContent).toBe("LH");
  await mod.act(async () => root.unmount());
});

test("an SF Symbol icon draws the host's image, and its monogram until then", async () => {
  const entry = path.join(dir, "symbol-entry.tsx");
  writeFileSync(
    entry,
    [
      `export { AgentMark } from ${JSON.stringify(path.join(src, "agent-session/shared/AgentMark.tsx"))};`,
      `export { rememberHarnessIcons, setHarnessSymbolHost } from ${JSON.stringify(path.join(src, "agent-session/shared/harnessIcons.ts"))};`,
      `export { act, createElement } from ${JSON.stringify(path.join(webviews, "node_modules/react/index.js"))};`,
      `export { createRoot } from ${JSON.stringify(path.join(webviews, "node_modules/react-dom/client.js"))};`,
    ].join("\n"),
  );
  const built = await Bun.build({
    entrypoints: [entry],
    outdir: path.join(dir, "symbol"),
    target: "browser",
    format: "esm",
    define: { "process.env.NODE_ENV": '"development"' },
    plugins: [reactCompilerPlugin({ mode: "babel", srcRoot: src })],
  });
  expect(built.success).toBe(true);
  const mod = await import(built.outputs[0]!.path);
  const png = "data:image/png;base64,iVBORw0KGgo=";
  let answer: (src: string | null) => void = () => {};
  const asked: string[] = [];
  mod.setHarnessSymbolHost((name: string) => {
    asked.push(name);
    return new Promise<string | null>((resolve) => (answer = resolve));
  });
  mod.rememberHarnessIcons([
    { id: "hammer", iconSpec: { kind: "symbol", name: "hammer.fill", text: "H", hue: 10, source: "profile" } },
  ]);
  const root = mod.createRoot(dom.window.document.getElementById("root"));
  await mod.act(async () => root.render(mod.createElement(mod.AgentMark, { agent: "hammer", size: 16 })));
  expect(asked).toEqual(["hammer.fill"]);
  expect(dom.window.document.querySelector(".agent-mark-monogram")?.textContent).toBe("H");
  await mod.act(async () => answer(png));
  const symbol = dom.window.document.querySelector<HTMLElement>(".agent-mark-symbol");
  expect(symbol?.dataset.symbol).toBe("hammer.fill");
  expect(symbol?.getAttribute("style")).toContain(png);

  // A page may replace its host without remounting the icon component (Settings, tab reuse).
  // Resetting the image cache must make a mounted mark ask the new host for its image.
  const updatedPng = "data:image/png;base64,TkVXTkVX";
  let updatedReply: (src: string | null) => void = () => {};
  const newRequests: string[] = [];
  await mod.act(async () => {
    mod.setHarnessSymbolHost((name: string) => {
      newRequests.push(name);
      return new Promise<string | null>((resolve) => (updatedReply = resolve));
    });
  });
  expect(newRequests).toEqual(["hammer.fill"]);
  expect(dom.window.document.querySelector(".agent-mark-monogram")?.textContent).toBe("H");
  await mod.act(async () => updatedReply(updatedPng));
  expect(dom.window.document.querySelector(".agent-mark-symbol")?.getAttribute("style")).toContain(updatedPng);

  await mod.act(async () => root.unmount());
  mod.setHarnessSymbolHost(undefined);
});
