// Scratch (not committed): the composer field's own scroll while a draft grows, per painted frame.
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, webkit } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { COMPOSER_MD_FIELD } from "../src/agent-session/acpmux/composerSelectors";

const [heightArg, linesArg, out, widthArg] = process.argv.slice(2);
const HEIGHT = Number(heightArg ?? 400);
const LINES = Number(linesArg ?? 8);
const WIDTH = Number(widthArg ?? 700);
const outDir = out ?? "/tmp/anchor-field";
mkdirSync(outDir, { recursive: true });
const ENGINE = process.env.ANCHOR_ENGINE === "chromium" ? chromium : webkit;
const ENTRY = "agent-pane.transcript-composer-grow";
const webviews = path.resolve(import.meta.dir, "..");
const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
  logLevel: "error",
});
await vite.listen();
const browser = await ENGINE.launch({ headless: true });
await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "bottom-one-line" } });
const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 1 });
await installPaintedFrames(page);
const port = (vite.httpServer!.address() as { port: number }).port;
await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "bottom-one-line" })}`);
await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
await page.waitForSelector(".acpmux-scroll .acpmux-row");
await page.locator(`${COMPOSER_MD_FIELD} .ProseMirror`).click();
await page.keyboard.press("Control+End");
await page.waitForTimeout(500);
await page.evaluate((sel) => {
  const own = window as any;
  own.__frames = [];
  own.__stop = window.cmuxAfterPaint(() => {
    const field = document.querySelector<HTMLElement>(sel)!;
    const s = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const rows = s.querySelectorAll<HTMLElement>(".acpmux-row");
    const box = document.querySelector<HTMLElement>(".acpmux-composer-box")!;
    const sel2 = getSelection();
    let caret = -1;
    if (sel2 && sel2.rangeCount) {
      const r = sel2.getRangeAt(0).getClientRects();
      const rr = r[r.length - 1] ?? (sel2.focusNode as HTMLElement)?.parentElement?.getBoundingClientRect();
      if (rr) caret = Math.round(field.getBoundingClientRect().bottom - rr.bottom);
    }
    own.__frames.push({
      t: Math.round(performance.now()),
      fTop: Math.round(field.scrollTop),
      fMax: Math.round(field.scrollHeight - field.clientHeight),
      fH: Math.round(field.getBoundingClientRect().height),
      caretBelowFieldBottom: caret,
      gap: Math.round(box.getBoundingClientRect().top - rows[rows.length - 1]!.getBoundingClientRect().bottom),
      sTop: Math.round(s.scrollTop),
    });
  });
}, COMPOSER_MD_FIELD);
if (process.env.MODE === "wrap")
  await page.keyboard.type(" and then a very long continuation of the sentence that has to wrap onto further lines ".repeat(LINES), { delay: 8 });
else if (process.env.MODE === "paste")
  await page.evaluate((n) => {
    const el = document.querySelector<HTMLElement>(".acpmux-composer-box .ProseMirror")!;
    const data = new DataTransfer();
    data.setData("text/plain", Array.from({ length: n }, (_, i) => `\npasted ${i + 2}`).join(""));
    el.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  }, LINES);
else for (let line = 2; line <= LINES; line++) {
  await page.keyboard.press("Shift+Enter");
  await page.keyboard.type(`line ${line} of the draft`, { delay: 15 });
  if (process.env.SHOTS) await page.screenshot({ path: path.join(outDir, `line${line}.png`) });
}
await page.waitForTimeout(600);
const frames = await page.evaluate(() => {
  (window as any).__stop();
  return (window as any).__frames;
});
writeFileSync(path.join(outDir, "frames.json"), JSON.stringify(frames));
let prev = "";
frames.forEach((f: any, i: number) => {
  const k = JSON.stringify({ ...f, t: 0 });
  if (k !== prev) console.log(i, JSON.stringify(f));
  prev = k;
});
await browser.close();
await vite.close();
process.exit(0);
