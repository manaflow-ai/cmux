// l10n-allow-file: bench fixture replies, not shipped UI.
// How long a host-glass surface (ui/glass/hostGlass.ts) shows the App's EMPTY glass when it opens, and
// how long its glass LINGERS after its content went, in the real pane (a production build of its dev
// entry and a stand-in acpmux, as link-card-appear.bench.ts) on Chromium in a see-through page. Leo,
// 2026-11-09: "this glass stuff is unaceptably slow to load. it loads the placeholder, THEN the
// content... every single time" (an issue link's hover card ~530 ms, the model picker ~260 ms).
//   bun bench/glass-surface-appear.bench.ts [rounds=3]
// The App is a stub of the page host's `cmux.agent.pane.glass` op: it stamps every report as it arrives
// (the App draws its glass then) and answers ANSWER_MS (default 4) later on a timer, as the App's reply
// is a task the page runs. BUSY_MS (default 0: only the pane's own work) makes the page busy after a
// marked surface mounts, as Leo's machine is: the frame after the mount queues a BUSY_MS task.
// Per surface: glassAt is the first report that carries it at an opacity above 0 (glass on screen);
// contentAt the first animation frame in which it shows (computed filter without opacity(0), computed
// opacity above 0). emptyGlassMs = max(0, contentAt - glassAt). On close: goneAt is the first frame in
// which it is unmounted or at opacity 0, withdrawAt the first report without it (or with it at opacity
// 0); lingerMs = max(0, withdrawAt - goneAt). Opens: HOVERS pull request links' hover cards, the
// composer's model picker (when it is a marked surface) and one menu (the first menu button showing).
// LABEL names the run in the output (the before/after of one harness).
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { PERF_ROW_MARK } from "./perfRow";

const ROUNDS = Number(process.argv[2] ?? 3);
const TURNS = Number(process.env.TURNS ?? 300);
const HOVERS = Number(process.env.HOVERS ?? 4);
const BUSY_MS = Number(process.env.BUSY_MS ?? 0);
const ANSWER_MS = Number(process.env.ANSWER_MS ?? 4);
const LABEL = process.env.LABEL ?? "build";
const HOLD_MS = Math.max(600, BUSY_MS * 2 + 300);
const webviews = path.resolve(import.meta.dir, "..");
const PROD_DIR = process.env.PROD_DIR;
const log = (...args: unknown[]) => console.error("glass-surface-appear:", ...args);

async function buildPane(): Promise<string> {
  if (PROD_DIR) return PROD_DIR;
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "glass-surface-pane-"));
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true },
    logLevel: "error",
  });
  log(`built the pane's dev entry into ${out}`);
  return out;
}

const LINKS = Array.from({ length: HOVERS }, (_, i) => `https://github.com/manaflow-ai/cmux/pull/${37150 + i}`);
const reply = [
  "Landed the fixes:",
  "",
  ...LINKS.map((link, i) => `- ${link} fixes papercut ${i + 1}, and the checks on its head are green.`),
].join("\n");
const { events, session } = papercutEvents({
  turns: TURNS,
  running: false,
  extra: [
    ["mux", "user_message", { text: "What landed?" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "agent_message_chunk",
      {
        method: "session/update",
        params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: reply } } }, // prettier-ignore
      },
    ],
    ["mux", "turn_result", { status: "completed" }],
  ],
});
const answer = (method: string): unknown => {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [session] };
    case "_acpmux/attach":
      return { session, lastSeq: events.length, events, hasMore: false };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: events.length };
    default:
      return null;
  }
};
let url = "";

type Surface = { id: string; level: string; left: number; top: number; right: number; bottom: number; opacity: number }; // prettier-ignore
/** One marked surface's life, page clock (performance.now()). */
type Life = {
  kind: string;
  mountAt: number;
  firstReportAt?: number;
  glassAt?: number;
  contentAt?: number;
  goneAt?: number;
  withdrawAt?: number;
};

