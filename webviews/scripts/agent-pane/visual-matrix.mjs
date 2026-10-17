#!/usr/bin/env node
// Behavior-boundary visual proof for the agent pane. This intentionally drives the real pane
// against its in-page mock daemon, so every screenshot and metric comes from the shipped React
// boundary rather than a component test.
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";
import { PNG } from "pngjs";
import { agentPaneTheme, ghosttyDefault } from "./theme.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const webviews = path.resolve(here, "../..");
const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? (process.argv[index + 1] ?? fallback) : fallback;
};
const out = path.resolve(arg("out", path.join(webviews, "../artifacts/agent-pane-visual")));
const maxFrames = Math.max(4, Number(arg("max-frames", "18")));
const only = arg("cases", "");
const selected = only ? new Set(only.split(",")) : undefined;

const fastStream = {
  steps: [
    {
      atMs: 0,
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "I’ll inspect the pane " } },
    },
    {
      atMs: 90,
      update: {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "while the daemon streams.\n\n" },
      },
    },
    {
      atMs: 180,
      update: {
        sessionUpdate: "tool_call",
        toolCallId: "stream-read",
        kind: "read",
        title: "Read agent-session",
        status: "in_progress",
      },
    },
    { atMs: 280, update: { sessionUpdate: "tool_call_update", toolCallId: "stream-read", status: "completed" } },
    {
      atMs: 380,
      update: {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "The layout stays compact as each chunk arrives." },
      },
    },
  ],
  endAtMs: 520,
};

const cases = [
  { id: "streaming-dark-narrow", state: "streaming", theme: "dark", width: 420 },
  { id: "streaming-dark-normal", state: "streaming", theme: "dark", width: 760 },
  { id: "streaming-dark-wide", state: "streaming", theme: "dark", width: 1200 },
  { id: "queue-steer-light-normal", state: "queue-steer", theme: "light", width: 760 },
  { id: "pr-chip-dark-normal", state: "pr-chip", theme: "dark", width: 760 },
  { id: "permission-dark-narrow", state: "permission", theme: "dark", width: 420 },
  { id: "permission-light-wide", state: "permission", theme: "light", width: 1200 },
  { id: "images-light-normal", state: "images", theme: "light", width: 760 },
  { id: "wallpaper-dark-wide", state: "wallpaper", theme: "dark", width: 1200 },
];

await fs.mkdir(out, { recursive: true });
const server = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  // This is a bounded capture job. Disabling Vite's file watcher keeps a full matrix from
  // exhausting Linux inotify slots when several Blacksmith workers run it together.
  server: { port: 0, strictPort: false, watch: null },
  logLevel: "error",
});
await server.listen();
const url = server.resolvedUrls.local[0];
const browser = await chromium.launch();
const results = [];

try {
  for (const item of cases) {
    if (selected && !selected.has(item.id)) continue;
    results.push(await runCase(item));
  }
} finally {
  await browser.close();
  await server.close();
}

const contact = await makeContactSheet(results);
const report = {
  schema: 1,
  generatedAt: new Date().toISOString(),
  transport: "mock-daemon",
  fastClock: true,
  cases: results,
  contactSheet: path.relative(out, contact),
  verdict: verdict(results),
};
await fs.writeFile(path.join(out, "matrix.json"), `${JSON.stringify(report, null, 2)}\n`);
await fs.writeFile(path.join(out, "verdict.md"), verdictMarkdown(report));
console.log(JSON.stringify({ out, cases: results.length, contactSheet: contact, verdict: report.verdict }));

