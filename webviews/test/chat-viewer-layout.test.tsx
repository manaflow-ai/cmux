// The real mock pane keeps the bottom stack on the transcript's column as its right panel changes.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-viewer-layout.test.tsx", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let base = "";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function measure(page: Page) {
    // Let the pane's ResizeObservers measure the transcript at its new width before reading it.
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page.evaluate(() => {
      const box = (selector: string, content = false) => {
        const element = document.querySelector(selector)!;
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        const left = rect.left + (content ? parseFloat(style.paddingLeft) : 0);
        const right = rect.right - (content ? parseFloat(style.paddingRight) : 0);
        return { left, right, top: rect.top, bottom: rect.bottom, center: (left + right) / 2 };
      };
      return {
        transcript: box(".acpmux-row.acpmux-assistant"),
        composer: box(".acpmux-composer-box"),
        prDock: document.querySelector(".acpmux-pr-dock") ? box(".acpmux-pr-dock", true) : null,
        asks: document.querySelector(".acpmux-asks-stack") ? box(".acpmux-asks-stack", true) : null,
        panel: document.querySelector(".acpmux-file-viewer, .acpmux-summary-card[data-placement=inline]")
          ? box(".acpmux-file-viewer, .acpmux-summary-card[data-placement=inline]")
          : null,
      };
    });
  }

  async function mockFiles(page: Page) {
    await page.evaluate(() => {
      // Listing uses callNative's direct actions; path chips use postNative instead.
      window.cmuxAcpmuxActions!["file.list"] = async () => ({ entries: [{ name: "note.txt", kind: "file" }] });
      window.webkit = {
        messageHandlers: {
          agentSession: {
            postMessage: async ({ method, params }: { method: string; params: Record<string, unknown> }) => ({
              ok: true,
              value:
                method === "link.readPath"
                  ? { kind: "text", path: String(params.path), text: "A note.", bytes: 7, truncated: false }
                  : {},
            }),
          },
        },
      } as typeof window.webkit;
    });
  }

  for (const entry of ["new chat", "new tab"]) {
    for (const via of ["Files", "path"]) {
      test(`${entry}: inherited Thread details opens ${via} without a transient chat shift`, async () => {
        const page = await browser!.newPage({ viewport: { width: 1600, height: 900 } });
        try {
          await page.addInitScript((newTab) => {
            localStorage.removeItem("cmux.acpmux.summaryPanel");
            window.cmuxAcpmuxActions = {
              ready: async () => ({
                protocolVersion: 1,
                transport: "mock",
                newSession: true,
                ...(newTab ? { newTab: { kind: "agent" } } : {}),
              }),
            };
            // A completed first turn: streaming must not change geometry during the measurement.
            window.cmuxAcpmuxMockScript = {
              steps: [
                {
                  update: {
                    sessionUpdate: "tool_call",
                    toolCallId: "inspect-project",
                    kind: "think",
                    title: "Check the project",
                    status: "completed",
                  },
                },
                {
                  update: {
                    sessionUpdate: "agent_message_chunk",
                    content: {
                      type: "text",
                      text:
                        "Read [note.txt](/chat/note.txt).\n\n" +
                        "A reply that wraps when Files takes the right column. ".repeat(80),
                    },
                  },
                },
              ],
            };
          }, entry === "new tab");
          await page.goto(`${base}/`);
          if (entry === "new tab") await page.locator(".nt-field").waitFor();
          await page.waitForFunction(() => !!window.cmuxAcpmuxActions?.["chat.new"]);
          await page.evaluate(() => window.cmuxAcpmuxDebug!.newChat("claude", "/chat"));
          await page.locator(".acpmux-empty").waitFor();
          await page.locator(".acpmux-summary-button").click();
          await page.locator('.acpmux-summary-card[data-placement="popover"]').waitFor();
          // A new session in the same pane keeps the open details choice from its empty view.
          await page.evaluate(() => window.cmuxAcpmuxDebug!.newChat("claude", "/chat"));
          await page.evaluate(() => window.cmuxAcpmuxDebug!.sendPrompt("Read note.txt"));
          await page.locator(".acpmux-row.acpmux-assistant").waitFor();
          await page.locator('.acpmux-summary-card[data-placement="inline"]').waitFor();
          await mockFiles(page);
          // Keep network/module loading out of the 600 ms layout window. The real lazy viewer
          // still mounts on the click, so its focus and panel lifecycle are exercised.
          await page.evaluate(async () => {
            const modules = ["/FilesView.tsx", "/FileViewer.tsx"];
            await Promise.all(modules.map((module) => import(/* @vite-ignore */ module)));
          });
          await measure(page);
          let selector = '.cv-chip.is-path[data-path="/chat/note.txt"]';
          if (via === "Files") {
            await page.locator('.acpmux-header-tool[aria-label="Chat actions"]').click();
            const item = page.getByRole("menuitem", { name: "Files", exact: true });
            await item.waitFor();
            selector = '[role="menuitem"]';
          }
          // Install the sampler before the click. Include the synchronous starting box and every
          // painted frame, rather than waiting for the viewer and missing an intermediate layout.
          const frames = await page.evaluate(
            ({ selector, via }) =>
              new Promise<
                Array<{
                  at: number;
                  transcript: Record<string, number>;
                  composer: Record<string, number>;
                  details: boolean;
                  viewer: boolean;
                }>
              >((resolve) => {
                const box = (query: string) => {
                  const r = document.querySelector(query)!.getBoundingClientRect();
                  return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, center: (r.left + r.right) / 2 };
                };
                const frames: Array<{
                  at: number;
                  transcript: Record<string, number>;
                  composer: Record<string, number>;
                  details: boolean;
                  viewer: boolean;
                }> = [];
                const start = performance.now();
                const sample = (at: number) =>
                  frames.push({
                    at: at - start,
                    transcript: box(".acpmux-row.acpmux-assistant"),
                    composer: box(".acpmux-composer-box"),
                    details: !!document.querySelector(".acpmux-summary-card:not([aria-hidden])"),
                    viewer: !!document.querySelector(".acpmux-file-viewer"),
                  });
                sample(start);
                const target = [...document.querySelectorAll<HTMLElement>(selector)].find(
                  (node) => via !== "Files" || node.textContent?.trim() === "Files",
                )!;
                target.click();
                const tick = (at: number) => {
                  sample(at);
                  if (at - start < 600) requestAnimationFrame(tick);
                  else resolve(frames);
                };
                requestAnimationFrame(tick);
              }),
            { selector, via },
          );
          await page.locator(via === "Files" ? ".acpmux-files" : ".acpmux-file-viewer:not(.acpmux-files)").waitFor();
          expect(frames.length).toBeGreaterThan(10);
          expect(frames.at(-1)!.at).toBeGreaterThanOrEqual(600);
          const first = frames[0]!;
          const last = frames.at(-1)!;
          expect(first.details).toBe(true);
          expect(first.viewer).toBe(false);
          expect(last.viewer).toBe(true);
          expect(Math.abs(last.transcript.center - last.composer.center)).toBeLessThanOrEqual(1);
          for (const frame of frames.slice(1)) {
            expect(frame.details, JSON.stringify(frame)).toBe(false);
            expect(
              Math.abs(frame.transcript.center - frame.composer.center),
              JSON.stringify(frame),
            ).toBeLessThanOrEqual(1);
            for (const name of ["transcript", "composer"] as const) {
              for (const edge of ["left", "right", "top", "bottom"]) {
                const a = first[name][edge]!;
                const b = last[name][edge]!;
                const value = frame[name][edge]!;
                expect(value, `${name}.${edge}: ${JSON.stringify(frames)}`).toBeGreaterThanOrEqual(Math.min(a, b) - 1);
                expect(value, `${name}.${edge}: ${JSON.stringify(frames)}`).toBeLessThanOrEqual(Math.max(a, b) + 1);
              }
            }
          }
        } finally {
          await page.close();
        }
      });
    }
  }

  for (const { width, viewport, viewerWidth } of [
    { width: 900, viewport: 900 },
    { width: 1600, viewport: 1600 },
    // A pane embedded in a wider page must use its own breakpoint, just as the transcript does.
    { width: 760, viewport: 1600 },
    // All three consumers must follow the viewer's actual width, rather than a second literal.
    { width: 900, viewport: 1600, viewerWidth: 360 },
  ]) {
    for (const session of [undefined, "mock-tab-strip"]) {
      test(`${session ?? "worked turn"}: bottom stack follows every panel at pane=${width}, page=${viewport}, viewer=${viewerWidth ?? 320}px`, async () => {
        const page = await browser!.newPage({ viewport: { width: viewport, height: 900 } });
        try {
          await page.addInitScript(() => localStorage.setItem("cmux.acpmux.summaryPanel", "hidden"));
          await page.goto(`${base}/?mock`);
          await page.locator(".acpmux-row.acpmux-assistant").first().waitFor();
          await page.locator(".acpmux-composer-box").waitFor();
          if (session) {
            await page.evaluate((id) => window.cmuxAcpmuxDebug!.selectSession(id), session);
            await page.locator(".acpmux-asks-stack").waitFor();
          } else await page.locator(".acpmux-pr-dock").waitFor();
          await page.addStyleTag({
            content: `#root{width:${width}px}${viewerWidth ? `.acpmux-main,.acpmux-stage{--acpmux-viewer-width:${viewerWidth}px}` : ""}`,
          });
          // Only the host's file reads are fixture data; panel state and layout use the real App.
          await mockFiles(page);
          const states: Record<string, Awaited<ReturnType<typeof measure>>> = {};
          states.closed = await measure(page);
          await page.locator(".acpmux-summary-button").click();
          await page.locator(".acpmux-summary-card").waitFor();
          states.details = await measure(page);
          // Files sits in the header's Chat actions menu unless the person pinned it as a quick action.
          await page.locator('.acpmux-header-tool[aria-label="Chat actions"]').click();
          await page.getByRole("menuitem", { name: "Files", exact: true }).click();
          await page.locator(".acpmux-files-row").waitFor();
          states.files = await measure(page);
          await page.getByRole("button", { name: "note.txt", exact: true }).click();
          await page.locator(".acpmux-file-viewer:not(.acpmux-files)").waitFor();
          states.file = await measure(page);
          for (const [state, { transcript, composer, prDock, asks, panel }] of Object.entries(states)) {
            for (const [name, rect] of Object.entries({ composer, prDock, asks })) {
              if (!rect) continue;
              expect(
                Math.abs(rect.center - transcript.center),
                `${state} ${name}: ${JSON.stringify(states[state])}`,
              ).toBeLessThanOrEqual(1);
              if (panel) {
                // Below the side-column breakpoint the viewer covers the stage above the dock.
                const separated =
                  rect.right <= panel.left + 1 || rect.top >= panel.bottom - 1 || rect.bottom <= panel.top + 1;
                expect(separated, `${state} ${name} does not overlap the panel`).toBe(true);
              }
            }
          }
        } finally {
          await page.close();
        }
      });
    }
  }
});
