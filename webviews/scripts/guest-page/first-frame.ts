// l10n-allow-file: harness output labels, not shipped UI.
// The guest page's load, measured the way a guest meets it (design/chat-multiplayer.md section 3;
// Leo, 2026-11-07: "the whole, like, loading thing, I think it could probably be faster ... That was
// the only thing that was seen for a while and then it got repositioned"). It serves a built page
// (scripts/cmux-next/build-guest-page-web.sh --out DIR) as the room does, under /g/ and /i/, with a
// mock room on the guest socket that answers after a set delay, and opens it in Chromium as a phone
// on a throttled network and CPU, as a guest who already joined (an invitee who may talk, so the
// composer shows).
//
//   bun scripts/guest-page/first-frame.ts --dir DIR [--runs 7] [--room-delay 300] [--out FILE.json]
//
// It reports, as the median of the runs (milliseconds from navigation start unless named):
//   fcp          the first contentful paint
//   dock         when the composer's dock first is in the page
//   transcript   when the first transcript row is in the page
//   dockMove     how far the dock's top moved between its first frame and the live chat (px)
//   cls          the page's cumulative layout shift
//   jsKB, cssKB  the compressed bytes of script and style the page loaded before the transcript
//   blockingCssKB  the compressed bytes of style that held the first paint (render-blocking)
import { gzipSync } from "bun";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { joinFrames, workingRecords } from "../../src/agent-session/guest/fixtures/liveChat";

const SHARE = "c2hhcmUtcGVyZmhhcm5lc3M";
const GUEST = "g1";

type Options = { dir: string; runs: number; roomDelay: number; out?: string; cpu: number };

function parse(argv: string[]): Options {
  const options: Options = { dir: "", runs: 7, roomDelay: 300, cpu: 4 };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index + 1];
    if (argv[index] === "--dir") options.dir = path.resolve(value);
    else if (argv[index] === "--runs") options.runs = Number(value);
    else if (argv[index] === "--room-delay") options.roomDelay = Number(value);
    else if (argv[index] === "--cpu") options.cpu = Number(value);
    else if (argv[index] === "--out") options.out = path.resolve(value);
    else throw new Error(`unknown argument ${argv[index]}`);
    index += 1;
  }
  if (!options.dir || !existsSync(path.join(options.dir, "index.html"))) throw new Error("--dir names no built page");
  return options;
}

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".woff2": "font/woff2",
  ".svg": "image/svg+xml",
  ".wasm": "application/wasm",
};

/** The room's routes for the page: index.html at /g/<id> and /i/<id>, its files under /g/. */
function serve(options: Options) {
  const cache = new Map<string, ArrayBuffer>();
  const body = (file: string) => {
    let bytes = cache.get(file);
    if (!bytes) cache.set(file, (bytes = gzipSync(readFileSync(file)).slice().buffer));
    return bytes;
  };
  const snapshot = joinFrames(workingRecords());
  return Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request, server) {
      const { pathname } = new URL(request.url);
      if (pathname === `/v1/chat-shares/${SHARE}/guest`) {
        return server.upgrade(request) ? undefined : new Response("upgrade", { status: 400 });
      }
      const relative =
        /^\/[gi]\/[^/]+\/?$/.test(pathname) && !pathname.startsWith("/g/assets")
          ? "index.html"
          : pathname.startsWith("/g/")
            ? pathname.slice(3)
            : undefined;
      const file = relative && path.resolve(options.dir, relative);
      if (!file || !file.startsWith(options.dir) || !existsSync(file))
        return new Response("Not found", { status: 404 });
      return new Response(body(file), {
        headers: {
          "content-type": TYPES[path.extname(file)] ?? "application/octet-stream",
          "content-encoding": "gzip",
          "cache-control": "no-store",
        },
      });
    },
    websocket: {
      open(socket) {
        // Presence at once, the snapshot after the room's round trip to the owner's daemon.
        socket.send(JSON.stringify(snapshot[0]));
        setTimeout(() => socket.send(JSON.stringify(snapshot[1])), options.roomDelay);
      },
      message() {},
    },
  });
}

