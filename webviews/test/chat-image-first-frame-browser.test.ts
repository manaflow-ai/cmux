// Leo, 2026-11-14: "picture dimensions were forgotten then reloaded. this is another cause of
// layout shift". A sent prompt's image drew as a 120 px square slot while the pane read its bytes
// back from acpmux, then the bubble took the image's real shape (his 1280x228 screenshot: a
// 320x57 strip), moving everything under it, on every history load, scroll-back, re-mount and
// restart. acpmux now records each image's pixel size with the prompt (hub/image_size.rs), and
// sends an older record with its kept image's size, so the bubble's first frame is its last.
//
// The page mounts the real UserBubble, with the real stylesheets, from the record acpmux writes
// for that prompt (cmux-tui/crates/acpmux/src/hub/image_size_fixture.json, which
// image_size_tests.rs checks against acpmux field for field), read through the pane's own record
// parser (inlinePrompt.ts recordedPromptParts); support/chatImageFirstFrame.entry.tsx is the page
// half. The image's bytes come 400 ms late, as a read over the daemon socket does; the bubble's
// height on its first frame must equal its height once the image has drawn: on first mount, on a
// re-mount (the virtual list scrolling it back), and with every image the pane held forgotten (an
// app restart or update).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Heights = { first: number; painted: number; loaded: number; imageLoaded: boolean };

await requireBrowserLane("chat-image-first-frame-browser.test.ts", async () => {
  setDefaultTimeout(90_000);
  let browser: Browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    console.warn("chat-image-first-frame-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat image first frame", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const src = path.join(webviews, "src");
  const fixture = path.resolve(webviews, "../cmux-tui/crates/acpmux/src/hub/image_size_fixture.json");
  // Any id: the page's reader answers every image with the same late bytes.
  const msg = JSON.parse((await readFile(fixture, "utf8")).replaceAll("{{id}}", "a".repeat(64))).msg as {
    images: Record<string, unknown>[];
    inlineParts: Record<string, unknown>[];
  };

  let server: ReturnType<typeof Bun.serve> | undefined;
  beforeAll(async () => {
    const built = await Bun.build({
      entrypoints: [path.join(import.meta.dir, "support/chatImageFirstFrame.entry.tsx")],
      // An ES module, loaded as one: the pane's code reads `import.meta` (a classic script refuses it).
      format: "esm",
      target: "browser",
      define: { "process.env.NODE_ENV": '"production"' },
    });
    if (!built.success) throw new Error(built.logs.map(String).join("\n"));
    // The page's script is the entry's bundle alone; the build also emits assets (images, fonts) that are no script.
    const outputs = await Promise.all(
      built.outputs.map(async (o) => ({ path: o.path, kind: o.kind, text: await o.text() })),
    );
    const script = outputs
      .filter((o) => o.kind === "entry-point")
      .map((o) => o.text)
      .join("\n");
    const css = [
      ...(await Promise.all(
        [
          "agent-session/shared/styles.css",
          "agent-session/acpmux/styles.css",
          "agent-session/acpmux/conversation/conversation.css",
        ].map((file) => readFile(path.join(src, file), "utf8")),
      )),
      ...outputs.filter((o) => o.path.endsWith(".css")).map((o) => o.text),
    ].join("\n");
    const page =
      `<!doctype html><html><head><style>${css.replaceAll("</style", "<\\/style")}</style></head>` +
      `<body style="margin:0"><div id="chat" style="width:760px;display:flex"></div>` +
      `<script type="module">${script.replaceAll("</script", "<\\/script")}</script></body></html>`;
    server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch: () => new Response(page, { headers: { "content-type": "text/html" } }),
    });
  });
  afterAll(async () => {
    await server?.stop(true);
    await browser.close();
  });

  async function measure(record: unknown): Promise<Heights[]> {
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    // A page that fails to load its bundle says why, instead of a wait that times out.
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(String(error)));
    try {
      await page.goto(`http://127.0.0.1:${server!.port}/`);
      // A module script runs after the parse, not before `goto` resolves: wait for the page's hook.
      await page
        .waitForFunction(() => typeof (window as any).measureChatImage === "function", undefined, { timeout: 10_000 })
        .catch(() => {});
      const ready = await page.evaluate(() => typeof (window as any).measureChatImage === "function");
      expect({ ready, errors }).toEqual({ ready: true, errors: [] });
      return await page.evaluate((msg) => (window as any).measureChatImage(msg, 400), record);
    } finally {
      await page.close();
    }
  }

  test("an image's bubble has its final height on its first frame: mount, re-mount and restart", async () => {
    const passes = await measure(msg);
    // The record acpmux wrote before hub/image_size.rs: the same images with no size.
    const unsized = await measure({
      ...msg,
      images: msg.images.map(({ width: _w, height: _h, ...image }) => image),
      inlineParts: msg.inlineParts.map(({ width: _w, height: _h, ...part }) => part),
    });
    const deltas = (list: Heights[]) => list.map((p) => (p.loaded - p.first).toFixed(1)).join(", ");
    console.log(
      `chat-image-first-frame: bubble height change when the image lands (fresh, remount, restart): ` +
        `sized record ${deltas(passes)} px; unsized record ${deltas(unsized)} px`,
    );
    for (const [index, pass] of passes.entries()) {
      const name = ["fresh", "remount", "restart"][index];
      expect({ name, imageLoaded: pass.imageLoaded }).toEqual({ name, imageLoaded: true });
      expect({ name, first: pass.first }).toEqual({ name, first: pass.loaded });
      expect({ name, painted: pass.painted }).toEqual({ name, painted: pass.loaded });
    }
  });
});
