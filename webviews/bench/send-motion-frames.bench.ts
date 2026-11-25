// l10n-allow-file: bench fixture prompts, not shipped UI.
// What the main thread spends on each frame of a send from the latest row (the send morph,
// conversation/sendMorph.ts, and the thread's rise, followGlide.ts), in the real pane (its dev entry
// with the mock agent, as agent-pane-send-morph.test.ts) on Chromium. Leo, 2026-11-11 (ask-17cca003dd):
// "It's still okay, if only it's fast. But it's not fast. It doesn't move at 120 hertz." A frame at
// 120 Hz has 8.33 ms; main-thread work over that in a frame of the motion is a frame the motion misses.
//   bun bench/send-motion-frames.bench.ts [rounds=8]
// CPU=N (default 4) slows the page's CPU N times (CDP Emulation.setCPUThrottlingRate), as a loaded
// machine is. LABEL names the run (the before/after of one harness).
// Per round: a screenshot is pasted and a line typed, Enter sends it, and a trace of the renderer's
// main thread covers the send motion (MOTION_SEND_MS plus 120 ms). Reported, summed per round, then the
// median over rounds: layoutMs (Layout), styleMs (UpdateLayoutTree), paintMs (Paint and PrePaint),
// frameCbMs (FireAnimationFrame: the frame callbacks, the morph's own steps among them), layouts (how
// many Layout passes), and frameCbs (how many frame callbacks ran).
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import type { Page } from "playwright";
import { MOTION_SEND_MS } from "../src/motion/scale.generated";

const ROUNDS = Number(process.argv[2] ?? 8);
const CPU = Number(process.env.CPU ?? 4);
const LABEL = process.env.LABEL ?? "build";
/// MORPH=inplace sets the gallery's `data-send-morph="inplace"` on the shell: the prompt fades in place and
/// nothing flies, so the difference from the product's morph is what the morph itself costs.
const MORPH = process.env.MORPH;
const webviews = path.resolve(import.meta.dir, "..");
const field = '.acpmux-composer-prompt [contenteditable="true"]';
const log = (...args: unknown[]) => console.error("send-motion-frames:", ...args);

type TraceEvent = {
  name: string;
  ph: string;
  ts: number;
  dur?: number;
  tid: number;
  pid: number;
  args?: { name?: string };
};

// A production build of the pane's dev entry (React's production build, as the app ships), served as files.
const { build, preview } = await import("vite");
const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "send-motion-pane-"));
await build({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  build: { outDir: out, emptyOutDir: true },
  logLevel: "error",
});
const pane = await preview({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  build: { outDir: out },
  preview: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const browser = await chromium.launch({ headless: true });

async function openChat(page: Page) {
  await page.addInitScript(() => {
    Object.assign(window, {
      webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
      cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
    });
  });
  await page.goto(pane.resolvedUrls!.local[0]!);
  await page.locator(field).waitFor();
  for (const line of ["first question", "second question", "third question"]) await send(page, line);
}

async function send(page: Page, line: string) {
  await page.locator(field).click();
  await page.keyboard.type(line);
  await page.keyboard.press("Enter");
  await page.locator(".cv-user__bubble", { hasText: line }).waitFor();
  await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached", timeout: 30_000 });
}

async function paste(page: Page) {
  await page.locator(field).click();
  await page.evaluate(async (selector) => {
    const canvas = document.createElement("canvas");
    canvas.width = 1600;
    canvas.height = 1000;
    const context = canvas.getContext("2d")!;
    context.fillStyle = "#3a7bd5";
    context.fillRect(0, 0, canvas.width, canvas.height);
    const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
    const data = new DataTransfer();
    data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
    document
      .querySelector(selector)!
      .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  }, field);
  await page.waitForFunction(() => {
    const image = document.querySelector<HTMLImageElement>(".acpmux-composer .acpmux-attachment-image img");
    return !!image && image.complete && image.naturalWidth > 0;
  });
}

const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)] ?? 0;
};

const page = await browser.newPage({ viewport: { width: 900, height: 620 } });
await openChat(page);
if (MORPH)
  await page.evaluate(
    (style) => document.querySelector(".acpmux-shell")?.setAttribute("data-send-morph", style),
    MORPH,
  );
const cdp = await page.context().newCDPSession(page);
await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
const rounds: Record<string, number>[] = [];
for (let round = 0; round < ROUNDS; round++) {
  const line = `round ${round} what is this sidebar doing`;
  await paste(page);
  await page.keyboard.type(` ${line}`);
  await browser.startTracing(page, { categories: ["devtools.timeline"] });
  await page.keyboard.press("Enter");
  // The motion, from the frame the composer let the prompt go; the host's clock, unthrottled.
  await page.waitForTimeout(MOTION_SEND_MS * CPU + 120);
  const trace = JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: TraceEvent[] };
  const events = trace.traceEvents;
  const main = events.find((event) => event.name === "thread_name" && event.args?.name === "CrRendererMain");
  const onMain = events.filter((event) => main && event.pid === main.pid && event.tid === main.tid && event.ph === "X");
  const sum = (names: string[]) =>
    onMain.filter((event) => names.includes(event.name)).reduce((total, event) => total + (event.dur ?? 0) / 1000, 0);
  const count = (name: string) => onMain.filter((event) => event.name === name).length;
  rounds.push({
    layoutMs: sum(["Layout"]),
    styleMs: sum(["UpdateLayoutTree"]),
    paintMs: sum(["Paint", "PrePaint"]),
    frameCbMs: sum(["FireAnimationFrame"]),
    layouts: count("Layout"),
    frameCbs: count("FireAnimationFrame"),
  });
  await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached", timeout: 30_000 });
  await page.waitForTimeout(200);
}
const keys = Object.keys(rounds[0] ?? {});
const result = Object.fromEntries(keys.map((key) => [key, Number(median(rounds.map((r) => r[key]!)).toFixed(2))]));
log(`${LABEL} morph=${MORPH ?? "product"} cpu=${CPU}x rounds=${ROUNDS}`);
console.log(JSON.stringify({ label: LABEL, cpu: CPU, rounds: ROUNDS, median: result }));
await browser.close();
await pane.close();
fs.rmSync(out, { recursive: true, force: true });
