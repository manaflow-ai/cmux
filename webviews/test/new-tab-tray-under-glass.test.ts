// cmux-web-test-timeout: 300
// l10n-allow-file: test fixtures.
// Nothing shows through the New Tab box's glass (Leo 2026-10-23, cx-ncc.113.116, over the desktop:
// "when the entire window is not there, when it's not in focus, just keeps showing that the desktop
// background has that transparen"). Codex's look tucks the folder and computer tray 10px under the
// box's top edge (composerLook.css); over a see-through window the box is glass, so the tucked tray
// showed through it as a band and a hairline across the field. The tray now stops at the box's top
// edge (composerStates.css masks the tuck), and the box stays glass.
//
// The real agent pane (the dev entry) in Chromium and WebKit, see-through, over a flat wallpaper
// colour, with a stand-in host and acpmux daemon. Reads the box's pixels in the tuck (its top 10px,
// inside the rim) and just under it: with nothing under the glass they are the same colour.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-tray-under-glass.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-tray-under-glass.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`new-tab-tray-under-glass: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab tray under glass", () => test("browsers", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const SHOTS = process.env.CMUX_TRAY_SHOTS;

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return { sessions: [] };
      case "_acpmux/harnesses":
        return { harnesses: { claude: { kind: "claude-stdio", family: "claude" } }, defaultHarness: "claude" };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// The Codex look's New Tab in a see-through window over a flat wallpaper colour.
  async function load(name: string): Promise<Page> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1000, height: 640 } });
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    const context = {
      kind: "agent",
      hotkeys: {},
      home: "/Users/you",
      projects: ["/Users/you/src/atlas"],
      host: "cosmic-gray",
      template: "minimal",
    };
    await page.addInitScript(
      ({ endpoint, context }) => {
        const w = window as unknown as Record<string, unknown>;
        w.__cmuxNewTabContext = context;
        localStorage.setItem("cmux.composer.look", "codex");
        const later = (value: unknown) => Promise.resolve({ ok: true, value });
        const answer = (request: { method: string }): unknown => {
          switch (request.method) {
            case "ready":
              return later({
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint,
                token: "t",
                newSession: true,
                newTab: context,
                machineName: "cosmic-gray",
              });
            case "newTab.context":
              return later({ newTab: context });
            case "project.list":
              return later({ projects: context.projects });
            case "transport.gesture":
              return later({ ticket: "gesture" });
            default:
              return later(null);
          }
        };
        w.webkit = { messageHandlers: { agentSession: { postMessage: answer } } };
      },
      { endpoint, context },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    // The desktop behind the window: one flat colour, so anything under the glass shows as a change.
    await page.addStyleTag({ content: "html, body { background: rgb(64, 120, 180) !important; }" });
    await page.locator(".nt-composer .nt-field").waitFor({ timeout: 30_000 });
    // What a see-through window sets (desktop.ts), once the page has its theme.
    await page.evaluate(() => document.documentElement.setAttribute("data-cmux-see-through", ""));
    await page
      .locator(".nt-composer[data-composer-look='codex'] > .nt-above .acpmux-location-picker")
      .first()
      .waitFor();
    return page;
  }

  test.each(engines.map(([name]) => name))("%s: the Codex look's tray never shows through the box", async (name) => {
    const page = await load(name);
    const { tray, box } = await page.evaluate(() => {
      const rect = (selector: string) => {
        const r = document.querySelector(selector)!.getBoundingClientRect();
        return { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
      };
      return { tray: rect(".nt-composer > .nt-above"), box: rect(".nt-composer > .nt-box") };
    });
    // The tray still tucks under the box: its place is unchanged.
    expect(tray.bottom).toBeGreaterThan(box.top);
    if (SHOTS) await page.locator(".nt-composer").screenshot({ path: `${SHOTS}-${name}.png` });
    // Columns over the tray's middle, inside the box's rim: rows in the tuck, and rows under it.
    const x = Math.round((tray.left + tray.right) / 2) - 40;
    const clip = { x, y: Math.round(box.top) - 2, width: 80, height: Math.round(tray.bottom - box.top) + 12 };
    const png = await page.screenshot({ clip });
    const rows = await page.evaluate(
      async ({ data, height }) => {
        const image = new Image();
        image.src = `data:image/png;base64,${data}`;
        await image.decode();
        const canvas = document.createElement("canvas");
        canvas.width = image.naturalWidth;
        canvas.height = image.naturalHeight;
        const context = canvas.getContext("2d")!;
        context.drawImage(image, 0, 0);
        const scale = image.naturalHeight / height;
        const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
        // Each CSS row's mean colour.
        return Array.from({ length: height }, (_, row) => {
          const y = Math.min(canvas.height - 1, Math.round((row + 0.5) * scale));
          let r = 0;
          let g = 0;
          let b = 0;
          for (let column = 0; column < canvas.width; column += 1) {
            const at = (y * canvas.width + column) * 4;
            r += pixels[at]!;
            g += pixels[at + 1]!;
            b += pixels[at + 2]!;
          }
          return [r / canvas.width, g / canvas.width, b / canvas.width].map(Math.round);
        });
      },
      { data: png.toString("base64"), height: clip.height },
    );
    await page.close();
    // The first row is the tray's, just over the box's top edge; then the box's rim; then the box.
    const [over, , , ...inside] = rows;
    const below = inside.at(-1)!;
    const differs = inside
      .slice(0, -1)
      .map((row) => Math.max(...row.map((value, index) => Math.abs(value - below[index]!))));
    console.info(
      `${name}: over the edge ${over!.join(",")}; box rows vs under the tuck ${below.join(",")}: ${differs.join(" ")}`,
    );
    // The tray reaches the box's edge: no strip of the wallpaper between them.
    const wallpaper = [64, 120, 180];
    expect(Math.max(...over!.map((value, index) => Math.abs(value - wallpaper[index]!)))).toBeGreaterThan(10);
    // Every row in the tuck is the box's own glass over the wallpaper, as under it (no band, no line).
    for (const difference of differs) expect(difference).toBeLessThanOrEqual(2);
  });
});