/// The page's host: `cmux.agent.pane.glass` is the App's glass (stamped, answered ANSWER_MS later),
/// `cmux.agent.pr.inspect` the cached pull request the hover card draws; every other envelope goes to
/// the dev host's bridge (dev-host/host.ts). Also the probe: each marked surface's mount, its frames
/// and the reports that carry it, and the busy task BUSY_MS after a mount.
function installHost({ answerMs, busyMs }: { answerMs: number; busyMs: number }) {
  type Tracked = Life & { el: Element };
  const bench = { kind: "other", lives: [] as Tracked[], reports: 0 };
  (window as any).glassBench = bench;
  const byElement = new Map<Element, Tracked>();
  const track = (el: Element) => {
    if (byElement.has(el)) return;
    const life: Tracked = { el, kind: bench.kind, mountAt: performance.now() };
    byElement.set(el, life);
    bench.lives.push(life);
    if (busyMs > 0)
      // The work a mount sets off, after the frame that first paints it (React effects, the card's
      // own reads): the App's answer and the deadline queue behind it.
      requestAnimationFrame(() =>
        setTimeout(() => {
          const end = performance.now() + busyMs;
          while (performance.now() < end);
        }, 0),
      );
  };
  const collect = (node: Node) => {
    if (!(node instanceof Element)) return;
    if (node.matches("[data-host-glass]")) track(node);
    for (const inner of node.querySelectorAll("[data-host-glass]")) track(inner);
  };
  new MutationObserver((records) => {
    for (const record of records) for (const node of record.addedNodes) collect(node);
  }).observe(document, { childList: true, subtree: true });
  // Every frame: is each surface's content on screen?
  const frame = () => {
    const now = performance.now();
    for (const life of bench.lives) {
      if (life.goneAt !== undefined) continue;
      let visible = false;
      if (life.el.isConnected) {
        const style = getComputedStyle(life.el);
        visible = !style.filter.includes("opacity(0)") && Number.parseFloat(style.opacity) > 0;
      }
      if (visible && life.contentAt === undefined) life.contentAt = now;
      else if (!visible && life.contentAt !== undefined) life.goneAt = now;
    }
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
  // A report is measured in the task that posts it, so a surface's box in it is its box now.
  const glass = (surfaces: Surface[]) => {
    const now = performance.now();
    bench.reports += 1;
    for (const el of document.querySelectorAll("[data-host-glass]")) track(el);
    for (const life of bench.lives) {
      if (life.withdrawAt !== undefined) continue;
      let carried: Surface | undefined;
      if (life.el.isConnected) {
        const box = life.el.getBoundingClientRect();
        const level = life.el.getAttribute("data-host-glass");
        carried = surfaces.find(
          (s) =>
            s.level === level &&
            Math.abs(s.left - box.left) < 0.6 &&
            Math.abs(s.top - box.top) < 0.6 &&
            Math.abs(s.right - box.right) < 0.6 &&
            Math.abs(s.bottom - box.bottom) < 0.6,
        );
      }
      if (carried && life.firstReportAt === undefined) life.firstReportAt = now;
      const shown = !!carried && carried.opacity > 0;
      if (shown && life.glassAt === undefined) life.glassAt = now;
      else if (!shown && life.glassAt !== undefined) life.withdrawAt = now;
    }
  };
  const full = (link: string) => ({
    number: Number(link.split("/").pop()),
    title: "fix(cmux-wg): a dial waiting on a handshake resends its initiation every second",
    state: "merged",
    url: link,
    author: "teamleaderleo",
    updatedAt: new Date(Date.now() - 5 * 60_000).toISOString(),
    additions: 86,
    deletions: 0,
    changedFiles: 3,
    files: [
      { path: "cmux-wg/src/dial.rs", additions: 49, deletions: 0 },
      { path: "cmux-wg/tests/dial.rs", additions: 37, deletions: 0 },
      { path: "cmux-wg/tests/handshake.rs", additions: 0, deletions: 0 },
    ],
    labels: ["risk:normal"],
    baseRef: "feat-cmux-next",
    headRef: "lane/wg-dial-handshake-retry",
  });
  let original: { postMessage(message: unknown): unknown } | undefined;
  const wrapped = {
    postMessage(message: { t?: string; id?: number; op?: string; params?: any }) {
      if (message?.t === "call" && message.op === "cmux.agent.pane.glass") {
        glass((message.params?.surfaces ?? []) as Surface[]);
        return new Promise((resolve) => setTimeout(() => resolve({ t: "ok", id: message.id, value: {} }), answerMs));
      }
      if (message?.t === "call" && message.op === "cmux.agent.pr.inspect" && message.params?.url)
        return Promise.resolve({
          t: "ok",
          id: message.id,
          value: { pullRequest: full(message.params.url), fetchedAt: Date.now() / 1000, reading: false },
        });
      return original!.postMessage(message);
    },
  };
  const handlers: Record<string, unknown> = {};
  Object.defineProperty(handlers, "cmuxPage", {
    enumerable: true,
    configurable: true,
    get: () => (original ? wrapped : undefined),
    set: (value) => void (original = value),
  });
  (window as any).webkit = { messageHandlers: handlers };
}

async function open(browser: Browser): Promise<Page> {
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  await page.addInitScript(installHost, { answerMs: ANSWER_MS, busyMs: BUSY_MS });
  await page.addInitScript(() => document.documentElement.setAttribute("data-cmux-see-through", ""));
  const said: string[] = [];
  page.on("console", (m) => void ((m.type() === "error" || m.type() === "warning") && said.push(`${m.type()}: ${m.text()}`))); // prettier-ignore
  page.on("pageerror", (error) => said.push(`page error: ${error.message}`));
  await page.goto(url);
  try {
    await page.locator(`a.cv-chip[href="${LINKS.at(-1)}"]`).waitFor({ timeout: 180_000 });
  } catch (error) {
    log(`the chat or its links never showed\n${said.slice(0, 40).join("\n")}`);
    throw error;
  }
  await page.evaluate(() => document.documentElement.setAttribute("data-cmux-see-through", ""));
  await page.waitForTimeout(1500);
  return page;
}

const setKind = (page: Page, kind: string) => page.evaluate((k) => void ((window as any).glassBench.kind = k), kind);
const count = (page: Page, kind: string) =>
  page.evaluate((k) => (window as any).glassBench.lives.filter((l: Life) => l.kind === k).length as number, kind);
/** Waits until every surface of `kind` is gone and withdrawn (or `ms` passed). */
async function settled(page: Page, kind: string, ms = 3000) {
  await page
    .waitForFunction(
      (k) =>
        (window as any).glassBench.lives
          .filter((l: Life & { el: Element }) => l.kind === k)
          .every((l: Life & { el: Element }) => !l.el.isConnected && (l.glassAt === undefined || l.withdrawAt !== undefined)), // prettier-ignore
      kind,
      { timeout: ms },
    )
    .catch(() => log(`${kind}: a surface was still up or not withdrawn after ${ms} ms`));
  await page.waitForTimeout(250);
}
/** Waits for a new marked surface of `kind`; false when none mounts in `ms`. */
async function mounted(page: Page, kind: string, before: number, ms = 3000) {
  return page
    .waitForFunction(
      ([k, n]) => (window as any).glassBench.lives.filter((l: Life) => l.kind === k).length > (n as number),
      [kind, before] as const,
      { timeout: ms },
    )
    .then(() => true)
    .catch(() => false);
}

async function runAll(page: Page): Promise<{ lives: Life[]; reports: number; notes: string[] }> {
  const notes: string[] = [];
  await setKind(page, "hovercard");
  for (const link of LINKS) {
    const chip = page.locator(`a.cv-chip[href="${link}"]`);
    await chip.scrollIntoViewIfNeeded();
    const box = (await chip.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 4 });
    await page.locator(".cv-link-preview").first().waitFor({ timeout: 5_000 });
    await page.waitForTimeout(HOLD_MS);
    await page.mouse.move(5, 5, { steps: 2 });
    await page.locator(".cv-link-preview").first().waitFor({ state: "detached", timeout: 5_000 });
    await settled(page, "hovercard");
  }
  // The composer's model picker: its chip's button.
  await setKind(page, "picker");
  const picker = page.locator(".acpmux-model .acpmux-picker-button").first();
  if ((await picker.count()) > 0 && (await picker.isVisible())) {
    const before = await count(page, "picker");
    await picker.click();
    if (await mounted(page, "picker", before)) {
      await page.waitForTimeout(HOLD_MS);
      await page.keyboard.press("Escape");
      await settled(page, "picker");
    } else {
      notes.push("picker: the model chip opened no data-host-glass surface");
      await page.keyboard.press("Escape");
      await page.waitForTimeout(300);
    }
  } else notes.push("picker: no visible .acpmux-model .acpmux-picker-button");
  // One menu: the first menu button showing.
  await setKind(page, "menu");
  const menuButton = page.locator('button[aria-haspopup="menu"]:visible').first();
  if ((await menuButton.count()) > 0) {
    const name = await menuButton.evaluate((b) => b.getAttribute("data-menu") ?? b.getAttribute("aria-label") ?? b.className); // prettier-ignore
    const before = await count(page, "menu");
    await menuButton.click();
    if (await mounted(page, "menu", before)) {
      notes.push(`menu: ${name}`);
      await page.waitForTimeout(HOLD_MS);
      await page.keyboard.press("Escape");
      await settled(page, "menu");
    } else {
      notes.push(`menu: ${name} opened no data-host-glass surface`);
      await page.keyboard.press("Escape");
      await page.waitForTimeout(300);
    }
  } else notes.push("menu: no visible menu button");
  const result = await page.evaluate(() => {
    const bench = (window as any).glassBench;
    return {
      reports: bench.reports as number,
      lives: (bench.lives as (Life & { el?: Element })[]).map(({ el: _el, ...life }) => life),
    };
  });
  return { ...result, notes };
}

