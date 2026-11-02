// The changes view's header in a narrow pane (build capture 8603d77b, toolbar-diffviewer flow):
// a turn's View changes opened the diff in a right split about 275px wide, and there the scope
// pill ("Last turn ▾ +26 -2") drew on top of the toolbar's Commit and Push, the two rows' words
// printed over each other. The pill's wrapper may shrink (min-width:0) but the nowrap pill inside
// it did not, so it ran out of its box under the toolbar. Every control in the header now keeps a
// box of its own at every pane width: none overlaps another, and the pill stays inside its box.
//
// The header is the real DiffPanel's, rendered in jsdom with a git source (Commit, Push ↑1) and a
// turn's files, then laid out in real Chromium from the pane's stylesheets. CI fails the file when
// Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("changes-header-narrow-browser.test.tsx", async () => {
  setDefaultTimeout(60_000);
  const { JSDOM, VirtualConsole } = await import("jsdom");
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
    localStorage: dom.window.localStorage,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    customElements: dom.window.customElements,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  // Pierre's registered elements read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (
      /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
      !(key in scope)
    )
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);

  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { DiffPanel } = await import("../src/agent-session/acpmux/DiffPanel");
  const { toolFiles } = await import("../src/agent-session/acpmux/diff");
  const { chromium } = await import("playwright");

  const lines = (count: number, edit?: (line: number) => string | undefined) =>
    Array.from({ length: count }, (_, index) => edit?.(index + 1) ?? `line ${index + 1}`).join("\n");
  const files = toolFiles([
    {
      id: "edit-retry",
      kind: "edit",
      title: "Edit retry.ts",
      status: "completed",
      diffs: [
        {
          path: "/repo/src/retry.ts",
          oldText: lines(4),
          newText: lines(16, (line) => (line > 4 ? `added ${line}` : undefined)),
        },
      ],
    },
  ] as never);
  // A repository on a branch one commit ahead of its upstream: the toolbar shows Commit and Push ↑1.
  const source = {
    diff: async () => ({ files: [] }),
    status: async () => ({
      detached: false,
      branch: "fleet/retry",
      head: "abc123",
      upstream: "origin/fleet/retry",
      ahead: 1,
      behind: 0,
    }),
    commit: async () => ({}),
    push: async () => ({}),
  };

  const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(<DiffPanel files={files} onClose={() => {}} source={source} />));
  for (let step = 0; step < 3; step++) await settle();
  const header = container.querySelector("header.acpmux-diff-header")!.outerHTML;
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/changes/git.css",
    "agent-session/acpmux/changes/changes.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8").replace(/^@import[^;]*;$/gm, ""))
    .join("\n");

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  describe("the changes header in a narrow pane", () => {
    test("renders the toolbar's Commit and Push beside the scope pill", () => {
      expect(header).toContain("acpmux-diff-scope");
      expect(header).toContain('data-tool="commit"');
      expect(header).toContain("acpmux-diff-counts");
    });
    for (const width of [275, 360, 520])
      test(`no control overlaps another at ${width}px`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 400 } });
        try {
          await page.setContent(
            `<style>${css} body { margin: 0 }</style>` +
              `<div style="position: relative; width: ${width}px; height: 400px"><section class="acpmux-diff-panel">${header}</section></div>`,
          );
          const boxes = await page.evaluate(() => {
            const box = (name: string, el: Element) => {
              const r = el.getBoundingClientRect();
              return { name, left: r.left, right: r.right, top: r.top, bottom: r.bottom };
            };
            const head = document.querySelector("header.acpmux-diff-header")!;
            const pill = head.querySelector("button.acpmux-diff-scope")!;
            return {
              controls: [
                box("back", head.querySelector(".acpmux-diff-back")!),
                box("scope pill", pill),
                box("toolbar", head.querySelector(".acpmux-diff-tools")!),
              ],
              // The pill's words and counts stay inside the pill.
              pill: box("scope pill", pill),
              pillParts: [...pill.children].map((child) => box(child.className || child.tagName, child)),
            };
          });
          const overlaps: string[] = [];
          boxes.controls.forEach((a, i) =>
            boxes.controls.slice(i + 1).forEach((b) => {
              if (a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5)
                overlaps.push(`${a.name} overlaps ${b.name}`);
            }),
          );
          expect(overlaps).toEqual([]);
          const outside = boxes.pillParts
            .filter((part) => part.right > boxes.pill.right + 0.5)
            .map((part) => part.name);
          expect(outside).toEqual([]);
        } finally {
          await page.close();
        }
      });
  });
});