async function runCase(item) {
  const dir = path.join(out, item.id);
  await fs.mkdir(dir, { recursive: true });
  const context = await browser.newContext({
    viewport: { width: item.width, height: 760 },
    colorScheme: item.theme,
    recordVideo: { dir },
  });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(
    ({ script }) => {
      if (script) window.cmuxAcpmuxMockScript = script;
      window.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock" }) };
    },
    { script: item.state === "streaming" ? fastStream : undefined },
  );
  await page.goto(url, { waitUntil: "networkidle" });
  await page.waitForFunction(() => window.cmuxAcpmuxBridge && window.cmuxAcpmuxActions?.["chat.send"]);
  await page.evaluate(
    (theme) => window.cmuxAcpmuxBridge.applyTheme(theme),
    agentPaneTheme(item.theme === "dark" ? ghosttyDefault : lightTheme()),
  );
  if (item.state === "pr-chip")
    await page.evaluate((state) => window.cmuxAcpmuxBridge.applyHeaderState?.(state), prState());
  await page.waitForSelector(".acpmux-shell");
  if (item.state === "permission") await select(page, "mock-tab-strip");
  if (item.state === "images") await select(page, "mock-light-theme");
  if (item.state === "pr-chip") {
    await select(page, "mock-session");
    await page.evaluate((state) => window.cmuxAcpmuxBridge.applyHeaderState?.(state), prState());
  }
  if (item.state === "wallpaper") await applyWallpaper(page);
  if (item.state === "streaming") {
    await page.evaluate(() => window.cmuxAcpmuxActions["chat.send"]({ text: "Show the streaming state." }));
  } else if (item.state === "queue-steer") {
    await page.evaluate(async () => {
      const send = window.cmuxAcpmuxActions["chat.send"];
      void send({ text: "First queued prompt" });
      await new Promise((resolve) => setTimeout(resolve, 35));
      void send({ text: "Steer this turn", steer: true });
    });
  }
  const frames = [];
  const boxes = [];
  const started = Date.now();
  for (let i = 0; i < maxFrames; i += 1) {
    await page.waitForTimeout(i === 0 ? 80 : 90);
    const name = `frame-${String(i).padStart(2, "0")}.png`;
    await page.screenshot({ path: path.join(dir, name), animations: "disabled", caret: "hide" });
    frames.push(name);
    boxes.push(await readBoxes(page));
    if (Date.now() - started > 2600) break;
  }
  const metrics = layoutMetrics(boxes, item.width, 760);
  const video = page.video();
  await context.close();
  const videoPath = video ? await video.path() : undefined;
  if (videoPath) {
    const target = path.join(dir, "fast-clock.webm");
    await fs.copyFile(videoPath, target);
    if (videoPath !== target) await fs.rm(videoPath, { force: true });
  }
  if (errors.length) throw new Error(`${item.id}: ${errors.join("; ")}`);
  const result = {
    ...item,
    frames,
    video: "fast-clock.webm",
    metrics,
    galleryPath: `/live/agent-pane-visual/${item.id}`,
  };
  await fs.writeFile(path.join(dir, "metrics.json"), `${JSON.stringify(result, null, 2)}\n`);
  return result;
}

async function select(page, sessionId) {
  await page.evaluate((id) => window.cmuxAcpmuxActions["chat.select"]({ sessionId: id }), sessionId);
  await page.waitForFunction((id) => window.cmuxAcpmuxDebug?.chatState?.().sessionId === id, sessionId);
  await page.waitForTimeout(120);
}

async function readBoxes(page) {
  return page.evaluate(() => {
    const nodes = [
      ["shell", document.querySelector(".acpmux-shell")],
      ["header", document.querySelector(".acpmux-header")],
      ["sidebar", document.querySelector(".acpmux-sidebar")],
      ["scroll", document.querySelector(".acpmux-scroll")],
      ["composer", document.querySelector(".acpmux-composer")],
      ["permission", document.querySelector(".acpmux-permission-panel")],
      ["queue", document.querySelector(".acpmux-composer-queue")],
      ...[...document.querySelectorAll(".acpmux-row")].map((node) => [node.getAttribute("data-row-id") || "row", node]),
    ];
    return nodes.flatMap(([key, node]) => {
      if (!(node instanceof HTMLElement)) return [];
      const rect = node.getBoundingClientRect();
      return [{ key, x: rect.x, y: rect.y, width: rect.width, height: rect.height }];
    });
  });
}

function layoutMetrics(frames, width, height) {
  let cls = 0;
  const jumps = [];
  for (let index = 1; index < frames.length; index += 1) {
    const previous = new Map(frames[index - 1].map((box) => [box.key, box]));
    let frameJump = 0;
    let frameScore = 0;
    for (const box of frames[index]) {
      const before = previous.get(box.key);
      if (!before) continue;
      const dx = box.x - before.x;
      const dy = box.y - before.y;
      const movement = Math.hypot(dx, dy);
      frameJump = Math.max(frameJump, movement);
      if (!movement) continue;
      const left = Math.min(before.x, box.x);
      const top = Math.min(before.y, box.y);
      const right = Math.max(before.x + before.width, box.x + box.width);
      const bottom = Math.max(before.y + before.height, box.y + box.height);
      const impact = Math.min(1, (Math.max(0, right - left) * Math.max(0, bottom - top)) / (width * height));
      const distance = Math.max(Math.abs(dx) / width, Math.abs(dy) / height);
      frameScore += impact * distance;
    }
    cls += frameScore;
    jumps.push({ frame: index, maxPx: Number(frameJump.toFixed(2)), score: Number(frameScore.toFixed(5)) });
  }
  const finalBoxes = frames.at(-1) ?? [];
  const overlaps = [];
  for (let leftIndex = 0; leftIndex < finalBoxes.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < finalBoxes.length; rightIndex += 1) {
      const left = finalBoxes[leftIndex];
      const right = finalBoxes[rightIndex];
      if (left.key === right.key || left.key === "shell" || right.key === "shell") continue;
      const overlapWidth = Math.min(left.x + left.width, right.x + right.width) - Math.max(left.x, right.x);
      const overlapHeight = Math.min(left.y + left.height, right.y + right.height) - Math.max(left.y, right.y);
      if (overlapWidth > 1 && overlapHeight > 1 && (left.key === "composer" || right.key === "composer")) {
        overlaps.push({
          left: left.key,
          right: right.key,
          width: Number(overlapWidth.toFixed(2)),
          height: Number(overlapHeight.toFixed(2)),
        });
      }
    }
  }
  return {
    frames: frames.length,
    cls: Number(cls.toFixed(5)),
    maxFrameJumpPx: Number(Math.max(0, ...jumps.map((jump) => jump.maxPx)).toFixed(2)),
    perFrameJumps: jumps,
    composerOverlaps: overlaps,
  };
}