const pct = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))] ?? Number.NaN;
};

const lives: Life[] = [];
const notes = new Set<string>();
let reports = 0;
const releases: Array<[string, () => unknown]> = [];
try {
  const daemon = Bun.serve({
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
  releases.push(["stand-in acpmux", () => daemon.stop(true)]);
  const prodDir = await buildPane();
  if (!PROD_DIR) releases.push(["pane build", () => fs.rmSync(prodDir, { recursive: true, force: true })]);
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(prodDir, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(["static server", () => statics.stop(true)]);
  url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`;
  const browser = await chromium.launch({
    ...(process.env.CMUX_CHROME_HEADLESS_SHELL
      ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
      : { channel: "chrome" }),
    headless: true,
  });
  releases.push(["browser", () => browser.close()]);
  for (let round = 0; round < ROUNDS; round++) {
    const page = await open(browser);
    const run = await runAll(page);
    if (process.env.DEBUG) log(JSON.stringify(run));
    lives.push(...run.lives);
    reports += run.reports;
    for (const note of run.notes) notes.add(note);
    await page.close();
  }
} finally {
  for (const [name, release] of releases.reverse()) {
    try {
      await release();
    } catch (error) {
      log(`could not release the ${name}:`, error);
    }
  }
}

if (reports === 0) log("the App stub got no pane.glass report: host glass never applied in this page");
for (const note of notes) log(note);
const kinds = [...new Set(lives.map((l) => l.kind))];
const summary: Record<string, Record<string, number>> = {};
const fmt = (n: number) => (Number.isFinite(n) ? n.toFixed(1) : "-").padStart(8);
console.log(`label=${LABEL} busy=${BUSY_MS}ms answer=${ANSWER_MS}ms rounds=${ROUNDS} reports=${reports}`);
console.log("label   busy  kind        n  glass  empty p50  empty max  linger p50 linger max  firstReport->glass p50");
for (const kind of kinds) {
  const of = lives.filter((l) => l.kind === kind);
  const empty = of.filter((l) => l.glassAt !== undefined && l.contentAt !== undefined).map((l) => Math.max(0, l.contentAt! - l.glassAt!)); // prettier-ignore
  const linger = of.filter((l) => l.goneAt !== undefined && l.withdrawAt !== undefined).map((l) => Math.max(0, l.withdrawAt! - l.goneAt!)); // prettier-ignore
  const toGlass = of.filter((l) => l.glassAt !== undefined && l.firstReportAt !== undefined).map((l) => l.glassAt! - l.firstReportAt!); // prettier-ignore
  const row = {
    n: of.length,
    glassed: of.filter((l) => l.glassAt !== undefined).length,
    emptyP50: pct(empty, 50),
    emptyMax: empty.length ? Math.max(...empty) : Number.NaN,
    lingerP50: pct(linger, 50),
    lingerMax: linger.length ? Math.max(...linger) : Number.NaN,
  };
  summary[kind] = row;
  console.log(
    `${LABEL.padEnd(7)} ${String(BUSY_MS).padStart(4)}  ${kind.padEnd(10)} ${String(row.n).padStart(2)} ${String(row.glassed).padStart(6)} ${fmt(row.emptyP50)}   ${fmt(row.emptyMax)}   ${fmt(row.lingerP50)}   ${fmt(row.lingerMax)}   ${fmt(pct(toGlass, 50))}`, // prettier-ignore
  );
  if (Number.isFinite(row.emptyP50))
    console.log(`${PERF_ROW_MARK}${JSON.stringify({ name: `glass_surface_appear.${kind}.empty_glass`, p50: row.emptyP50, p95: pct(empty, 95), unit: "ms" })}`); // prettier-ignore
}
console.log(`GLASSBENCH ${JSON.stringify({ label: LABEL, busyMs: BUSY_MS, answerMs: ANSWER_MS, rounds: ROUNDS, reports, notes: [...notes], kinds: summary })}`); // prettier-ignore
