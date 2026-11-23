// Scratch probe (not committed): the agent chat composer's geometry while a draft grows and an
// attachment comes and goes, with screenshots and a video, for before/after evidence.
// bun scripts/probe-composer-geometry.ts OUT_DIR
import path from "node:path";
import fs from "node:fs";
import { chromium, type Page } from "playwright";
import { createServer } from "vite";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

const out = path.resolve(process.argv[2] ?? "probe-out");
fs.mkdirSync(out, { recursive: true });
const webviews = path.resolve(import.meta.dir, "..");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
  logLevel: "error",
});
await vite.listen();
const { port } = vite.httpServer!.address() as { port: number };
const browser = await chromium.launch({ headless: true });
const report: Record<string, unknown> = {};

const WORDS =
  "several problems here. STILL, the buttons for send attach all that stuff dont follow or simply stick with the bottom of the composer. plus, the caret gets shot down past the composer as it goes. ";

async function open(scheme: "dark" | "light", video?: string): Promise<Page> {
  const context = await browser.newContext({
    viewport: { width: 620, height: 640 },
    deviceScaleFactor: 2,
    colorScheme: scheme,
    ...(video ? { recordVideo: { dir: video, size: { width: 620, height: 640 } } } : {}),
  });
  const page = await context.newPage();
  await page.addInitScript(() => {
    Object.assign(window, {
      webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
      cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
    });
    (window as any).__shifts = [];
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as any[])
        (window as any).__shifts.push({ value: entry.value, t: entry.startTime });
    }).observe({ type: "layout-shift", buffered: true });
  });
  await page.goto(`http://127.0.0.1:${port}/`);
  await page.locator(".acpmux-composer-prompt").waitFor();
  await page.locator(COMPOSER_EDITOR).click();
  return page;
}

const measure = (page: Page) =>
  page.evaluate(() => {
    const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
    const field = document.querySelector<HTMLElement>(".acpmux-composer-box .acpmux-md-field")!;
    const f = field.getBoundingClientRect();
    const cs = getComputedStyle(field);
    const plus = document.querySelector(".acpmux-composer-plus")?.getBoundingClientRect();
    const actions = document.querySelector(".acpmux-composer-actions")?.getBoundingClientRect();
    const sel = getSelection();
    const caret =
      sel && sel.rangeCount
        ? (sel.getRangeAt(0).getClientRects()[0] ?? sel.getRangeAt(0).getBoundingClientRect())
        : undefined;
    const p = field.querySelector(".ProseMirror p, [contenteditable] p");
    const textLeft = p ? p.getBoundingClientRect().left : NaN;
    const textRight = p ? p.getBoundingClientRect().right : NaN;
    const visTop = f.top + parseFloat(cs.borderTopWidth);
    const visBottom = visTop + field.clientHeight;
    return {
      boxH: +box.height.toFixed(1),
      fieldH: +f.height.toFixed(1),
      fieldMax: cs.maxHeight,
      plusBottomGap: plus ? +(box.bottom - plus.bottom).toFixed(1) : null,
      plusTopGap: plus ? +(plus.top - box.top).toFixed(1) : null,
      actionsBottomGap: actions ? +(box.bottom - actions.bottom).toFixed(1) : null,
      textLeftInset: +(textLeft - box.left).toFixed(1),
      textRightInset: +(box.right - textRight).toFixed(1),
      plusLeft: plus ? +(plus.left - box.left).toFixed(1) : null,
      actionsRight: actions ? +(box.right - actions.right).toFixed(1) : null,
      caretBelowVisible: caret ? +Math.max(0, caret.bottom - visBottom).toFixed(1) : null,
      scrollTop: field.scrollTop,
      overflow: field.scrollHeight > field.clientHeight + 1,
      paneH: innerHeight,
    };
  });

