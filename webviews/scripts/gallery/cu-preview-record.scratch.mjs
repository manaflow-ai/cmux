// Scratch (not committed): record the Computer Use preview card's drag, hide, show and full size
// from the gallery, headless, for #50066's body. Writes $FAST_CHECKS_OUT/{stills/*.png,flow-*.webm}.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const out = path.resolve(process.env.FAST_CHECKS_OUT ?? "cu-preview-record");
fs.mkdirSync(path.join(out, "stills"), { recursive: true });
const root = path.resolve(import.meta.dir, "../..");
if (!fs.existsSync(path.join(root, "dist/gallery"))) {
  const build = spawn("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
  await new Promise((resolve, reject) => {
    build.once("error", reject);
    build.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`gallery build exited ${code}`))));
  });
}
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const baseUrl = `http://127.0.0.1:${server.httpServer.address().port}`;
const entry = "agent-pane.computer-use-preview";
const viewport = { width: 960, height: 640 };
const url = (variant, scheme) =>
  `${baseUrl}/frame.html?${new URLSearchParams({ entry, variant, colorScheme: scheme, width: "wide", frame: "component" })}`;
const ready = (page) =>
  page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 90_000 });
const wait = (page, ms) => page.waitForTimeout(ms);
// The matrix runner's trusted input driver (scripts/gallery-matrix/runner.ts), so plays act like a person.
const installInput = (page) =>
  page.exposeFunction("cmuxGalleryInput", async (action) => {
    const at = () => page.mouse.move(action.x ?? 0, action.y ?? 0);
    if (action.kind === "click") await page.mouse.click(action.x ?? 0, action.y ?? 0);
    else if (action.kind === "hover" || action.kind === "move") await at();
    else if (action.kind === "down") { await at(); await page.mouse.down(); }
    else if (action.kind === "up") { await at(); await page.mouse.up(); }
    else if (action.kind === "type") await page.keyboard.type(action.text ?? "");
    else if (action.kind === "press") await page.keyboard.press(action.text ?? "");
  });
const playReport = (page) =>
  page.evaluate(() => {
    const r = window.cmuxGalleryPlayReport;
    if (!r) return null;
    return { status: r.status, error: r.error, steps: (r.steps ?? []).map((s) => [s.step ?? s.name, s.status ?? s.ok, s.error]).slice(0, 12) };
  });
const under = (page, x, y) =>
  page.evaluate(([x, y]) => {
    const e = document.elementFromPoint(x, y);
    return e ? `${e.tagName}.${e.className} [${e.getAttribute("aria-label") ?? ""}]` : null;
  }, [x, y]);

