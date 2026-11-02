// The scrollbar thumb while a long chat pages its history in from the bottom up.
//
// Leo (2026-10-26): "When I scroll up really far and the thing is loading, okay, the thumb just
// jitters like crazy because it's loading upwards."
//
// The real pane on the in-page mock daemon (`?mock`) opens a seeded long chat (debug loadSeed) at
// its latest message, and the wheel scrolls it up a step a frame. While the reader only scrolls up,
// the thumb only moves up: a frame where it moves down, or resizes, is a page that landed and moved
// it (conversation/olderReserve.ts holds room for those pages instead).
//
//   CMUX_BROWSER_TESTS=1 bun scripts/agent-pane/thumb-paging.harness.ts
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium } from "playwright";
import { stopDevServer } from "../../test/support/devServer";
import { warmDevServer } from "../../test/support/warmDevServer";

if (process.env.CMUX_BROWSER_TESTS !== "1") {
  console.log("thumb-paging: set CMUX_BROWSER_TESTS=1 to run");
  process.exit(0);
}
const TURNS = 400;
const STEPS = 500;
const webviews = path.resolve(import.meta.dir, "../..");
const port = await new Promise<number>((resolve) => {
  const probe = net.createServer().listen(0, "127.0.0.1", () => {
    const { port } = probe.address() as net.AddressInfo;
    probe.close(() => resolve(port));
  });
});
const server = spawn(
  path.join(webviews, "node_modules/.bin/vp"),
  ["dev", "--config", "vite.config.acpmux-pane.mjs", "--port", String(port), "--strictPort"],
  { cwd: webviews, stdio: ["ignore", "pipe", "pipe"] },
);
const base = `http://127.0.0.1:${port}`;
const browser = await (async () => {
  await new Promise<void>((resolve, reject) => {
    const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
    server.stdout!.on("data", onData);
    server.stderr!.on("data", onData);
    server.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
  });
  await warmDevServer(base, "/?mock");
  return chromium.launch({ headless: true });
})();
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
  await page.goto(`${base}/?mock`);
  await page.waitForFunction(() => Boolean((window as { cmuxAcpmuxDebug?: unknown }).cmuxAcpmuxDebug), null, {
    timeout: 30_000,
  });
  const seeded = await page.evaluate(
    (turns) =>
      (
        window as unknown as { cmuxAcpmuxDebug: { loadSeed(turns: number): Promise<Record<string, unknown>> } }
      ).cmuxAcpmuxDebug.loadSeed(turns),
    TURNS,
  );
  assert.ok(!("error" in seeded), JSON.stringify(seeded));
  const box = (await page.locator(".acpmux-scroll").boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  const frames: { position: number; size: number; top: number; height: number }[] = [];
  for (let step = 0; step < STEPS; step += 1) {
    await page.mouse.wheel(0, -500);
    const frame = await page.evaluate(
      () =>
        new Promise<{ position: number; size: number; top: number; height: number }>((resolve) =>
          requestAnimationFrame(() =>
            requestAnimationFrame(() => {
              const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              const range = Math.max(1, node.scrollHeight - node.clientHeight);
              resolve({
                position: node.scrollTop / range,
                size: node.clientHeight / node.scrollHeight,
                top: node.scrollTop,
                height: node.scrollHeight,
              });
            }),
          ),
        ),
    );
    frames.push(frame);
    if (frame.top === 0 && frames.at(-2)?.top === 0 && frames.at(-3)?.top === 0) break;
  }
  // A frame where the thumb moved down while the reader scrolled up, or changed size.
  const jumps = frames.slice(1).filter((frame, index) => frame.position > frames[index]!.position + 0.002);
  const resizes = frames.slice(1).filter((frame, index) => Math.abs(frame.size - frames[index]!.size) > 0.002);
  const grew = frames.slice(1).filter((frame, index) => frame.height !== frames[index]!.height).length;
  console.log(
    `THUMB_PAGING=${JSON.stringify({ steps: frames.length, heightChanges: grew, jumps: jumps.length, resizes: resizes.length, first: frames[0], last: frames.at(-1) })}`,
  );
  assert.ok(frames.length > 20, "the chat scrolled");
  // At most one step, when the last page leaves room over or the estimate runs out once.
  assert.ok(jumps.length <= 1, `the thumb moved down ${jumps.length} times while scrolling up`);
  assert.ok(resizes.length <= 1, `the thumb resized ${resizes.length} times while scrolling up`);
} finally {
  await browser.close();
  stopDevServer(server);
}
