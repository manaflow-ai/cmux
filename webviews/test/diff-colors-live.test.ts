// Diff Colors (Settings > Diff Viewer, `diff.colors`) applies live. The agent pane gets it as the
// host's `diffColors` event, so the Changes view's added and removed lines follow it: Muted and
// Standard mark the page, Theme (and anything unknown) clears the mark. An open diff tab gets each
// change on the `cmux.diff.prefs` stream and recolors in place, without a reload.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

test("the host's Diff Colors marks the pane, and Theme or an unknown value clears it", async () => {
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const root = dom.window.document.documentElement;
  applyHostEvent({ kind: "diffColors", value: "standard" });
  expect(root.dataset.diffColors).toBe("standard");
  applyHostEvent({ kind: "diffColors", value: "muted" });
  expect(root.dataset.diffColors).toBe("muted");
  applyHostEvent({ kind: "diffColors", value: "theme" });
  expect(root.dataset.diffColors).toBeUndefined();
  applyHostEvent({ kind: "diffColors", value: "neon" });
  expect(root.dataset.diffColors).toBeUndefined();
});

test("an open diff tab recolors when the host streams a new Diff Colors", async () => {
  const { applyDiffViewerAppearance } = await import("../src/appearance");
  const { startPageDiffPrefs } = await import("../src/diff/page");
  applyDiffViewerAppearance({
    themes: { dark: { background: "#000000", foreground: "#ffffff", palette: { "2": "#00ff00" } } },
  });
  const style = dom.window.document.documentElement.style;
  expect(style.getPropertyValue("--cmux-diff-addition-fg-dark")).toBe("#00ff00");
  let push: ((value: unknown) => void) | undefined;
  const page = {
    subscribe: async (stream: string, onEvent: (value: unknown) => void) => {
      if (stream === "cmux.diff.prefs") push = onEvent;
      return () => undefined;
    },
  };
  await startPageDiffPrefs(page as never);
  push?.({ prefs: { colors: "standard" } });
  expect(style.getPropertyValue("--cmux-diff-addition-fg-dark")).toBe("#8fd88f");
  push?.({ prefs: { colors: "theme" } });
  expect(style.getPropertyValue("--cmux-diff-addition-fg-dark")).toBe("#00ff00");
});