/** Installed before the page runs: the joined guest, and the observers that time the page. */
function observe({ share, guest }: { share: string; guest: string }) {
  sessionStorage.setItem(`cmux.guest.${share}.joined`, guest);
  sessionStorage.setItem(`cmux.guest.${share}.via`, "invite");
  sessionStorage.setItem(`cmux.guest.${share}.role`, "talk");
  const marks: Record<string, number> = { cls: 0 };
  (window as unknown as { __guestMarks: typeof marks }).__guestMarks = marks;
  new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) {
      if (entry.name === "first-contentful-paint") marks.fcp = entry.startTime;
    }
  }).observe({ type: "paint", buffered: true });
  new PerformanceObserver((list) => {
    for (const entry of list.getEntries() as unknown as { value: number; hadRecentInput: boolean }[]) {
      if (!entry.hadRecentInput) marks.cls += entry.value;
    }
  }).observe({ type: "layout-shift", buffered: true });
  const look = () => {
    const dock = document.querySelector(".guest-live__dock");
    if (dock && marks.dock === undefined) {
      marks.dock = performance.now();
      // Where it is drawn on the frame that first shows it.
      requestAnimationFrame(() => (marks.dockTop = dock.getBoundingClientRect().top));
    }
    if (
      marks.transcript === undefined &&
      document.querySelector(".guest-live__transcript [data-row-id], .guest-live__transcript [data-index]")
    ) {
      marks.transcript = performance.now();
      requestAnimationFrame(() => {
        marks.dockTopLive = document.querySelector(".guest-live__dock")?.getBoundingClientRect().top ?? -1;
        marks.scriptBytes = 0;
        marks.styleBytes = 0;
        marks.blockingStyleBytes = 0;
        const entries = performance.getEntriesByType("resource") as (PerformanceResourceTiming & {
          renderBlockingStatus?: string;
        })[];
        for (const entry of entries) {
          if (/\.js(\?|$)/.test(entry.name)) marks.scriptBytes += entry.encodedBodySize;
          if (/\.css(\?|$)/.test(entry.name)) {
            marks.styleBytes += entry.encodedBodySize;
            if (entry.renderBlockingStatus === "blocking") marks.blockingStyleBytes += entry.encodedBodySize;
          }
        }
      });
    }
  };
  new MutationObserver(look).observe(document, { childList: true, subtree: true });
}

const median = (values: number[]) => {
  const sorted = values.filter((value) => Number.isFinite(value)).sort((a, b) => a - b);
  return sorted.length ? sorted[Math.floor(sorted.length / 2)] : Number.NaN;
};

async function main() {
  const options = parse(process.argv.slice(2));
  const server = serve(options);
  const origin = `http://127.0.0.1:${server.port}`;
  const browser = await chromium.launch({ headless: true });
  const runs: Record<string, number>[] = [];
  try {
    for (let run = 0; run < options.runs; run += 1) {
      const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
      const page = await context.newPage();
      const cdp = await context.newCDPSession(page);
      await cdp.send("Network.enable");
      // A good phone connection: 40 ms each way, 20 Mbit/s down.
      await cdp.send("Network.emulateNetworkConditions", {
        offline: false,
        latency: 40,
        downloadThroughput: (20 * 1024 * 1024) / 8,
        uploadThroughput: (5 * 1024 * 1024) / 8,
      });
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: options.cpu });
      await page.addInitScript(observe, { share: SHARE, guest: GUEST });
      await page.goto(`${origin}/i/${SHARE}`, { waitUntil: "commit" });
      await page.waitForFunction(
        () =>
          (window as unknown as { __guestMarks?: { dockTopLive?: number } }).__guestMarks?.dockTopLive !== undefined,
        undefined,
        { timeout: 60_000 },
      );
      // A second after the transcript, for any late move.
      await page.waitForTimeout(1_000);
      const marks = await page.evaluate(() => {
        const marks = (window as unknown as { __guestMarks: Record<string, number> }).__guestMarks;
        return {
          ...marks,
          dockTopFinal: document.querySelector(".guest-live__dock")?.getBoundingClientRect().top ?? -1,
        };
      });
      runs.push(marks);
      await context.close();
    }
  } finally {
    await browser.close();
    void server.stop(true);
  }
  const pick = (name: string) => median(runs.map((run) => run[name]));
  const result = {
    runs: runs.length,
    roomDelayMs: options.roomDelay,
    cpuThrottle: options.cpu,
    fcp: pick("fcp"),
    dock: pick("dock"),
    transcript: pick("transcript"),
    dockMove: median(
      runs.map((run) => Math.max(Math.abs(run.dockTopFinal - run.dockTop), Math.abs(run.dockTopLive - run.dockTop))),
    ),
    cls: pick("cls"),
    jsKB: Math.round(pick("scriptBytes") / 1024),
    cssKB: Math.round(pick("styleBytes") / 1024),
    blockingCssKB: Math.round(pick("blockingStyleBytes") / 1024),
    raw: runs,
  };
  const text = JSON.stringify(result, null, 2);
  if (options.out) writeFileSync(options.out, text);
  console.log(text);
}

await main();
