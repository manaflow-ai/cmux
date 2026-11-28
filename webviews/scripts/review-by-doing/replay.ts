#!/usr/bin/env bun
// Review by doing (cmuxterm-hq#23817): record what a reviewer does on a candidate's gallery stage,
// replay it on any head, and turn it into a regression test.
//
//   bun scripts/review-by-doing/replay.ts record --dist DIR --entry ID [--variant V] [--width N]
//        --gesture GESTURE.json --out RECORDING.json [--title "what is wrong"]
//   bun scripts/review-by-doing/replay.ts replay RECORDING.json --dist DIR [--head SHA]... [--repeat N]
//   bun scripts/review-by-doing/replay.ts to-test RECORDING.json --out test/review-NAME.test.ts
//
// DIR is a head's built gallery (`bun run gallery:build`, CMUX_GALLERY_ENTRIES for a subset); its
// checkout's HEAD is the head. `record` injects recorder.js and drives the gesture with the mouse
// and keyboard at the elements' real positions, the way a person's hand would, so what is kept is
// what the recorder made of real events. A gesture file is
// `{ "actions": [{ "click": LOC } | { "drag": LOC, "dx": N, "dy": N, "from"?: EDGE } | { "type": TEXT } |
// { "press": KEY }], "expect": [{ "point": LOC | "target": TARGET, "state"?, "text"?, "attr"?, "box"? }] }`, LOC a
// Playwright selector for where the hand goes. `replay` refuses a head the recording was not made on
// unless `--head` names it; it prints one JSON line with every run's verdict and time.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, type Browser, type Page } from "playwright";
import { RECORDING_SCHEMA, headRefusal, readRecording, type Expectation, type Recording } from "./recording";
import { pressPoint, replayOnPage, surfaceParams } from "./replayCore";
import type { Edge } from "./recording";

const here = path.dirname(fileURLToPath(import.meta.url));
const TYPES: Record<string, string> = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".wasm": "application/wasm",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
};

function args(argv: string[]) {
  const positional: string[] = [];
  const named = new Map<string, string[]>();
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index]!;
    if (!arg.startsWith("--")) positional.push(arg);
    else named.set(arg.slice(2), [...(named.get(arg.slice(2)) ?? []), argv[++index] ?? ""]);
  }
  return { positional, one: (name: string) => named.get(name)?.at(-1), all: (name: string) => named.get(name) ?? [] };
}

/** A static server for a built gallery (its base is "./", so any root works). */
async function serve(dist: string): Promise<{ base: string; close: () => void }> {
  const root = path.resolve(dist);
  const server = http.createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://x");
    const file = path.join(root, decodeURIComponent(url.pathname));
    if (!file.startsWith(root) || !existsSync(file) || !statSync(file).isFile()) {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { "content-type": TYPES[path.extname(file)] ?? "application/octet-stream" });
    response.end(readFileSync(file));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("no TCP port");
  return { base: `http://127.0.0.1:${address.port}`, close: () => server.close() };
}

