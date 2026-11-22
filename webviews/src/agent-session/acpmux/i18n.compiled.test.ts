// A language change re-renders pane strings in the React Compiler's output, under both
// compilers (CMUX_REACT_COMPILER=babel|oxc). The components are compiled and bundled the way
// scripts/agent-pane/bundle.mjs ships them, then rendered in jsdom: memoized strings must
// follow the language, not stay cached from the first render.
import { afterAll, describe, expect, test } from "bun:test";
import { build } from "esbuild";
import { JSDOM, VirtualConsole } from "jsdom";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { reactCompilerPlugin } from "../../../scripts/agent-pane/reactCompilerPlugin.mjs";

const webviews = path.resolve(import.meta.dir, "../../..");
const dom = new JSDOM("<!doctype html><body></body>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
let languages = ["en-US"];
Object.defineProperty(dom.window.navigator, "languages", { get: () => languages, configurable: true });
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "customElements",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  ResizeObserver: class {
    observe() {}
    disconnect() {}
  },
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");

type Components = Record<"TrustAsk" | "MessageCard" | "CommandRow" | "ToolGroupRow", React.FC<Record<string, unknown>>>;

/** The four components, compiled by `mode` and bundled; packages stay external. */
async function compiled(mode: "babel" | "oxc"): Promise<{ components: Components; code: string }> {
  const result = await build({
    stdin: {
      contents: [
        'export { TrustAsk } from "./TrustAsk";',
        'export { MessageCard } from "./conversation/MessageCard";',
        'export { CommandRow } from "./conversation/CommandRow";',
        'export { ToolGroupRow } from "./conversation/ToolGroupRow";',
      ].join("\n"),
      resolveDir: import.meta.dir,
      sourcefile: "entry.ts",
      loader: "ts",
    },
    bundle: true,
    write: false,
    format: "esm",
    platform: "browser",
    target: "es2022",
    // Packages load from node_modules at run time: one React instance, and only first-party code compiled.
    packages: "external",
    logLevel: "silent",
    plugins: [reactCompilerPlugin({ mode, srcRoot: path.join(webviews, "src") })],
  });
  const code = result.outputFiles[0]!.text;
  // Inside webviews/, so `react` resolves to the same copy react-dom/client uses here.
  const dir = path.join(webviews, "node_modules/.cache/cmux-i18n-compiled");
  await mkdir(dir, { recursive: true });
  const file = path.join(dir, `${mode}-${process.pid}.mjs`);
  await writeFile(file, code);
  return { components: (await import(file)) as Components, code };
}

const command = (line: string, fields: Record<string, unknown> = {}) => ({
  kind: "tool",
  text: line,
  tool: { id: line, title: line, kind: "execute", status: "completed", command: line, ...fields },
});

for (const mode of ["babel", "oxc"] as const) {
  describe(`compiled with ${mode}`, () => {
    test("a language change re-renders memoized strings", async () => {
      languages = ["en-US"];
      dom.window.dispatchEvent(new dom.window.Event("languagechange"));
      const { components, code } = await compiled(mode);
      expect(code).toContain("react/compiler-runtime");
      const { TrustAsk, MessageCard, CommandRow, ToolGroupRow } = components;
      const container = dom.window.document.body.appendChild(dom.window.document.createElement("div"));
      const root = createRoot(container);
      try {
        const noop = () => {};
        const tree = createElement(
          "div",
          null,
          createElement(TrustAsk, {
            ask: { cwd: "/repo/app", state: "ask" },
            agent: "Codex",
            onTrust: noop,
            onDistrust: noop,
            onUndo: noop,
          }),
          createElement(MessageCard, {
            item: command("cmux send"),
            message: { channel: "agent", text: "hello" },
          }),
          createElement(CommandRow, { item: command("make", { startedAt: 0, endedAt: 4200 }) }),
          createElement(ToolGroupRow, {
            kind: "commands",
            items: [command("ls"), command("make")],
          }),
        );
        await act(async () => root.render(tree));
        const english = container.textContent ?? "";
        for (const text of ["Trust", "Codex can edit and run code in app", "This agent", "4.2s", "Ran 2 commands"])
          expect(english).toContain(text);

        languages = ["ja-JP"];
        await act(async () => {
          dom.window.dispatchEvent(new dom.window.Event("languagechange"));
        });
        const japanese = container.textContent ?? "";
        for (const text of ["信頼する", "Codex は app でコードを編集・実行できます", "このエージェント", "4.2秒"])
          expect(japanese).toContain(text);
        expect(japanese).toContain("2 件のコマンドを実行しました");
        expect(japanese).not.toContain("This agent");
      } finally {
        await act(async () => root.unmount());
        container.remove();
        languages = ["en-US"];
        dom.window.dispatchEvent(new dom.window.Event("languagechange"));
      }
    });
  });
}
