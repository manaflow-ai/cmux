// l10n-allow-file: bench output, not shipped UI.
// Screenshots of every state the transcript's rules converted from `:has()` to marks style (a sent
// prompt, a waiting steer with and without its bubble, a pending prompt in each pending look, the
// composer's tray tab, an edit diff with block-hover code actions: at rest, hovered, a tooltip, the
// context menu and a popup open and closed), from gallery stages on the dev server, as PNGs in DIR;
// `compare` counts the pixels that differ between two such dirs, shot by shot. CONTROL=1 strips the
// marks before each shot, to show the shots see them.
//   bun bench/hasMarkShots.ts DIR
//   bun bench/hasMarkShots.ts compare DIR_A DIR_B
/// <reference types="bun" />
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { galleryFrame, warmGalleryFrame } from "../test/support/galleryFrame";

if (process.argv[2] === "compare") {
  const [a, b] = process.argv.slice(3);
  type Png = { width: number; height: number; data: Buffer };
  const { PNG } = (await import("pngjs" as string)) as { PNG: { sync: { read(data: Buffer): Png } } };
  const pixelmatch = ((await import("pixelmatch" as string)) as { default: (...args: unknown[]) => number }).default;
  let differing = 0;
  let files = 0;
  for (const name of readdirSync(a!).sort()) {
    if (!name.endsWith(".png")) continue;
    files += 1;
    const one = PNG.sync.read(readFileSync(`${a}/${name}`));
    const two = PNG.sync.read(readFileSync(`${b}/${name}`));
    const diff =
      one.width === two.width && one.height === two.height
        ? pixelmatch(one.data, two.data, undefined, one.width, one.height, { threshold: 0 })
        : -1;
    if (diff !== 0) differing += 1;
    console.log(`SHOT-DIFF ${name} ${diff}`);
  }
  console.log(`SHOT-DIFF-SUMMARY ${files} shots, ${differing} differ`);
  process.exit(differing === 0 ? 0 : 1);
}
const dir = process.argv[2]!;
mkdirSync(dir, { recursive: true });
const webviews = path.resolve(import.meta.dir, "..");
const { createServer } = await import("vite");
const vite = await createServer({
  root: webviews,
  configFile: path.join(webviews, "vite.config.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const { port } = vite.httpServer!.address() as { port: number };
const base = `http://127.0.0.1:${port}`;
const browser = await chromium.launch({ headless: true });

type Step = [name: string, run: (page: Page) => Promise<unknown>];
type Scene = { entry: string; variant: string; doc?: Record<string, string>; steps: Step[] };

const away = async (page: Page) => page.mouse.move(1, 1);
const hoverText = (text: string) => async (page: Page) => {
  await away(page);
  await page.getByText(text, { exact: true }).first().hover();
};
const hoverSel = (selector: string) => async (page: Page) => {
  await away(page);
  // The first point of the element's box that hits it (the tray's tab sits partly under the composer).
  const point = await page.evaluate((selector) => {
    const el = document.querySelector(selector)!;
    const box = el.getBoundingClientRect();
    for (let y = box.top + 1; y < box.bottom; y += 1)
      for (let x = box.left + box.width / 2; x < box.right; x += 2) {
        const hit = document.elementFromPoint(x, y);
        if (hit && (hit === el || el.contains(hit))) return { x, y };
      }
    return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
  }, selector);
  await page.mouse.move(point.x, point.y);
};
/// An opener's popup open, as ui/popupWithin.ts marks it: the opener `data-popup-open`, its ancestors
/// `data-popup-within` (both sides get the same DOM; base styles it through :has(), head through the mark).
const popupOn = (selector: string) => async (page: Page) =>
  page.evaluate((selector) => {
    const opener = document.querySelector(selector);
    if (!opener) throw new Error(`no ${selector}`);
    opener.setAttribute("data-popup-open", "");
    for (let node = opener.parentElement; node; node = node.parentElement) {
      node.setAttribute("data-popup-within", "");
      if (node.matches(".acpmux-row")) break;
    }
  }, selector);
const popupOff = async (page: Page) =>
  page.evaluate(() => {
    for (const node of document.querySelectorAll("[data-popup-open]")) node.removeAttribute("data-popup-open");
    for (const node of document.querySelectorAll("[data-popup-within]")) node.removeAttribute("data-popup-within");
  });
const tooltip = (selector: string) => async (page: Page) => {
  await away(page);
  await page.locator(selector).first().hover();
  await page.waitForTimeout(1500);
};
const contextMenu = (text: string) => async (page: Page) => {
  await away(page);
  await page.getByText(text, { exact: true }).first().click({ button: "right" });
  await page.waitForTimeout(300);
};
const escape = async (page: Page) => {
  await page.keyboard.press("Escape");
  await away(page);
};
/// A waiting steer with no bubble (a prompt of images alone), for the stylesheet: its bubble taken out.
const dropBubble = (text: string) => async (page: Page) =>
  page.evaluate((text) => {
    const bubble = [...document.querySelectorAll(".cv-user__bubble")].find((b) => b.textContent?.includes(text));
    if (!bubble) throw new Error("no bubble");
    bubble.remove();
  }, text);

const STEER = "Use the cache directory for the next run";
const userRow = [
  ["rest", away],
  ["hover-sent", hoverText("Check the cache")],
  ["hover-steer", hoverText(STEER)],
  ["hover-reply", hoverText("Checking the cache.")],
  ["tooltip-copy", tooltip(".cv-user:not(:has(.cv-user__pending)) .cv-user__actions [aria-label='Copy']")],
  ["tooltip-away", away],
  ["context-sent", contextMenu("Check the cache")],
  ["context-closed", escape],
  ["popup-sent", popupOn(".cv-user:not(:has(.cv-user__pending)) .cv-user__actions button")],
  ["popup-sent-off", popupOff],
  ["popup-steer", popupOn(".cv-user__pending button")],
  ["popup-steer-off", popupOff],
  ["steer-no-bubble", dropBubble(STEER)],
  ["steer-no-bubble-hover", hoverSel(".cv-user__pending")],
] satisfies Step[];
const scenes: Scene[] = [
  { entry: "agent-pane.queued-user-footer", variant: "rest", steps: userRow },
  { entry: "agent-pane.queued-user-footer", variant: "read", steps: userRow.slice(0, 10) },
  {
    entry: "agent-pane.queued-user-footer",
    variant: "stack-rest",
    steps: [
      ["rest", away],
      ["hover-1", hoverText("Use the cache dir, not tmp")],
      ["hover-3", hoverText(STEER)],
      ["popup-1", popupOn(".cv-user__pending button")],
      ["popup-off", popupOff],
    ],
  },
  ...["prompt-pending", "prompt-pending-clock", "prompt-pending-dim"].map((variant) => ({
    entry: "agent-pane.transcript",
    variant,
    steps: [
      ["rest", away],
      ["hover-sending", hoverText("Use the cache dir, not tmp")],
      ["hover-slow", hoverText("Then open a PR")],
      ["hover-read", hoverText("Add retries to the client")],
      ["popup-pending", popupOn(".cv-user__actions--pending button")],
      ["popup-off", popupOff],
    ] satisfies Step[],
  })),
  ...["tucked-count", "tucked-waiting", "tucked-left"].map((variant) => ({
    entry: "agent-pane.subagent-tray",
    variant,
    steps: [
      ["rest", away],
      ["hover", hoverSel(".acpmux-tray-pull__tab")],
      ["popup-open", async (page: Page) => (await away(page), popupOn(".acpmux-tray-pull__hat > svg")(page))],
      ["popup-hover", hoverSel(".acpmux-tray-pull__tab")],
      ["popup-off", async (page: Page) => (await popupOff(page), away(page))],
      [
        "focus",
        async (page: Page) => (await page.keyboard.press("Shift"), page.locator(".acpmux-tray-pull__tab").focus()),
      ],
    ] satisfies Step[],
  })),
  ...[undefined, "block-hover"].map((look) => ({
    entry: "agent-pane.code-toolbar-buttons",
    variant: "diff",
    doc: look ? { "data-code-actions": look } : undefined,
    steps: [
      ["rest", away],
      ["hover", hoverSel(".cv-edit-diff")],
      ["popup-open", async (page: Page) => (await away(page), popupOn(".cv-edit-diff__header > button")(page))],
      ["popup-off", popupOff],
      ["tooltip", tooltip(".cv-edit-diff__header > button")],
    ] satisfies Step[],
  })),
];

try {
  const entries = [...new Set(scenes.map((s) => s.entry))];
  for (const entry of entries) await warmGalleryFrame(vite, entry, { browser });
  for (const scene of scenes) {
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto(`${base}${galleryFrame(scene.entry, { variant: scene.variant })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 120_000 });
    const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady);
    if (ready === "error") throw new Error(`${scene.entry}#${scene.variant}: ${await page.textContent("body")}`);
    await page.addStyleTag({
      content:
        "*, *::before, *::after { transition: none !important; animation: none !important; caret-color: transparent !important; }",
    });
    // A live turn's elapsed time ticks between runs: its words are hidden on both sides.
    await page.addStyleTag({ content: ".cv-hide-elapsed { visibility: hidden !important; }" });
    await page.evaluate(() => {
      const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (let node = walk.nextNode(); node; node = walk.nextNode())
        if (/^\s*(\d+m )?\d+s\s*$/.test(node.textContent ?? "")) node.parentElement?.classList.add("cv-hide-elapsed");
    });
    if (scene.doc)
      await page.evaluate((doc) => {
        for (const [k, v] of Object.entries(doc)) document.documentElement.setAttribute(k, v);
      }, scene.doc);
    const tag = `${scene.entry.replace("agent-pane.", "")}-${scene.variant}${scene.doc ? "-" + Object.values(scene.doc).join("-") : ""}`;
    let index = 0;
    for (const [name, run] of scene.steps) {
      await run(page);
      // CONTROL=1: the marks this change adds stripped before the shot, to show the shots see them.
      if (process.env.CONTROL === "1")
        await page.evaluate(() => {
          for (const a of ["data-steer-pending", "data-actions-pending", "data-popup-within"])
            for (const node of document.querySelectorAll(`[${a}]`)) node.removeAttribute(a);
        });
      await page.waitForTimeout(250);
      const marks = await page.evaluate(() =>
        ["data-popup-open", "data-popup-within", "data-steer-pending", "data-actions-pending"]
          .map((a) => `${a}=${document.querySelectorAll(`[${a}]`).length}`)
          .join(" "),
      );
      const file = `${tag}-${String(index++).padStart(2, "0")}-${name}.png`;
      writeFileSync(`${dir}/${file}`, await page.screenshot({ animations: "disabled" }));
      console.log(`SHOT ${file} ${marks}`);
    }
    await page.close();
  }
} finally {
  await browser.close();
  await vite.close();
}