const headOf = (dist: string) => execFileSync("git", ["-C", dist, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const frameUrl = (base: string, recording: Recording) =>
  `${base}/frame.html?${new URLSearchParams(surfaceParams(recording))}`;

async function browserPage(browser: Browser, recording: Recording): Promise<Page> {
  return browser.newPage({
    viewport: { width: recording.surface.width ?? 900, height: recording.surface.height ?? 700 },
  });
}

type Gesture = {
  actions: (
    | { click: string }
    | { drag: string; dx: number; dy: number; from?: Edge }
    | { type: string }
    | { press: string }
  )[];
  /** `point`: where the reviewer points (the recorder names it); or `target`: a claim they type. */
  expect: (Omit<Expectation, "target"> & ({ point: string } | { target: Expectation["target"] }))[];
};

async function record(options: ReturnType<typeof args>): Promise<void> {
  const dist = options.one("dist")!;
  const gesture = JSON.parse(readFileSync(options.one("gesture")!, "utf8")) as Gesture;
  const width = options.one("width");
  const draft: Recording = {
    schema: RECORDING_SCHEMA,
    title: options.one("title") ?? "",
    sha: headOf(dist),
    surface: {
      entry: options.one("entry")!,
      ...(options.one("variant") ? { variant: options.one("variant") } : {}),
      ...(width ? { width: Number(width) } : {}),
    },
    steps: [],
    expect: [],
  };
  const { base, close } = await serve(dist);
  const browser = await chromium.launch({ headless: true });
  const started = Date.now();
  try {
    const page = await browserPage(browser, draft);
    await page.addInitScript({ path: path.join(here, "recorder.js") });
    await page.goto(frameUrl(base, draft), { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    await page.evaluate(() => (window as never as { __cmuxReview: { start(): void } }).__cmuxReview.start());
    const center = async (selector: string, from?: Edge) => {
      const box = await page.locator(selector).filter({ visible: true }).first().boundingBox({ timeout: 5_000 });
      if (!box) throw new Error(`gesture: ${selector} has no box`);
      return pressPoint(box, from);
    };
    for (const action of gesture.actions) {
      if ("click" in action) {
        const { x, y } = await center(action.click);
        await page.mouse.move(x, y, { steps: 4 });
        await page.mouse.click(x, y);
      } else if ("drag" in action) {
        const { x, y } = await center(action.drag, action.from);
        await page.mouse.move(x, y, { steps: 4 });
        await page.mouse.down();
        await page.mouse.move(x + action.dx, y + action.dy, { steps: 8 });
        await page.mouse.up();
      } else if ("type" in action) await page.keyboard.type(action.type);
      else await page.keyboard.press(action.press);
      await page.waitForTimeout(250);
    }
    // The reviewer points at what is wrong: the element's description comes from the recorder.
    const pointed: Expectation[] = [];
    for (const claim of gesture.expect) {
      if ("target" in claim) {
        pointed.push(claim);
        continue;
      }
      const { point, ...rest } = claim;
      const handle = await page
        .locator(point)
        .first()
        .elementHandle({ timeout: 5_000 })
        .catch(() => null);
      const target = handle
        ? await handle.evaluate((element) =>
            (window as never as { __cmuxReview: { point(e: Element): unknown } }).__cmuxReview.point(element),
          )
        : { selector: point };
      pointed.push({ ...rest, target } as Expectation);
    }
    const steps = await page.evaluate(() =>
      (window as never as { __cmuxReview: { finish(): unknown[] } }).__cmuxReview.finish(),
    );
    const recording = readRecording({ ...draft, steps, expect: pointed });
    writeFileSync(options.one("out")!, `${JSON.stringify(recording, null, 2)}\n`);
    console.log(
      JSON.stringify({
        recorded: options.one("out"),
        sha: recording.sha,
        steps: steps.length,
        ms: Date.now() - started,
      }),
    );
  } finally {
    await browser.close();
    close();
  }
}

async function replay(options: ReturnType<typeof args>): Promise<number> {
  const recording = readRecording(JSON.parse(readFileSync(options.positional[1]!, "utf8")));
  const dist = options.one("dist")!;
  const head = headOf(dist);
  const allow = options.all("head").map((short) => (head.startsWith(short) ? head : short));
  const refusal = headRefusal(recording, head, allow);
  if (refusal) {
    console.log(JSON.stringify({ head, refused: refusal }));
    return 3;
  }
  const repeat = Number(options.one("repeat") ?? 1);
  const { base, close } = await serve(dist);
  const browser = await chromium.launch({ headless: true });
  const runs = [];
  try {
    for (let run = 0; run < repeat; run++) {
      const page = await browserPage(browser, recording);
      try {
        runs.push(await replayOnPage(page, frameUrl(base, recording), recording));
      } finally {
        await page.close();
      }
    }
  } finally {
    await browser.close();
    close();
  }
  const ms = runs.map((run) => run.ms).sort((a, b) => a - b);
  const passed = runs.filter((run) => run.pass).length;
  console.log(
    JSON.stringify({
      head,
      runs: runs.length,
      passed,
      failed: runs.length - passed,
      medianMs: ms[Math.floor(ms.length / 2)],
      failures: [...new Set(runs.flatMap((run) => run.failures))],
    }),
  );
  return passed === runs.length ? 0 : 1;
}

/** A regression test that replays the recording on the dev gallery of whatever head runs it. */
function toTest(options: ReturnType<typeof args>): void {
  const source = options.positional[1]!;
  const recording = readRecording(JSON.parse(readFileSync(source, "utf8")));
  const out = options.one("out")!;
  const name = path.basename(out);
  const fromTest = (target: string) => {
    const relative = path.relative(path.dirname(out), target).split(path.sep).join("/");
    return relative.startsWith(".") ? relative : `./${relative}`;
  };
  const core = fromTest(path.join(here, "replayCore.ts")).replace(/\.ts$/, "");
  const support = fromTest(path.join(here, "../../test/support"));
  writeFileSync(
    out,
    `// Generated by scripts/review-by-doing/replay.ts to-test from a reviewer's recording on ${recording.sha.slice(0, 12)}
// (cmuxterm-hq#23817). Edit the recording and regenerate rather than this file.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { readRecording } from "${core.replace(/replayCore$/, "recording")}";
import { replayOnPage, surfaceParams } from "${core}";
import { galleryFrame, warmGalleryFrame } from "${support}/galleryFrame";
import { requireBrowserLane } from "${support}/requireBrowserLane";

await requireBrowserLane(${JSON.stringify(name)}, async () => {
  setDefaultTimeout(120_000);
  const recording = readRecording(${JSON.stringify(recording, null, 2).replace(/\n/g, "\n  ")});
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const { entry, ...params } = surfaceParams(recording);
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "${fromTest(path.join(here, "../.."))}");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  test(${JSON.stringify(recording.title || name)}, async () => {
    const page = await browser.newPage({
      viewport: { width: recording.surface.width ?? 900, height: recording.surface.height ?? 700 },
    });
    try {
      const { port } = vite.httpServer!.address() as { port: number };
      const result = await replayOnPage(page, \`http://127.0.0.1:\${port}\${galleryFrame(entry, params)}\`, recording);
      expect(result.failures).toEqual([]);
    } finally {
      await page.close();
    }
  });
});
`,
  );
  console.log(JSON.stringify({ test: out }));
}

const options = args(process.argv.slice(2));
const command = options.positional[0];
if (command === "record") await record(options);
else if (command === "replay") process.exitCode = await replay(options);
else if (command === "to-test") toTest(options);
else {
  console.error("usage: replay.ts record|replay|to-test (see the header)");
  process.exitCode = 2;
}
