// The tray's chat (subagents/usePaneTray.ts `stepTrayChat`) steps on every render, as App.tsx
// stepped its refs before the tray left it, also on a render that comes right after an abandoned
// one with the same inputs as the last commit. The card reads `shown.current` as it detaches
// (trayMotion.tsx): its exit plays only while its own chat still shows. Built as the pane ships it,
// with the React Compiler on (scripts/agent-pane/bundle.mjs), which caches a call whose value the
// hook returns on its arguments: such a cached step would skip that render and leave `shown` on the
// abandoned render's chat. A concurrent root: chat B renders in a transition that suspends and is
// never committed, then chat A renders again, urgently, with the inputs of the last commit.
import { afterAll, expect, test } from "bun:test";
import { build } from "esbuild";
import { JSDOM, VirtualConsole } from "jsdom";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { reactCompilerPlugin } from "../scripts/agent-pane/reactCompilerPlugin.mjs";
import { teardownDom } from "./support/domTeardown";

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
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const out = mkdtempSync(path.join(tmpdir(), "pane-tray-chat-"));

afterAll(async () => {
  rmSync(out, { recursive: true, force: true });
  await teardownDom(saved, { scope });
});

test("the tray's chat steps back on the render after an abandoned one, with the React Compiler on", async () => {
  const webviews = path.resolve(import.meta.dir, "..");
  const compiled = new Set<string>();
  await build({
    stdin: {
      contents: [
        'export { usePaneTrayCard } from "./src/agent-session/acpmux/subagents/usePaneTray";',
        'export { createRoot } from "react-dom/client";',
        'export { act, createElement, startTransition, Suspense, use, useLayoutEffect } from "react";',
      ].join("\n"),
      resolveDir: webviews,
      loader: "ts",
    },
    bundle: true,
    format: "esm",
    platform: "browser",
    define: { "process.env.NODE_ENV": '"development"' },
    outfile: path.join(out, "tray.js"),
    // The chat fonts its imports reach (chatFonts/faces.ts) are not drawn here.
    loader: { ".woff2": "empty" },
    logLevel: "silent",
    plugins: [
      reactCompilerPlugin({
        mode: "babel",
        srcRoot: path.join(webviews, "src"),
        onCompiled: (id: string) => compiled.add(id),
      }),
    ],
  });
  expect(compiled).toContain("agent-session/acpmux/subagents/usePaneTray.ts:usePaneTrayCard");

  const R = await import(path.join(out, "tray.js"));
  const never = new Promise<never>(() => {});
  const noItems: never[] = [];
  const counted = { current: {} };
  const showToolRow = () => false;
  /// What each render's hook left in `shown`, and what each commit shows.
  const rendered: (string | undefined)[] = [];
  const committed: (string | undefined)[] = [];
  function Waits() {
    R.use(never);
    return null;
  }
  function Probe({ chat, waits }: { chat: string; waits: boolean }) {
    const card = R.usePaneTrayCard({
      quick: false,
      freshView: false,
      trayList: noItems,
      trayFinished: noItems,
      hatPlan: undefined,
      shownSessionId: chat,
      chatRead: true,
      trayPlacement: "tray",
      counted,
      showToolRow,
    });
    rendered.push(card.trayChat.current);
    R.useLayoutEffect(() => {
      committed.push(card.trayChat.current);
    });
    return R.createElement(R.Suspense, { fallback: null }, waits ? R.createElement(Waits) : null);
  }

  const root = R.createRoot(dom.window.document.getElementById("root")!);
  await R.act(async () => root.render(R.createElement(Probe, { chat: "A", waits: false })));
  expect(committed).toEqual(["A"]);
  // Chat B in a transition: the shown boundary would fall back, so the render waits and never commits.
  await R.act(async () => R.startTransition(() => root.render(R.createElement(Probe, { chat: "B", waits: true }))));
  expect(rendered, "the transition rendered chat B").toContain("B");
  expect(committed, "and never committed it").toEqual(["A"]);
  // Chat A again, urgently, with the inputs of the last commit: the step runs, so the card reads A.
  rendered.length = 0;
  await R.act(async () => root.render(R.createElement(Probe, { chat: "A", waits: false })));
  expect(rendered[0], "the render after the abandoned one").toBe("A");
  expect(committed.at(-1), "shown as A commits").toBe("A");
  await R.act(async () => root.unmount());
});