const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
let failures = 0;
try {
  // Stills: every new variant, played where it has a play.
  const stills = ["beside-chat", "close", "hidden-chip", "hidden-chip-moved", "hidden-chip-show", "dragged",
    "dragged-middle", "drag", "full-size", "full-size-play", "full-size-done", "expanded"];
  for (const scheme of ["dark", "light"]) {
    for (const variant of stills) {
      const context = await browser.newContext({ viewport, deviceScaleFactor: 2, colorScheme: scheme });
      const page = await context.newPage();
      await installInput(page);
      try {
        await page.goto(url(variant, scheme), { waitUntil: "domcontentloaded" });
        await ready(page);
        const report = await playReport(page);
        if (report && report.status !== "pass") failures += 1;
        console.log(JSON.stringify({ play: variant, scheme, report }).slice(0, 1500));
        await wait(page, 900);
        const file = path.join(out, "stills", `${variant}-${scheme}.png`);
        await page.screenshot({ path: file });
        console.log(JSON.stringify({ still: variant, scheme, file: path.relative(out, file) }));
      } catch (error) {
        failures += 1;
        console.log(JSON.stringify({ still: variant, scheme, error: String(error).slice(0, 300) }));
      }
      await context.close();
    }
  }

  // The flow, one take per scheme: drag, click to enlarge, Full Size, hide to the chip, show, drag back.
  for (const scheme of ["dark", "light"]) {
    const dir = path.join(out, `video-${scheme}`);
    const context = await browser.newContext({
      viewport,
      deviceScaleFactor: 1,
      colorScheme: scheme,
      recordVideo: { dir, size: viewport },
    });
    const page = await context.newPage();
    try {
      await page.goto(url("beside-chat", scheme), { waitUntil: "domcontentloaded" });
      await ready(page);
      // A drawn pointer: headless video shows none.
      await page.addStyleTag({
        content:
          "#cu-rec-pointer{position:fixed;z-index:2147483647;width:18px;height:18px;margin:-9px 0 0 -9px;border-radius:50%;" +
          "background:rgba(255,255,255,.85);border:2px solid #0a84ff;pointer-events:none;transition:transform .08s}" +
          "#cu-rec-pointer[data-down]{transform:scale(.7);background:#0a84ff}",
      });
      await page.evaluate(() => {
        const dot = document.createElement("div");
        dot.id = "cu-rec-pointer";
        dot.style.left = "-40px";
        document.body.append(dot);
        addEventListener("pointermove", (e) => { dot.style.left = `${e.clientX}px`; dot.style.top = `${e.clientY}px`; }, true);
        addEventListener("pointerdown", () => dot.setAttribute("data-down", ""), true);
        addEventListener("pointerup", () => dot.removeAttribute("data-down"), true);
      });
      const card = () => page.getByRole("button", { name: "Calculator, live" });
      const center = async (locator) => {
        const box = await locator.boundingBox();
        return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
      };
      {
        const c = await center(card());
        const f = await center(page.getByRole("button", { name: "Full Size" }));
        console.log(JSON.stringify({ diag: scheme, cardAt: c, underCard: await under(page, c.x, c.y), underFull: await under(page, f.x, f.y) }));
        const trial = await page.getByRole("button", { name: "Full Size" }).click({ trial: true, timeout: 3000 }).then(() => "ok", (e) => String(e).slice(0, 600));
        console.log(JSON.stringify({ diag: scheme, fullSizeTrial: trial }));
        const events = await page.evaluate(() => { window.__ev = []; for (const t of ["pointerdown","pointerup","click"]) addEventListener(t, (e) => window.__ev.push(`${t}:${e.target.className}`), true); return true; });
        void events;
      }
      const glide = async (to, steps = 25) => page.mouse.move(to.x, to.y, { steps });
      const press = async (locator) => {
        await glide(await center(locator));
        await wait(page, 250);
        await page.mouse.down();
        await wait(page, 90);
        await page.mouse.up();
      };
      await page.mouse.move(viewport.width / 2, viewport.height / 2);
      await wait(page, 900);
      // Drag to the bottom left.
      await glide(await center(card()));
      await wait(page, 300);
      await page.mouse.down();
      await glide({ x: 140, y: viewport.height - 160 }, 45);
      await page.mouse.up();
      await wait(page, 1200);
      console.log(JSON.stringify({ diag: scheme, afterDrag: await page.evaluate(() => ({ ev: window.__ev.slice(0, 8), placed: document.querySelector(".acpmux-cu-preview")?.getAttribute("style"), attrs: [...(document.querySelector(".acpmux-cu-preview")?.attributes ?? [])].map((a) => a.name) })) }));
      // A click that does not move: it enlarges; another shrinks it.
      await press(card());
      await wait(page, 1200);
      await press(card());
      await wait(page, 1000);
      // Full Size, then back.
      await glide(await center(card()));
      await wait(page, 300);
      await press(page.getByRole("button", { name: "Full Size" }));
      await wait(page, 1500);
      await press(page.getByRole("button", { name: "Exit Full Size" }));
      await wait(page, 1200);
      // Hide to the chip, then show again.
      await glide(await center(card()));
      await wait(page, 300);
      await press(page.getByRole("button", { name: "Hide Preview" }));
      await wait(page, 1500);
      await press(page.getByRole("button", { name: "Show Preview" }));
      await wait(page, 1300);
      // Drag back to the top right.
      await glide(await center(card()));
      await wait(page, 300);
      await page.mouse.down();
      await glide({ x: viewport.width - 120, y: 120 }, 45);
      await page.mouse.up();
      await wait(page, 1500);
      console.log(JSON.stringify({ video: scheme, ok: true }));
    } catch (error) {
      failures += 1;
      console.log(JSON.stringify({ video: scheme, error: String(error).slice(0, 400) }));
      await page.screenshot({ path: path.join(out, `video-${scheme}-failed.png`) }).catch(() => {});
    }
    const video = page.video();
    await context.close();
    if (video) {
      const file = path.join(out, `flow-${scheme}.webm`);
      await video.saveAs(file).catch((e) => console.log(JSON.stringify({ saveAs: String(e) })));
      console.log(JSON.stringify({ videoFile: path.relative(out, file) }));
    }
  }
} finally {
  await browser.close();
  await server.close();
}
for (const scheme of ["dark", "light"]) {
  const webm = path.join(out, `flow-${scheme}.webm`);
  if (!fs.existsSync(webm)) continue;
  const mp4 = path.join(out, `flow-${scheme}.mp4`);
  const ff = spawn("ffmpeg", ["-y", "-loglevel", "error", "-i", webm, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30", mp4], { stdio: "inherit" });
  await new Promise((resolve) => { ff.once("error", (e) => { console.log(JSON.stringify({ ffmpeg: String(e) })); resolve(); }); ff.once("exit", resolve); });
}
console.log(JSON.stringify({ failures }));
process.exit(failures ? 1 : 0);