// 1. Growth: per-frame sampling while typing to the cap.
for (const scheme of ["dark", "light"] as const) {
  const page = await open(scheme, scheme === "dark" ? path.join(out, "video-grow") : undefined);
  await page.screenshot({ path: path.join(out, `${scheme}-empty.png`), clip: await composerClip(page) });
  await page.evaluate(() => {
    const w = window as any;
    w.__frames = [];
    const box = document.querySelector(".acpmux-composer-box")!;
    const field = document.querySelector<HTMLElement>(".acpmux-composer-box .acpmux-md-field")!;
    const sample = () => {
      const b = box.getBoundingClientRect();
      const plus = document.querySelector(".acpmux-composer-plus")?.getBoundingClientRect();
      const actions = document.querySelector(".acpmux-composer-actions")?.getBoundingClientRect();
      const f = field.getBoundingClientRect();
      const sel = getSelection();
      const r = sel && sel.rangeCount ? sel.getRangeAt(0) : undefined;
      const c = r ? (r.getClientRects()[0] ?? r.getBoundingClientRect()) : undefined;
      const visBottom = f.top + field.clientTop + field.clientHeight;
      w.__frames.push({
        h: b.height,
        plusGap: plus ? b.bottom - plus.bottom : NaN,
        actGap: actions ? b.bottom - actions.bottom : NaN,
        caretOut: c && c.height > 0 ? Math.max(0, c.bottom - visBottom, f.top + field.clientTop - c.top) : 0,
      });
      requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
  });
  const steps: unknown[] = [];
  let lines = 0;
  for (let i = 0; i < 9; i += 1) {
    await page.keyboard.type(WORDS, { delay: 8 });
    await page.waitForTimeout(400);
    const m = await measure(page);
    steps.push(m);
    if (i === 0) await page.screenshot({ path: path.join(out, `${scheme}-wrap.png`), clip: await composerClip(page) });
    if (i === 2) await page.screenshot({ path: path.join(out, `${scheme}-grown.png`), clip: await composerClip(page) });
    lines = i;
    if ((m as any).overflow) break;
  }
  for (let i = 0; i < 4; i += 1) {
    await page.keyboard.press("Shift+Enter");
    await page.waitForTimeout(300);
  }
  steps.push(await measure(page));
  await page.screenshot({ path: path.join(out, `${scheme}-capped.png`), clip: await composerClip(page) });
  const frames = (await page.evaluate(() => (window as any).__frames)) as any[];
  const spread = (k: string) => {
    const v = frames.map((x) => x[k]).filter((x) => Number.isFinite(x));
    return +(Math.max(...v) - Math.min(...v)).toFixed(1);
  };
  report[`grow-${scheme}`] = {
    steps,
    lines,
    frames: frames.length,
    plusBottomSpread: spread("plusGap"),
    actionsBottomSpread: spread("actGap"),
    caretOutFrames: frames.filter((x) => x.caretOut > 0.5).length,
    caretOutMax: +Math.max(0, ...frames.map((x) => x.caretOut)).toFixed(1),
    shifts: await page.evaluate(() => (window as any).__shifts),
  };
  await page.context().close();
}

// 2. Attachment add/remove: layout shifts and per-frame height steps.
{
  const page = await open("dark", path.join(out, "video-attach"));
  await page.keyboard.type("why is our composer jumping ");
  await page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = 1600;
    canvas.height = 900;
    const ctx = canvas.getContext("2d")!;
    ctx.fillStyle = "#333";
    ctx.fillRect(0, 0, 1600, 900);
    const blob = await new Promise<Blob>((r) => canvas.toBlob((b) => r(b!), "image/png"));
    (window as any).__file = new File([blob], "shot.png", { type: "image/png" });
  });
  await page.evaluate(() => ((window as any).__shifts = []));
  const startFrames = () =>
    page.evaluate(() => {
      const w = window as any;
      w.__af = [];
      const box = document.querySelector(".acpmux-composer-box")!;
      const sample = () => {
        const p = document.querySelector(".acpmux-composer-box .acpmux-md-field p");
        w.__af.push({
          h: box.getBoundingClientRect().height,
          textTop: p ? p.getBoundingClientRect().top : NaN,
          boxTop: box.getBoundingClientRect().top,
        });
        if (w.__af.length < 90) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    });
  const summarize = (af: any[]) => {
    let maxStep = 0;
    let maxTextJump = 0;
    for (let i = 1; i < af.length; i += 1) {
      maxStep = Math.max(maxStep, Math.abs(af[i].h - af[i - 1].h));
      const textMove = af[i].textTop - af[i - 1].textTop;
      const edgeMove = af[i].boxTop - af[i - 1].boxTop;
      maxTextJump = Math.max(maxTextJump, Math.abs(textMove - edgeMove), Math.abs(textMove));
    }
    const total = Math.abs(af[af.length - 1].h - af[0].h);
    return {
      totalHeightChange: +total.toFixed(1),
      maxFrameStep: +maxStep.toFixed(1),
      maxTextMovePerFrame: +maxTextJump.toFixed(1),
    };
  };
  await startFrames();
  await page.evaluate((prompt) => {
    const data = new DataTransfer();
    data.items.add((window as any).__file);
    const field = document.querySelector(prompt)!;
    const ev = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
    if (ev.clipboardData !== data) Object.defineProperty(ev, "clipboardData", { value: data });
    field.dispatchEvent(ev);
  }, COMPOSER_EDITOR);
  await page.waitForTimeout(1600);
  const add = summarize(await page.evaluate(() => (window as any).__af));
  const addShifts = await page.evaluate(() => (window as any).__shifts.splice(0));
  await page.screenshot({ path: path.join(out, `dark-attached.png`), clip: await composerClip(page) });
  await startFrames();
  // Remove: Backspace over the inline chip (the caret sits after it).
  await page.keyboard.press("Backspace");
  await page.waitForTimeout(1600);
  const remove = summarize(await page.evaluate(() => (window as any).__af));
  const removeShifts = await page.evaluate(() => (window as any).__shifts.splice(0));
  report.attach = {
    add,
    addShifts: { count: addShifts.length, sum: +addShifts.reduce((s: number, x: any) => s + x.value, 0).toFixed(4) },
    remove,
    removeShifts: {
      count: removeShifts.length,
      sum: +removeShifts.reduce((s: number, x: any) => s + x.value, 0).toFixed(4),
    },
  };
  await page.context().close();
}

async function composerClip(page: Page) {
  const r = await page.locator(".acpmux-composer-box").boundingBox();
  const pad = 24;
  const top = Math.max(0, r!.y - pad);
  return {
    x: Math.max(0, r!.x - pad),
    y: top,
    width: Math.min(620, r!.width + pad * 2),
    height: Math.min(640 - top, r!.height + pad * 2 + 40),
  };
}

fs.writeFileSync(path.join(out, "report.json"), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, (k, v) => (k === "steps" ? undefined : v), 2));
await browser.close();
await vite.close();