async function makeContactSheet(results) {
  const columns = 2;
  const tileWidth = 400;
  const tileHeight = 300;
  const rows = Math.ceil(results.length / columns);
  const sheet = new PNG({ width: columns * tileWidth, height: rows * tileHeight });
  for (let index = 0; index < results.length; index += 1) {
    const result = results[index];
    const source = PNG.sync.read(await fs.readFile(path.join(out, result.id, result.frames.at(-1))));
    const width = Math.min(tileWidth, source.width);
    const height = Math.min(tileHeight, source.height);
    PNG.bitblt(
      source,
      sheet,
      0,
      0,
      width,
      height,
      (index % columns) * tileWidth,
      Math.floor(index / columns) * tileHeight,
      width,
      height,
    );
  }
  const target = path.join(out, "contact-sheet.png");
  await fs.writeFile(target, PNG.sync.write(sheet));
  return target;
}

function lightTheme() {
  return {
    ...ghosttyDefault,
    background: { r: 0.94, g: 0.94, b: 0.94, a: 1 },
    foreground: { r: 0.08, g: 0.08, b: 0.08, a: 1 },
  };
}

function prState() {
  return {
    pinned: true,
    sideTabs: false,
    lit: [],
    floatingChat: false,
    version: 1,
    pullRequest: {
      url: "https://github.com/manaflow-ai/cmux/pull/20214",
      number: 20214,
      title: "Agent pane visual verification loop",
      state: "open",
      review: "",
      mergeable: "mergeable",
      checks: { state: "passing", passed: 5, total: 5 },
      checkList: [
        { name: "web", state: "passed", url: "https://github.com/manaflow-ai/cmux/actions" },
        { name: "visual matrix", state: "pending", url: "https://github.com/manaflow-ai/cmux/actions" },
      ],
    },
  };
}

function verdict(results) {
  const maxCls = Math.max(0, ...results.map((result) => result.metrics.cls));
  const maxJump = Math.max(0, ...results.map((result) => result.metrics.maxFrameJumpPx));
  const overlapCount = results.reduce((total, result) => total + result.metrics.composerOverlaps.length, 0);
  return maxCls <= 0.25 && maxJump <= 120 && overlapCount === 0 ? "pass" : "review";
}

function verdictMarkdown(report) {
  const rows = report.cases
    .map(
      (item) =>
        `| ${item.id} | ${item.width}px | ${item.theme} | ${item.metrics.cls} | ${item.metrics.maxFrameJumpPx}px | ${item.metrics.composerOverlaps.length || "none"} | [gallery](${item.galleryPath}) |`,
    )
    .join("\n");
  return `# Agent pane visual matrix\n\nVerdict: **${report.verdict}**. The matrix uses the mock daemon at the real Playwright boundary with a fast scripted clock. Any composer overlap is a review finding for the sticky bottom stack.\n\n| Case | Width | Theme | CLS-style | Max frame jump | Composer overlaps | Gallery |\n| --- | ---: | --- | ---: | ---: | ---: | --- |\n${rows}\n\nContact sheet: [contact-sheet.png](./contact-sheet.png)\n`;
}

async function applyWallpaper(page) {
  await page.evaluate(() => {
    const style = document.createElement("style");
    style.dataset.visualMatrix = "wallpaper";
    style.textContent = `.acpmux-shell { background-image: radial-gradient(circle at 20% 15%, rgba(74, 100, 190, .42), transparent 42%), radial-gradient(circle at 85% 80%, rgba(192, 90, 136, .30), transparent 46%); background-size: cover; }`;
    document.head.append(style);
  });
}
