// Scratch (never committed): renders the subagent tray's panel variants from a built gallery and
// prints each PNG as base64 chunks, since the fast-checks job returns only its log.
import { chromium } from "playwright";
import path from "node:path";

const [dir, label, ...cases] = process.argv.slice(2);
const root = path.resolve(dir!);
const server = Bun.serve({
  port: 0,
  fetch(request) {
    const url = new URL(request.url);
    return new Response(Bun.file(path.join(root, decodeURIComponent(url.pathname))));
  },
});
const browser = await chromium.launch();
for (const spec of cases) {
  const [variant, scheme, arm, tall] = spec.split(":");
  const page = await browser.newPage({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2 });
  const params = new URLSearchParams({
    entry: "agent-pane.subagent-tray",
    variant: variant!,
    colorScheme: scheme!,
    frame: "component",
    width: "720",
    height: tall || "820",
  });
  if (arm) {
    params.set("exp", "subagent-tray-panel");
    params.set("arm", arm);
  }
  await page.goto(`http://127.0.0.1:${server.port}/frame.html?${params}`);
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady, null, { timeout: 60_000 });
  await page.evaluate(() => { for (const a of document.getAnimations()) if (Number.isFinite(a.effect?.getComputedTiming().endTime as number)) a.finish(); });
  // A wheel over the tray scrolls whatever scrolls there: on base the tray itself, header included.
  const info = await page.evaluate(() => {
    const tray = document.querySelector<HTMLElement>(".acpmux-running-tray");
    if (!tray) return "no tray";
    tray.scrollTop = 100_000;
    const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head");
    const box = tray.getBoundingClientRect();
    const rect = head?.getBoundingClientRect();
    return `play=${document.documentElement.dataset.galleryPlay} ${JSON.stringify([(window as any).cmuxGalleryPlayReport?.error, ...((window as any).cmuxGalleryPlayReport?.steps ?? []).flatMap((s: any) => s.problems)]).slice(0, 400)} trayScroll=${tray.scrollTop} head=${rect ? Math.round(rect.top - box.top) : "none"}`;
  });
  console.log(`INFO ${label} ${spec} ${info}`);
  const dock = page.locator(".acpmux-dock");
  const shot = await dock.screenshot();
  const name = `${variant}-${arm || label}-${scheme}${tall ? `-h${tall}` : ""}`;
  const text = shot.toString("base64");
  const hash = new Bun.CryptoHasher("sha256").update(shot).digest("hex");
  let seq = 0;
  for (let at = 0; at < text.length; at += 1000) {
    process.stdout.write(`\nIMG ${name} ${seq} ${text.slice(at, at + 1000)} .\n`);
    seq += 1;
  }
  process.stdout.write(`\nEND ${name} ${seq} ${hash} .\n`);
  await Bun.sleep(50);
  await page.close();
}
await browser.close();
server.stop();
