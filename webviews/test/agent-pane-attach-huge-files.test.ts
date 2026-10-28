// cmux-web-test-timeout: 3000
// Leo, 2026-10-25: "are the fixes for all the composer attachment/image big size things fixed? like
// arbitarrily large file sizes the composer should never ever freeze and prevent new things from
// happening/from cancelling the thing". And: "also why dont we have previews of videos we should ...
// oh attaching a video froze the composer..." (a macOS screen recording; it never reached the agent).
//
// Each file below is attached to a chat's composer, one after another, while its upload is still
// running, and the composer must stay usable:
// - its tile shows at once, typed keys land within a frame, and the main thread never stalls;
// - the + menu opens and closes, and another message goes out without waiting for the file;
// - the tile's × takes it away, stops its upload (no chunk after it, `chat.upload.cancel` sent),
//   and the page's memory falls back; nothing ever holds a whole big file in the page's heap;
// - a screen recording reaches the agent (the prompt's blocks name it).
// Files: a 300 MB screen recording (.mov) dropped, pasted and chosen through + > Attach files, in a
// chat on this Mac (the host knows its path) and in a remote one (it streams through
// `chat.upload.*`); then a 2 GB file, a 500 MB video, a 200-megapixel PNG and a 100 MB paste of
// text, pasted and dropped in a remote chat. The big files are sparse files on disk given to the page
// as disk-backed Files (never built in page memory); the text is one string built in the page.
// The page is the pane's dev entry with the in-page mock daemon; its native host is a stand-in that
// takes uploads with a delay per chunk (CMUX_BIGTEST_CHUNK_MS, default 25), so each upload is still
// running while the test acts. A remote chat is the worked mock chat whose host does not know where
// the files are (`chat.attach.dropped` names none), as the app's host answers for a chat not on
// this Mac. Prints a table of the numbers per file.
// Then three ways a file can still go wrong (Codex review of #25191/#25192):
// - a held send: Enter pressed while a pasted recording is still being read (the host takes 1 s to
//   say where it is) never goes without the file the moment its upload starts; it waits for the
//   upload and carries its link, or the tile's × sends it without the file;
// - a pasted screenshot is its preview chip while its original still streams: that chip's × stops
//   the original's upload (no chunk after it, `chat.upload.cancel` for its token);
// - a JPEG whose APP segments run past 64 KiB before its frame header (12000 x 9000) is never
//   decoded (createImageBitmap is spied in the page and in the image worker) and goes as a file.
// The stand-in host keeps each upload's stage (begin opens it, finish or cancel closes it): no case
// may end with one open. A file still uploading when another message went finishes, and the next
// prompt carries its link.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  closeSync,
  existsSync,
  ftruncateSync,
  mkdtempSync,
  rmSync,
  openSync,
  readFileSync,
  statSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type BrowserContext, type CDPSession, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// `none`: the baseline, the composer with nothing attached.
type Way = "paste" | "drop" | "menu" | "none";
type Mode = "local" | "remote";
type BigFile = {
  name: string;
  type: string;
  size?: number;
  header?: number[];
  /// A real PNG this size, one colour with a row of noise every `noise` rows.
  png?: { width: number; height: number; noise: number };
  /// A JPEG this size whose APP segments take `app` bytes before its frame header.
  jpeg?: { width: number; height: number; app: number };
};
/// A case with steps of its own (the three ways a file still went wrong), instead of the usual ones.
type Scenario = "held-wait" | "held-x" | "staged-x" | "jpeg-app";
type Case = {
  id: string;
  file?: BigFile;
  text?: number;
  way: Way;
  mode: Mode;
  heapBudget: number;
  finish?: boolean;
  scenario?: Scenario;
  /// The stand-in host's delay per chunk for this case (CHUNK_MS otherwise).
  chunkMs?: number;
  /// How long the host takes to answer `chat.attach.dropped`.
  droppedMs?: number;
};
type Block = { type: string; name?: string; uri?: string; mimeType?: string; text?: number; data?: number };
type Row = {
  id: string;
  way: Way;
  mode: Mode;
  size: number;
  fileType?: string;
  tileMs?: number;
  keys?: { p50: number; p95: number; max: number; lost: boolean };
  stallMs?: number;
  menuMs?: number;
  cancel?: string;
  chunksAfterX?: number;
  uploadCancelSent?: boolean;
  heap?: { base: number; peak: number; after: number };
  rss?: { base: number; peak: number; after: number };
  send?: string;
  sentBlocks?: Block[];
  /// The prompt sent after the file that was uploading meanwhile finished.
  nextBlocks?: Block[];
  videoBlocks?: Block[];
  /// Upload stages the host still held open at the case's end.
  stagesLeft?: string[];
  note?: string;
  problems: string[];
};
type BigState = {
  chunkMs: number;
  counts: Record<string, number>;
  chunks: number[];
  bytes: number;
  begins: { at: number; name: string; size: number; token: string }[];
  cancels: { at: number; token: string }[];
  finishes: number;
  /// The host's open upload stages, by token: begin opens one, finish or cancel closes it.
  stages: Record<string, string>;
  /// When each upload's finish was answered, by token.
  finishedAt: Record<string, number>;
  /// Each createImageBitmap call, on the page or in the image worker, by its source's size.
  decodes: { where: string; size: number; type: string }[];
  droppedMs: number;
  sends: { at: number; text: number; attachments: { kind: string; name: string; size: number; path?: string }[] }[];
  keys: { key: string; down: number; landed?: number; settled?: number; frame?: number }[];
  recording: boolean;
  stall: number;
  heapPeak: number;
  tileAt: number;
  gestureAt: number;
  clickAt: number;
  chosenType?: string;
  sendReady: boolean;
  startBeat(): void;
  stopBeat(): void;
  watchTile(): void;
  watchKeys(): void;
};
type BigWindow = Window & {
  __big: BigState;
  __bigText?: string;
  __bigTransfer?: DataTransfer;
  cmuxGalleryLog: { method: string; params?: { prompt?: unknown }; at?: number }[];
};

await requireBrowserLane("agent-pane-attach-huge-files.test.ts", async () => {
  const MB = 1024 * 1024;
  /// How long the stand-in host takes over each 512 KiB chunk: a 300 MB upload takes about 15 s.
  const CHUNK_MS = Number(process.env.CMUX_BIGTEST_CHUNK_MS) || 25;
  /// Any one step (a gesture, the typing, a click) not done in this long: the composer froze.
  const STEP_MS = 30_000;
  /// A typed key is in the prompt, and its work done, within a frame (p95) and never far past one. The
  /// dev page's own typing (development React, nothing attached: the baseline row) is the floor: a
  /// file attaching may add at most KEY_ADDED_MS to its p95.
  const KEY_P95_MS = 16;
  const KEY_ADDED_MS = 8;
  const KEY_MAX_MS = 50;
  /// The longest the main thread may stall while a file attaches (agent-pane-paste-large-screenshots),
  /// or the baseline row's own stall (the same steps with nothing attached) and STALL_ADDED_MS.
  const MAX_STALL_MS = 120;
  const STALL_ADDED_MS = 50;
  /// The tile is there this soon after the paste, drop or choice.
  const TILE_MS = 100;
  /// The + menu is open this soon after its click (the click's own round trip included).
  const MENU_MS = 300;
  /// Another message goes out this soon after Enter while the file is still loading.
  const SEND_MS = 5_000;
  /// After the ×, the page's heap (after a GC) is back within this of where it started.
  const HEAP_BACK = 64 * MB;
  const TYPED = "hello while loading!";
  const PROMPT = ".acpmux-composer-prompt [contenteditable]";
  setDefaultTimeout(900_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-attach-huge-files: skipping (run `bunx playwright install chromium`)");
    describe.skip("attaching huge files", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  // Each run its own folder (two runs at once must not share fixtures), removed when the file ends.
  const dir = mkdtempSync(path.join(os.tmpdir(), "composer-bigtest-files-"));

  const MOV: BigFile = {
    name: "Screen Recording 2026-10-25 at 10.14.02.mov",
    type: "video/quicktime",
    size: 300 * MB,
    // An ftyp box ("qt  "), as a QuickTime file starts.
    header: [0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20, 0, 0, 0, 0, 0x71, 0x74, 0x20, 0x20],
  };
  const BIN: BigFile = { name: "capture.bin", type: "application/octet-stream", size: 2048 * MB };
  const MP4: BigFile = {
    name: "clip.mp4",
    type: "video/mp4",
    size: 500 * MB,
    header: [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d, 0, 0, 2, 0, 0x69, 0x73, 0x6f, 0x6d],
  };
  /// About 200 megapixels: 14142 x 14142.
  const PNG: BigFile = {
    name: "panorama-200mp.png",
    type: "image/png",
    png: { width: 14142, height: 14142, noise: 97 },
  };
  /// A Retina screenshot of a few megabytes that decodes: its preview is made at once.
  const SHOT: BigFile = {
    name: "Screenshot 2026-10-26 at 09.12.44.png",
    type: "image/png",
    png: { width: 1800, height: 1200, noise: 2 },
  };
  /// A phone photo whose Exif and ICC segments (72 KiB) come before its 12000 x 9000 frame header.
  const JPEG: BigFile = {
    name: "IMG_4032.jpg",
    type: "image/jpeg",
    jpeg: { width: 12000, height: 9000, app: 72 * 1024 },
  };
  const TEXT_BYTES = 100 * MB;
  const CASES: Case[] = [
    { id: "baseline: nothing attached", way: "none", mode: "remote", heapBudget: 300 * MB },
    ...(["local", "remote"] as const).flatMap((mode) =>
      (["drop", "paste", "menu"] as const).map((way): Case => ({
        id: `0 .mov 300 MB ${way} ${mode}`,
        file: MOV,
        way,
        mode,
        heapBudget: 300 * MB,
        finish: true,
      })),
    ),
    ...(
      [
        ["1 .bin 2 GB", BIN],
        ["2 .mp4 500 MB", MP4],
        ["3 .png 200 MP", PNG],
      ] as const
    ).flatMap(([id, file]) =>
      (["paste", "drop"] as const).map((way): Case => ({
        id: `${id} ${way} remote`,
        file,
        way,
        mode: "remote",
        heapBudget: 300 * MB,
      })),
    ),
    // The page holds the text itself (100 MB) and the paste's own copy; nothing more.
    ...(["paste", "drop"] as const).map((way): Case => ({
      id: `4 text 100 MB ${way} remote`,
      text: TEXT_BYTES,
      way,
      mode: "remote",
      heapBudget: 400 * MB,
    })),
    ...(
      [
        ["held-wait", "the upload finishes"],
        ["held-x", "the tile's ×"],
      ] as const
    ).map(([scenario, then]): Case => ({
      id: `5 held send, then ${then}: .mov paste remote`,
      file: MOV,
      way: "paste",
      mode: "remote",
      heapBudget: 300 * MB,
      scenario,
      droppedMs: 1000,
    })),
    {
      id: "6 staged screenshot's × while its original uploads",
      file: SHOT,
      way: "paste",
      mode: "remote",
      heapBudget: 300 * MB,
      scenario: "staged-x",
      chunkMs: 400,
    },
    {
      id: "7 JPEG, 72 KiB of APP segments, 12000x9000",
      file: JPEG,
      way: "paste",
      mode: "remote",
      heapBudget: 300 * MB,
      scenario: "jpeg-app",
    },
  ];

  /// A sparse file of `size` bytes starting with `header`; kept from an earlier run when its size matches.
  function sparse(file: BigFile) {
    const at = path.join(dir, file.name);
    if (existsSync(at) && statSync(at).size === file.size) return;
    const fd = openSync(at, "w");
    try {
      if (file.header) writeSync(fd, Buffer.from(file.header));
      ftruncateSync(fd, file.size!);
    } finally {
      closeSync(fd);
    }
  }

  /// A real PNG (RGB): one colour with rows of noise, written row by row with zlib, so neither this
  /// process nor the page ever holds its pixels.
  function png(file: BigFile) {
    const at = path.join(dir, file.name);
    if (existsSync(at) && statSync(at).size > 1024 * 1024) return;
    const { width, height, noise } = file.png!;
    const script = `
import os, struct, sys, zlib
path, width, height, noise = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
def chunk(out, kind, data):
    out.write(struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
with open(path + ".part", "wb") as out:
    out.write(b"\\x89PNG\\r\\n\\x1a\\n")
    chunk(out, b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    deflate = zlib.compressobj(6)
    plain = b"\\x00" + bytes((40, 90, 160)) * width
    held, size = [], 0
    for row in range(height):
        data = deflate.compress(b"\\x00" + os.urandom(3 * width) if row % noise == 0 else plain)
        if data:
            held.append(data)
            size += len(data)
        if size >= 1 << 20:
            chunk(out, b"IDAT", b"".join(held))
            held, size = [], 0
    held.append(deflate.flush())
    chunk(out, b"IDAT", b"".join(held))
    chunk(out, b"IEND", b"")
os.replace(path + ".part", path)
`;
    const made = spawnSync("python3", ["-I", "-c", script, at, String(width), String(height), String(noise)], {
      encoding: "utf8",
    });
    if (made.status !== 0) throw new Error(`could not write ${file.name}: ${made.stderr}`);
  }

  /// A JPEG whose APP1 (Exif) and APP2 (ICC) segments take `app` bytes before its baseline frame
  /// header (SOF0) of `width` x `height`, then a scan of zeros: its size is only in the header past
  /// the first 64 KiB, and its body need not decode.
  function jpeg(file: BigFile) {
    const { width, height, app } = file.jpeg!;
    const parts: Buffer[] = [Buffer.from([0xff, 0xd8])];
    const segment = (marker: number, payload: Buffer) => {
      const head = Buffer.from([0xff, marker, 0, 0]);
      head.writeUInt16BE(payload.length + 2, 2);
      parts.push(head, payload);
    };
    // One segment holds at most 65533 bytes: Exif fills APP1, ICC profiles take the rest.
    let left = app;
    for (const [marker, tag] of [
      [0xe1, "Exif\0\0"],
      [0xe2, "ICC_PROFILE\0"],
    ] as const) {
      const length = Math.min(65533, left - 4);
      if (length <= tag.length) break;
      const payload = Buffer.alloc(length);
      payload.write(tag, "latin1");
      segment(marker, payload);
      left -= length + 4;
    }
    const frame = Buffer.from([8, 0, 0, 0, 0, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
    frame.writeUInt16BE(height, 1);
    frame.writeUInt16BE(width, 3);
    segment(0xc0, frame);
    segment(0xda, Buffer.from([3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3f, 0]));
    parts.push(Buffer.alloc(64 * 1024), Buffer.from([0xff, 0xd9]));
    writeFileSync(path.join(dir, file.name), Buffer.concat(parts));
    file.size = statSync(path.join(dir, file.name)).size;
  }

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const launch = () =>
    chromium.launch({ headless: true, args: ["--enable-precise-memory-info", "--js-flags=--max-old-space-size=4096"] });
  const rows: Row[] = [];
  /// The baseline row, the floor the other rows' typing and stalls are held to.
  let baseline: Row | undefined;
  beforeAll(async () => {
    for (const file of [MOV, BIN, MP4]) sparse(file);
    for (const file of [PNG, SHOT]) {
      png(file);
      file.size = statSync(path.join(dir, file.name)).size;
    }
    jpeg(JPEG);
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await launch();
  });
  afterAll(async () => {
    try {
      console.log(table(rows));
      console.log(`BIGTEST-JSON ${JSON.stringify(rows)}`);
      await browser?.close();
      await vite?.close();
    } finally {
      // Also when setup failed part way: the sparse and generated fixtures are about 3 GB apparent.
      rmSync(dir, { recursive: true, force: true });
    }
  });

  /// The page's native host and in-page probes, before the page's own scripts run.
  function hostStub(config: {
    mode: Mode;
    known: string[];
    chunkMs: number;
    droppedMs: number;
    choose: string;
    workerSpy: string;
  }) {
    const page = window as unknown as BigWindow;
    const big: BigState = {
      chunkMs: config.chunkMs,
      counts: {},
      chunks: [],
      bytes: 0,
      begins: [],
      cancels: [],
      finishes: 0,
      stages: {},
      finishedAt: {},
      decodes: [],
      droppedMs: config.droppedMs,
      sends: [],
      keys: [],
      recording: false,
      stall: 0,
      heapPeak: 0,
      tileAt: 0,
      gestureAt: 0,
      clickAt: 0,
      sendReady: false,
      startBeat() {},
      stopBeat() {},
      watchTile() {},
      watchKeys() {},
    };
    page.__big = big;
    // The mock daemon lists each request it takes here (mock.ts), session/prompt's blocks included.
    page.cmuxGalleryLog = [];
    // Each entry with when the daemon took it.
    page.cmuxGalleryLog.push = function (...entries) {
      for (const entry of entries) entry.at = performance.now();
      return Array.prototype.push.apply(this, entries);
    };
    // A decode on the page; the image worker's are reported to /__bigtest/decode (decodeSpy).
    const decode = window.createImageBitmap.bind(window);
    window.createImageBitmap = ((source: ImageBitmapSource, ...rest: unknown[]) => {
      const blob = source instanceof Blob ? source : undefined;
      big.decodes.push({ where: "page", size: blob?.size ?? -1, type: blob?.type ?? "" });
      return (decode as (...args: unknown[]) => Promise<ImageBitmap>)(source, ...rest);
    }) as typeof createImageBitmap;
    // The image worker starts as test/support/imageWorkerSpy.ts, which reports its decodes here.
    const Started = window.Worker;
    window.Worker = class extends Started {
      constructor(url: string | URL, options?: WorkerOptions) {
        const spied = /imageWorker\.ts/.test(String(url));
        super(spied ? new URL(config.workerSpy, location.href) : url, options);
        if (spied)
          this.addEventListener("message", (event: MessageEvent<{ bigtestDecode?: BigState["decodes"][number] }>) => {
            if (event.data?.bigtestDecode) big.decodes.push(event.data.bigtestDecode);
          });
      }
    };
    const names = new Map<string, string>();
    const ok = (value: unknown) => ({ ok: true, value });
    const reply = async (method: string, params: Record<string, unknown>) => {
      big.counts[method] = (big.counts[method] ?? 0) + 1;
      switch (method) {
        case "chat.attach.dropped": {
          if (big.droppedMs > 0)
            // fixed-wait: the stand-in host's slow answer, which keeps a pasted file in its read phase.
            await new Promise((resolve) => setTimeout(resolve, big.droppedMs));
          // A chat on this Mac: the host knows where the person's own files are. A remote one: none.
          const asked = Array.isArray(params.names) ? (params.names as string[]) : [];
          const known = config.mode === "local" ? asked.filter((name) => config.known.includes(name)) : [];
          return ok({ items: known.map((name) => ({ path: `/Users/dev/Desktop/${name}`, folder: false })) });
        }
        case "chat.attach.choose":
          return ok({ items: [{ path: config.choose, folder: false }] });
        case "chat.upload.begin": {
          const token = `t${big.begins.length + 1}`;
          big.begins.push({ at: performance.now(), name: String(params.name), size: Number(params.size), token });
          names.set(token, String(params.name));
          big.stages[token] = String(params.name);
          return ok({ token, size: params.size, chunkSize: 512 * 1024 });
        }
        case "chat.upload.chunk": {
          // Counted from the base64's length: decoding it here would load the page this test times.
          const data = typeof params.data === "string" ? params.data : "";
          const length = (data.length / 4) * 3 - (data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0);
          big.chunks.push(performance.now());
          big.bytes += length;
          if (big.chunkMs > 0)
            // fixed-wait: the stand-in host's per-chunk latency, which keeps an upload running while the test acts.
            await new Promise((resolve) => setTimeout(resolve, big.chunkMs));
          return ok({ offset: Number(params.offset) + length });
        }
        case "chat.upload.finish":
          big.finishes += 1;
          big.finishedAt[String(params.token)] = performance.now();
          delete big.stages[String(params.token)];
          return ok({ path: `/srv/session/uploads/${names.get(String(params.token))}` });
        case "chat.upload.cancel":
          big.cancels.push({ at: performance.now(), token: String(params.token) });
          delete big.stages[String(params.token)];
          return ok(null);
        default:
          return ok(null);
      }
    };
    Object.assign(window, {
      webkit: {
        messageHandlers: {
          agentSession: {
            postMessage: (message: { method: string; params?: Record<string, unknown> }) =>
              reply(message.method, message.params ?? {}),
          },
        },
      },
    });
    // The page replaces its actions map as its chat connects (App.tsx): count each chat.send in it.
    type Actions = Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    let actions: Actions | undefined = { ready: async () => ({ protocolVersion: 1, transport: "mock" }) };
    Object.defineProperty(window, "cmuxAcpmuxActions", {
      configurable: true,
      get: () => actions,
      set: (next: Actions | undefined) => {
        const send = next?.["chat.send"];
        if (!next || !send) {
          actions = next;
          return;
        }
        big.sendReady = true;
        actions = {
          ...next,
          "chat.send": (params) => {
            const chips = Array.isArray(params.attachments)
              ? (params.attachments as { kind: string; name: string; size: number; path?: string }[])
              : [];
            big.sends.push({
              at: performance.now(),
              text: typeof params.text === "string" ? params.text.length : 0,
              attachments: chips.map(({ kind, name, size, path }) => ({ kind, name, size, ...(path ? { path } : {}) })),
            });
            return send(params);
          },
        };
      },
    });
    let beat = 0;
    big.startBeat = () => {
      big.stall = 0;
      big.heapPeak = 0;
      let last = performance.now();
      let tick = 0;
      const memory = (performance as unknown as { memory?: { usedJSHeapSize: number } }).memory;
      beat = window.setInterval(() => {
        const now = performance.now();
        big.stall = Math.max(big.stall, now - last);
        last = now;
        tick += 1;
        if (memory && tick % 12 === 0) big.heapPeak = Math.max(big.heapPeak, memory.usedJSHeapSize);
      }, 4);
    };
    big.stopBeat = () => window.clearInterval(beat);
    big.watchTile = () => {
      big.tileAt = 0;
      const seen = () => document.querySelector(".acpmux-composer .acpmux-attachment");
      const observer = new MutationObserver(() => {
        if (big.tileAt || !seen()) return;
        big.tileAt = performance.now();
        observer.disconnect();
      });
      observer.observe(document.body, { childList: true, subtree: true });
    };
    // A typed key: from its keydown's time to its text in the prompt (`landed`), to the task after
    // that (`settled`: the editor's and React's work for it done), and to the next frame.
    let typed: BigState["keys"][number] | undefined;
    document.addEventListener(
      "keydown",
      (event) => {
        if (big.recording && event.key.length === 1) typed = { key: event.key, down: event.timeStamp };
      },
      true,
    );
    big.watchKeys = () => {
      const field = document.querySelector(".acpmux-composer-prompt");
      if (!field) return;
      new MutationObserver(() => {
        const key = typed;
        if (!key) return;
        typed = undefined;
        key.landed = performance.now() - key.down;
        big.keys.push(key);
        setTimeout(() => {
          key.settled = performance.now() - key.down;
        }, 0);
        requestAnimationFrame(() => {
          key.frame = performance.now() - key.down;
        });
      }).observe(field, { childList: true, subtree: true, characterData: true });
    };
    document.addEventListener(
      "change",
      (event) => {
        const input = event.target as HTMLInputElement;
        if (!input.classList?.contains("acpmux-attach-input")) return;
        big.gestureAt = performance.now();
        big.chosenType = input.files?.[0]?.type;
      },
      true,
    );
    document.addEventListener(
      "click",
      (event) => {
        if ((event.target as Element).closest?.(".acpmux-attachment-remove")) big.clickAt = performance.now();
      },
      true,
    );
  }

  class Frozen extends Error {}
  /// `work`, or a Frozen failure named `label` once `ms` pass without it.
  const step = <T>(label: string, work: Promise<T>, ms = STEP_MS): Promise<T> =>
    Promise.race([
      work,
      new Promise<T>((_, reject) =>
        setTimeout(() => reject(new Frozen(`${label} did not finish in ${ms / 1000} s`)), ms),
      ),
    ]);

  /// The page's probes, as plain data.
  const probes = (page: Page) =>
    page.evaluate(() => {
      const state = (window as unknown as BigWindow).__big;
      return {
        chunks: state.chunks,
        begins: state.begins.length,
        begun: state.begins.map(({ name, token, at }) => ({ name, token, at })),
        cancels: state.cancels.length,
        cancelled: state.cancels.map(({ token }) => token),
        finishes: state.finishes,
        finishedAt: state.finishedAt,
        stages: Object.entries(state.stages).map(([token, name]) => `${name} (${token})`),
        decodes: state.decodes,
        keys: state.keys,
        stall: state.stall,
        heapPeak: state.heapPeak,
        tileAt: state.tileAt,
        gestureAt: state.gestureAt,
        clickAt: state.clickAt,
        chosenType: state.chosenType,
      };
    });

  /// The renderers' process ids, from the browser (one page is open at a time).
  async function rendererPids(): Promise<number[]> {
    try {
      const session = await browser!.newBrowserCDPSession();
      const { processInfo } = (await session.send("SystemInfo.getProcessInfo")) as {
        processInfo: { type: string; id: number }[];
      };
      await session.detach();
      return processInfo.filter((info) => info.type === "renderer").map((info) => info.id);
    } catch {
      return [];
    }
  }
  /// The renderers' resident memory, in bytes, from /proc (0 where there is none).
  function rss(pids: number[]): number {
    let total = 0;
    for (const pid of pids) {
      try {
        const match = /VmRSS:\s+(\d+) kB/.exec(readFileSync(`/proc/${pid}/status`, "utf8"));
        if (match) total += Number(match[1]) * 1024;
      } catch {
        // The process is gone.
      }
    }
    return total;
  }
  /// The page's JS heap after a full GC, and the renderers' resident memory.
  async function settledMemory(cdp: CDPSession, pids: number[]) {
    await cdp.send("HeapProfiler.collectGarbage");
    const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
    return { heap: metrics.find((metric) => metric.name === "JSHeapUsedSize")?.value ?? 0, rss: rss(pids) };
  }
  async function liveHeap(cdp: CDPSession) {
    const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
    return metrics.find((metric) => metric.name === "JSHeapUsedSize")?.value ?? 0;
  }

  const promptText = (page: Page) =>
    page.locator(PROMPT).evaluate((node) => node.textContent?.replace(/ /g, " ") ?? "");
  const sentPrompts = (page: Page) =>
    page.evaluate(
      () =>
        (window as unknown as BigWindow).cmuxGalleryLog.filter((entry) => entry.method === "acpmux session/prompt")
          .length,
    );
  /// The blocks of session/prompt number `index`, without their bytes.
  const promptBlocks = (page: Page, index: number) =>
    page.evaluate((index) => {
      const entry = (window as unknown as BigWindow).cmuxGalleryLog.filter(
        (item) => item.method === "acpmux session/prompt",
      )[index];
      const blocks = Array.isArray(entry?.params?.prompt) ? (entry.params.prompt as Record<string, unknown>[]) : [];
      return blocks.map((block) => ({
        type: String(block.type),
        ...(typeof block.name === "string" ? { name: block.name } : {}),
        ...(typeof block.uri === "string" ? { uri: block.uri } : {}),
        ...(typeof block.mimeType === "string" ? { mimeType: block.mimeType } : {}),
        ...(typeof block.text === "string" ? { text: block.text.length } : {}),
        ...(typeof block.data === "string" ? { data: block.data.length } : {}),
      }));
    }, index);

  /// Readies what the next gesture hands the page: a DataTransfer holding the disk-backed file (as
  /// the person's file manager would give it, typed as macOS types it) or the text.
  const prepareTransfer = (page: Page, c: Case) =>
    page.evaluate(
      ({ text, type }) => {
        const state = window as unknown as BigWindow;
        const data = new DataTransfer();
        if (text) data.setData("text/plain", state.__bigText!);
        else {
          const input = document.getElementById("bigtest-file") as HTMLInputElement;
          let file = input.files![0]!;
          if (file.type !== type) file = new File([file], file.name, { type, lastModified: file.lastModified });
          data.items.add(file);
        }
        state.__bigTransfer = data;
      },
      { text: Boolean(c.text), type: c.file?.type ?? "" },
    );

  /// Pastes, drops or chooses the case's file (or text); returns the gesture's time on the page.
  async function gesture(page: Page, c: Case): Promise<number> {
    if (c.way === "menu") {
      await page.locator(".acpmux-composer-plus .acpmux-picker-button").click();
      const chooser = page.waitForEvent("filechooser", { timeout: 5_000 });
      await page.locator('[role="listbox"] [role="option"][data-value="attach"]').click();
      await (await chooser).setFiles(path.join(dir, c.file!.name));
      await page.waitForFunction(() => (window as unknown as BigWindow).__big.gestureAt > 0, undefined, {
        polling: 20,
        timeout: 5_000,
      });
      return (await probes(page)).gestureAt;
    }
    await prepareTransfer(page, c);
    return page.evaluate(
      ({ way, prompt, text }) => {
        const state = window as unknown as BigWindow;
        const data = state.__bigTransfer!;
        delete state.__bigTransfer;
        const field = document.querySelector(prompt)!;
        const at = performance.now();
        state.__big.gestureAt = at;
        if (way === "paste")
          field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
        else {
          // Over the prompt (a text drop lands where it is dropped) or the composer (files).
          const target = text ? field : document.querySelector(".acpmux-composer-box")!;
          const box = target.getBoundingClientRect();
          const init = {
            dataTransfer: data,
            bubbles: true,
            cancelable: true,
            clientX: box.left + Math.min(40, box.width / 2),
            clientY: box.top + box.height / 2,
          };
          for (const type of ["dragenter", "dragover", "drop"]) target.dispatchEvent(new DragEvent(type, init));
        }
        return at;
      },
      { way: c.way, prompt: PROMPT, text: Boolean(c.text) },
    );
  }

  const quantile = (values: number[], q: number) => {
    const sorted = [...values].sort((a, b) => a - b);
    return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]! : NaN;
  };
  /// Whether `block` is the file (its name, or the end of its link).
  const names = (block: Block, name: string) =>
    block.name === name || Boolean(block.uri?.endsWith(`/${encodeURIComponent(name)}`));

  async function closeQuietly(context: BrowserContext) {
    try {
      await step("closing the page", context.close(), 20_000);
    } catch {
      // A renderer that never answers: a fresh browser for the next case.
      const stuck = browser;
      browser = await launch();
      void stuck?.close().catch(() => undefined);
    }
  }

  const PENDING = ".acpmux-composer .acpmux-attachment-pending";
  /// When `session/prompt` number `count` went (the page's clock), or undefined after `ms`.
  const promptAfter = (page: Page, count: number, ms: number) =>
    page
      .waitForFunction(
        (count) => {
          const sent = (window as unknown as BigWindow).cmuxGalleryLog.filter(
            (entry) => entry.method === "acpmux session/prompt",
          );
          return sent.length > count ? (sent[count]!.at ?? 1) : false;
        },
        count,
        { polling: 20, timeout: ms },
      )
      .then(
        (handle) => handle.jsonValue() as Promise<number>,
        () => undefined,
      );
  /// Whether `blocks` link the copy of `name` the host saved (`chat.upload.finish`'s path).
  const uploadedLink = (blocks: Block[], name: string) =>
    blocks.some(
      (block) =>
        block.type === "resource_link" && decodeURIComponent(block.uri ?? "") === `file:///srv/session/uploads/${name}`,
    );

  /// After a ×: the upload it took away stops (no chunk after the click) and the host is told
  /// (`chat.upload.cancel`, for `token` when given).
  async function uploadStopped(page: Page, row: Row, problem: (text: string) => void, token?: string) {
    row.uploadCancelSent = await page
      .waitForFunction(
        (token) => {
          const cancels = (window as unknown as BigWindow).__big.cancels;
          return token ? cancels.some((cancel) => cancel.token === token) : cancels.length > 0;
        },
        token,
        { polling: 50, timeout: 5_000 },
      )
      .then(
        () => true,
        () => false,
      );
    // fixed-wait: an upload that stopped says nothing; the assertion is that no chunk follows.
    await page.waitForTimeout(1_500);
    const stopped = await probes(page);
    row.chunksAfterX = stopped.chunks.filter((time) => time > stopped.clickAt).length;
    if (!row.uploadCancelSent)
      problem(token ? `the × sent no chat.upload.cancel for its token ${token}` : "the × sent no chat.upload.cancel");
    if (row.chunksAfterX > 1) problem(`the upload went on after the ×: ${row.chunksAfterX} chunks`);
  }

  /// The upload still running finishes (the host answers at once from here); then the next prompt
  /// carries the link to the copy of `name` the host saved.
  async function nextPrompt(page: Page, row: Row, problem: (text: string) => void, name: string) {
    await page.evaluate(() => ((window as unknown as BigWindow).__big.chunkMs = 0));
    const done = await page
      .waitForFunction((pending) => !document.querySelector(pending), PENDING, { polling: 100, timeout: 300_000 })
      .then(
        () => true,
        () => false,
      );
    if (!done) {
      problem("its upload never finished");
      return;
    }
    await step("the prompt for the next send", page.locator(PROMPT).click());
    await page.keyboard.type(" and the file");
    const count = await sentPrompts(page);
    await step("pressing Enter for the next prompt", page.keyboard.press("Enter"));
    const went = await promptAfter(page, count, 60_000);
    row.nextBlocks = went === undefined ? [] : await promptBlocks(page, count);
    if (went === undefined) problem("the next prompt after the upload finished never went");
    else if (!uploadedLink(row.nextBlocks, name))
      problem(`the next prompt after its upload finished carried no link to it: ${blocksText(row.nextBlocks)}`);
  }

  /// The host holds no upload stage open once the case is done (begin opened it, finish or cancel
  /// closes it).
  async function stagesClosed(page: Page, row: Row, problem: (text: string) => void) {
    await page
      .waitForFunction(() => Object.keys((window as unknown as BigWindow).__big.stages).length === 0, undefined, {
        polling: 50,
        timeout: 10_000,
      })
      .catch(() => undefined);
    row.stagesLeft = (await probes(page)).stages;
    if (row.stagesLeft.length) problem(`upload stages left open on the host: ${row.stagesLeft.join(", ")}`);
  }

  /// The three ways a file still went wrong (Codex review of #25191/#25192), each its own steps.
  async function scenario(page: Page, c: Case, row: Row, problem: (text: string) => void) {
    const prompt = page.locator(PROMPT);
    const name = c.file!.name;
    const tile = () =>
      step(
        "the tile",
        page.waitForFunction(() => (window as unknown as BigWindow).__big.tileAt > 0, undefined, {
          polling: 20,
          timeout: STEP_MS - 1000,
        }),
      );
    if (c.scenario === "held-wait" || c.scenario === "held-x") {
      // 5. Enter while the pasted recording is still being read (the host takes `droppedMs` to say
      // where it is): the prompt waits for it, never going without it the moment its upload starts.
      await page.keyboard.type("what is in this recording");
      const before = await sentPrompts(page);
      await page.evaluate(() => (window as unknown as BigWindow).__big.watchTile());
      await step("the paste", gesture(page, c));
      await tile();
      const enter = await page.evaluate(() => performance.now());
      await step("pressing Enter", page.keyboard.press("Enter"));
      if ((await probes(page)).begins) row.note = "its upload had begun by Enter";
      if (c.scenario === "held-wait") {
        const went = await promptAfter(page, before, 240_000);
        const probe = await probes(page);
        const begin = probe.begun.find((entry) => entry.name === name);
        const finished = begin ? probe.finishedAt[begin.token] : undefined;
        if (went === undefined) {
          row.send = "held; never went";
          problem(`the held prompt never went (its upload ${finished === undefined ? "did not finish" : "finished"})`);
        } else {
          row.sentBlocks = await promptBlocks(page, before);
          if (uploadedLink(row.sentBlocks, name)) {
            row.send = `held ${((went - enter) / 1000).toFixed(1)} s; went with the file's link`;
            if (finished === undefined || went < finished) problem("the held prompt went before its upload finished");
          } else {
            row.send =
              begin && went >= begin.at
                ? `went without the file ${(went - begin.at).toFixed(0)} ms after its upload began`
                : "went without the file before its upload began";
            problem(`the held prompt ${row.send}`);
          }
        }
        // Gone without it: the file stays, and the next prompt carries it once its upload finishes.
        if (!row.sentBlocks || !uploadedLink(row.sentBlocks, name)) await nextPrompt(page, row, problem, name);
        return;
      }
      const begun = await page
        .waitForFunction(() => (window as unknown as BigWindow).__big.begins.length > 0, undefined, {
          polling: 20,
          timeout: 10_000,
        })
        .then(
          () => true,
          () => false,
        );
      if (!begun) problem("its upload never began");
      // A prompt let go as the upload starts goes at once; this one must still be held.
      const early = await promptAfter(page, before, 1_500);
      const begin = (await probes(page)).begun.find((entry) => entry.name === name);
      if (early !== undefined) {
        row.sentBlocks = await promptBlocks(page, before);
        row.send = `went without the file ${(early - (begin?.at ?? enter)).toFixed(0)} ms after its upload began`;
        problem(`the held prompt ${row.send}`);
      }
      const loading = page.locator(PENDING).first();
      if (!(await loading.count())) {
        problem("no loading tile left to take away");
        return;
      }
      await step("the tile's ×", loading.locator(".acpmux-attachment-remove").click());
      row.cancel = (await page.locator(PENDING).count()) ? "loading tile stayed" : "loading tile gone";
      if (early === undefined) {
        const went = await promptAfter(page, before, SEND_MS);
        if (went === undefined) {
          row.send = "held; the tile's × did not send it";
          problem(row.send);
        } else {
          row.sentBlocks = await promptBlocks(page, before);
          row.send = `held; the tile's × sent it without the file in ${(went - (await probes(page)).clickAt).toFixed(0)} ms`;
          if (row.sentBlocks.some((block) => names(block, name)))
            problem("the prompt the × sent still carried the file");
        }
      }
      await uploadStopped(page, row, problem, begin?.token);
      return;
    }
    if (c.scenario === "staged-x") {
      // 6. A pasted screenshot is its preview chip while its original streams to the session's
      // machine: that chip's × stops the original's upload.
      await step("the paste", gesture(page, c));
      const staged = page.locator(
        ".acpmux-composer .acpmux-attachment-image:not(.acpmux-attachment-pending):not(.acpmux-attachment-failed)",
      );
      await step("the preview chip", staged.first().waitFor({ timeout: STEP_MS - 1000 }));
      await page
        .waitForFunction(() => (window as unknown as BigWindow).__big.begins.length > 0, undefined, {
          polling: 20,
          timeout: 10_000,
        })
        .catch(() => undefined);
      const probe = await probes(page);
      const begin = probe.begun.find((entry) => entry.name === name);
      if (!begin) problem("its original never began uploading");
      else if (probe.finishedAt[begin.token] !== undefined)
        problem("its original finished uploading before its chip showed: nothing was left to stop");
      row.note = `${probe.chunks.length} of ${Math.ceil(c.file!.size! / (512 * 1024))} chunks in at the ×`;
      await step("the preview chip's ×", staged.first().locator(".acpmux-attachment-remove").click());
      row.cancel = (await staged.count()) ? "preview chip stayed" : "preview chip gone";
      if (await staged.count()) problem("the preview chip's × left the chip");
      if (begin) await uploadStopped(page, row, problem, begin.token);
      // The prompt after it carries neither the preview nor the original.
      await step("the prompt for the send", prompt.click());
      await page.keyboard.type("no screenshot after all");
      const before = await sentPrompts(page);
      await step("pressing Enter", page.keyboard.press("Enter"));
      const went = await promptAfter(page, before, SEND_MS);
      row.sentBlocks = went === undefined ? [] : await promptBlocks(page, before);
      if (went === undefined) problem("the prompt after the × never went");
      if (row.sentBlocks.some((block) => block.type === "image" || names(block, name)))
        problem(`the removed screenshot still went: ${blocksText(row.sentBlocks)}`);
      return;
    }
    // 7. A JPEG whose APP segments run past 64 KiB before its frame header: never decoded, it goes
    // as a file.
    await step("the paste", gesture(page, c));
    const settled = await page
      .waitForFunction(
        (pending) => document.querySelector(".acpmux-composer .acpmux-attachment") && !document.querySelector(pending),
        PENDING,
        { polling: 50, timeout: 60_000 },
      )
      .then(
        () => true,
        () => false,
      );
    if (!settled) problem("it never settled into a chip");
    const decodes = (await probes(page)).decodes.filter((decode) => decode.size === c.file!.size);
    row.note = decodes.length
      ? `createImageBitmap called ${decodes.length}x (${decodes.map((decode) => decode.where).join(", ")})`
      : "never decoded";
    if (decodes.length) problem(`it was decoded: ${row.note}`);
    const image = await page.locator(".acpmux-composer .acpmux-attachment-image").count();
    const link = await page.locator(".acpmux-composer .acpmux-attachment-link").count();
    row.cancel = image ? "an image chip" : link ? "a file chip" : "no chip";
    if (image) problem("it became an image chip");
    if (!link) problem("it did not go as a file");
    await step("the prompt for the send", prompt.click());
    await page.keyboard.type("what is in this photo");
    const before = await sentPrompts(page);
    await step("pressing Enter", page.keyboard.press("Enter"));
    const went = await promptAfter(page, before, SEND_MS);
    row.sentBlocks = went === undefined ? [] : await promptBlocks(page, before);
    if (went === undefined) problem("its prompt never went");
    else {
      if (!uploadedLink(row.sentBlocks, name))
        problem(`its prompt carried no link to its copy: ${blocksText(row.sentBlocks)}`);
      if (row.sentBlocks.some((block) => block.type === "image")) problem("its prompt carried it as an image");
    }
  }

  async function runCase(c: Case): Promise<Row> {
    const size = c.file?.size ?? c.text ?? 0;
    const row: Row = { id: c.id, way: c.way, mode: c.mode, size, problems: [] };
    const problem = (text: string) => row.problems.push(text);
    const context = await browser!.newContext({ viewport: { width: 1000, height: 760 } });
    const page = await context.newPage();
    page.on("crash", () => problem("the page crashed"));
    await page.addInitScript(hostStub, {
      mode: c.mode,
      known: c.file ? [c.file.name] : [],
      chunkMs: c.chunkMs ?? CHUNK_MS,
      droppedMs: c.droppedMs ?? 0,
      choose: `/Users/dev/Desktop/${c.file?.name ?? "notes.txt"}`,
      workerSpy: `/@fs${path.join(webviews, "test/support/imageWorkerSpy.ts")}?worker_file&type=module`,
    });
    const cdp = await context.newCDPSession(page);
    let sampler: ReturnType<typeof setInterval> | undefined;
    try {
      await cdp.send("Performance.enable");
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/`);
      await page.locator(PROMPT).waitFor();
      await page.waitForFunction(() => (window as unknown as BigWindow).__big.sendReady, undefined, {
        timeout: 30_000,
      });
      await page.evaluate(() => (window as unknown as BigWindow).__big.watchKeys());
      const pids = await rendererPids();
      if (c.file) {
        await page.evaluate(() => {
          const input = document.createElement("input");
          input.type = "file";
          input.id = "bigtest-file";
          input.hidden = true;
          document.body.append(input);
        });
        await page.setInputFiles("#bigtest-file", path.join(dir, c.file.name));
        row.fileType = await page.evaluate(
          () => (document.getElementById("bigtest-file") as HTMLInputElement).files![0]!.type,
        );
      } else {
        await page.evaluate((bytes) => {
          const line = "2026-10-25 10:14:02 build step 0042 finished: the quick brown fox jumps over the lazy dog.\n";
          (window as unknown as BigWindow).__bigText = line.repeat(Math.ceil(bytes / line.length)).slice(0, bytes);
        }, c.text!);
      }
      const prompt = page.locator(PROMPT);
      await prompt.click();
      if (c.scenario) {
        await scenario(page, c, row, problem);
        await stagesClosed(page, row, problem);
        return row;
      }

      // 1. Attach, type, open + and close it, then the tile's ×.
      const attaching = c.way !== "none";
      if (attaching && c.way !== "menu") await prepareTransfer(page, c);
      const base = await settledMemory(cdp, pids);
      let rssPeak = base.rss;
      sampler = setInterval(() => (rssPeak = Math.max(rssPeak, rss(pids))), 200);
      await page.evaluate(() => {
        const state = (window as unknown as BigWindow).__big;
        state.startBeat();
        state.watchTile();
      });
      if (attaching) {
        const at = await step(`the ${c.way}`, gesture(page, c));
        await step(
          "the tile",
          page.waitForFunction(() => (window as unknown as BigWindow).__big.tileAt > 0, undefined, {
            polling: 20,
            timeout: STEP_MS - 1000,
          }),
        );
        const shown = await probes(page);
        row.tileMs = shown.tileAt - at;
        if (c.way === "menu") row.fileType = shown.chosenType;
      }
      await step("focusing the prompt", prompt.click());
      await page.evaluate(() => ((window as unknown as BigWindow).__big.recording = true));
      await step("typing 20 keys", page.keyboard.type(TYPED, { delay: 30 }));
      await page.evaluate(() => ((window as unknown as BigWindow).__big.recording = false));
      await step(
        "the last key's frame",
        page.waitForFunction(
          () => (window as unknown as BigWindow).__big.keys.every((key) => key.frame !== undefined),
          undefined,
          { polling: 20, timeout: 10_000 },
        ),
      );
      const keys = (await probes(page)).keys.map((key) => key.settled ?? key.landed ?? Infinity);
      const typed = await promptText(page);
      row.keys = {
        p50: quantile(keys, 0.5),
        p95: quantile(keys, 0.95),
        max: Math.max(...keys),
        lost: keys.length !== TYPED.length || typed !== TYPED,
      };
      const opened = Date.now();
      await step("opening the + menu", page.locator(".acpmux-composer-plus .acpmux-picker-button").click());
      await step(
        "the + menu",
        page
          .locator('[role="listbox"]')
          .first()
          .waitFor({ timeout: STEP_MS - 1000 }),
      );
      row.menuMs = Date.now() - opened;
      await step("closing the + menu", page.keyboard.press("Escape"));
      await step("the + menu closed", page.locator('[role="listbox"]').first().waitFor({ state: "detached" }));
      const heapNow = await liveHeap(cdp);
      const pending = page.locator(".acpmux-composer .acpmux-attachment-pending");
      const begun = (await probes(page)).begins;
      if (await pending.count()) {
        await step("the tile's ×", pending.first().locator(".acpmux-attachment-remove").click());
        const gone = await page
          .waitForFunction(
            () =>
              !document.querySelector(".acpmux-composer .acpmux-attachment-pending") &&
              !document.querySelector(".acpmux-composer .acpmux-attachment-failed"),
            undefined,
            { polling: 20, timeout: 1_000 },
          )
          .then(
            () => true,
            () => false,
          );
        row.cancel = gone ? "loading tile gone" : "loading tile stayed";
        if (!gone) problem("the loading tile's × left a tile");
        if (begun) await uploadStopped(page, row, problem);
      } else {
        const chip = page.locator(".acpmux-composer .acpmux-attachment").first();
        if (await chip.count()) {
          row.cancel = `already a chip (${await chip.getAttribute("class")}); removed`;
          await step("the chip's ×", chip.locator(".acpmux-attachment-remove").click());
          if (await page.locator(".acpmux-composer .acpmux-attachment").count()) problem("the chip's × left a chip");
        } else row.cancel = "no tile left to remove";
      }
      const state = await probes(page);
      await page.evaluate(() => (window as unknown as BigWindow).__big.stopBeat());
      row.stallMs = state.stall;
      const after = await settledMemory(cdp, pids);
      clearInterval(sampler);
      row.heap = { base: base.heap, peak: Math.max(state.heapPeak, heapNow, base.heap), after: after.heap };
      row.rss = { base: base.rss, peak: rssPeak, after: after.rss };

      if (row.tileMs !== undefined && row.tileMs > TILE_MS)
        problem(`the tile took ${row.tileMs.toFixed(0)} ms to show`);
      if (row.keys.lost) problem(`typed keys were lost: the prompt reads ${JSON.stringify(typed.slice(0, 40))}`);
      if (!attaching) baseline = row;
      else {
        const p95 = Math.max(KEY_P95_MS, (baseline?.keys?.p95 ?? 0) + KEY_ADDED_MS);
        const max = Math.max(KEY_MAX_MS, (baseline?.keys?.max ?? 0) + 2 * KEY_ADDED_MS);
        if (row.keys.p95 > p95) problem(`typing p95 ${row.keys.p95.toFixed(1)} ms per key (limit ${p95.toFixed(0)})`);
        if (row.keys.max > max) problem(`a key took ${row.keys.max.toFixed(0)} ms (limit ${max.toFixed(0)})`);
      }
      const stall = Math.max(MAX_STALL_MS, (baseline?.stallMs ?? 0) + STALL_ADDED_MS);
      if (attaching && row.stallMs > stall)
        problem(`the main thread stalled ${row.stallMs.toFixed(0)} ms (limit ${stall.toFixed(0)})`);
      if (row.menuMs > MENU_MS) problem(`the + menu took ${row.menuMs} ms to open`);
      if (row.heap.peak - row.heap.base > c.heapBudget)
        problem(`the heap grew ${((row.heap.peak - row.heap.base) / MB).toFixed(0)} MB while it loaded`);
      if (row.heap.after - row.heap.base > HEAP_BACK)
        problem(`the heap stayed ${((row.heap.after - row.heap.base) / MB).toFixed(0)} MB up after the ×`);

      // 2. Attach again and send another message at once.
      await step("the prompt for the send", prompt.click());
      if (!(await promptText(page)).trim()) await page.keyboard.type(TYPED);
      const beginsBefore = (await probes(page)).begins;
      if (attaching) {
        await page.evaluate(() => (window as unknown as BigWindow).__big.watchTile());
        await step(`the second ${c.way}`, gesture(page, c));
        await step(
          "the second tile",
          page.waitForFunction(() => (window as unknown as BigWindow).__big.tileAt > 0, undefined, {
            polling: 20,
            timeout: STEP_MS - 1000,
          }),
        );
        // A file streaming to the session's machine holds no send (one still being read does: case 5).
        await page
          .waitForFunction(
            ({ begun, pending }) =>
              (window as unknown as BigWindow).__big.begins.length > begun || !document.querySelector(pending),
            { begun: beginsBefore, pending: PENDING },
            { polling: 20, timeout: 10_000 },
          )
          .catch(() => undefined);
      }
      await step("the prompt before Enter", prompt.click());
      const before = await sentPrompts(page);
      const pressed = Date.now();
      await step("pressing Enter", page.keyboard.press("Enter"));
      const wentAt = await page
        .waitForFunction(
          (count) => {
            const log = (window as unknown as BigWindow).cmuxGalleryLog;
            return log.filter((entry) => entry.method === "acpmux session/prompt").length > count;
          },
          before,
          { polling: 20, timeout: SEND_MS },
        )
        .then(
          () => Date.now() - pressed,
          () => undefined,
        );
      if (wentAt !== undefined) row.send = `sent in ${wentAt} ms`;
      else {
        problem(`another message waited for the file: nothing went within ${SEND_MS / 1000} s of Enter`);
        // What its × does to the held message.
        const loading = page.locator(".acpmux-composer .acpmux-attachment-pending .acpmux-attachment-remove");
        if (await loading.count()) await step("the held tile's ×", loading.first().click());
        const late = await page
          .waitForFunction(
            (count) => {
              const log = (window as unknown as BigWindow).cmuxGalleryLog;
              return log.filter((entry) => entry.method === "acpmux session/prompt").length > count;
            },
            before,
            { polling: 20, timeout: SEND_MS },
          )
          .then(
            () => true,
            () => false,
          );
        row.send = late ? "held; went after the tile's ×" : "held; never went";
      }
      if ((await sentPrompts(page)) > before) row.sentBlocks = await promptBlocks(page, before);
      // 2b. The file that was uploading meanwhile finishes, and the next prompt carries its link.
      const second = (await probes(page)).begun.slice(beginsBefore);
      if (attaching && second.length && (await page.locator(PENDING).count()))
        await nextPrompt(page, row, problem, second[0]!.name);
      // Whatever still loads stops here.
      for (const loading of await page
        .locator(".acpmux-composer .acpmux-attachment-pending .acpmux-attachment-remove")
        .all())
        await loading.click().catch(() => undefined);

      // 3. A screen recording reaches the agent: attach it, let it finish, send.
      if (c.finish && c.file) {
        const name = c.file.name;
        let blocks = [...(row.sentBlocks ?? []), ...(row.nextBlocks ?? [])];
        if (!blocks.some((block) => names(block, name))) {
          await page.evaluate(() => ((window as unknown as BigWindow).__big.chunkMs = 0));
          await page.evaluate(() => (window as unknown as BigWindow).__big.watchTile());
          await step(`the third ${c.way}`, gesture(page, c));
          const attached = await page
            .waitForFunction(
              () =>
                document.querySelector(
                  ".acpmux-composer .acpmux-attachment-link, .acpmux-composer .acpmux-attachment-image",
                ) && !document.querySelector(".acpmux-composer .acpmux-attachment-pending"),
              undefined,
              { polling: 100, timeout: 240_000 },
            )
            .then(
              () => true,
              () => false,
            );
          if (!attached) problem("the recording never became a chip");
          await step("the prompt for the recording", prompt.click());
          await page.keyboard.type(" what is in this video");
          const count = await sentPrompts(page);
          await step("pressing Enter for the recording", page.keyboard.press("Enter"));
          const went = await page
            .waitForFunction(
              (count) => {
                const log = (window as unknown as BigWindow).cmuxGalleryLog;
                return log.filter((entry) => entry.method === "acpmux session/prompt").length > count;
              },
              count,
              { polling: 50, timeout: 60_000 },
            )
            .then(
              () => true,
              () => false,
            );
          blocks = went ? await promptBlocks(page, count) : [];
        }
        row.videoBlocks = blocks.filter((block) => names(block, name));
        if (!row.videoBlocks.length)
          problem(`the recording never reached the agent: the prompt carried ${JSON.stringify(blocks)}`);
      }
      await stagesClosed(page, row, problem);
    } catch (error) {
      if (error instanceof Frozen) {
        problem(`froze: ${error.message}`);
        await step("stopping the page's script", cdp.send("Runtime.terminateExecution"), 5_000).catch(() => undefined);
      } else problem(`failed: ${error instanceof Error ? error.message.split("\n")[0] : String(error)}`);
    } finally {
      if (sampler) clearInterval(sampler);
      await closeQuietly(context);
    }
    return row;
  }

  const mb = (bytes: number | undefined) => (bytes === undefined ? "-" : (bytes / MB).toFixed(0));
  const ms = (value: number | undefined) => (value === undefined ? "-" : value.toFixed(value < 10 ? 1 : 0));
  function blocksText(blocks: Block[] | undefined) {
    if (!blocks) return "-";
    return blocks
      .map((block) =>
        block.type === "text"
          ? `text(${block.text})`
          : block.type === "resource_link"
            ? `link(${decodeURIComponent(block.uri ?? "")})`
            : `${block.type}(${block.name ?? block.mimeType ?? ""}${block.data ? ` ${mb(block.data)} MB b64` : ""})`,
      )
      .join(" + ");
  }
  function table(rows: Row[]) {
    const head =
      "| case | type seen | tile ms | keys p50/p95/max ms | stall ms | + menu ms | × | chunks after × | upload.cancel | heap MB base/peak/after | renderer RSS MB base/peak/after | send while loading | that prompt | next prompt after finish | recording's blocks | stages left | note | failed |";
    const lines = rows.map((row) =>
      [
        row.id,
        row.fileType ?? (row.way === "none" ? "-" : "text"),
        ms(row.tileMs),
        row.keys ? `${ms(row.keys.p50)}/${ms(row.keys.p95)}/${ms(row.keys.max)}${row.keys.lost ? " LOST" : ""}` : "-",
        ms(row.stallMs),
        row.menuMs ?? "-",
        row.cancel ?? "-",
        row.chunksAfterX ?? "-",
        row.uploadCancelSent === undefined ? "-" : row.uploadCancelSent ? "yes" : "no",
        row.heap ? `${mb(row.heap.base)}/${mb(row.heap.peak)}/${mb(row.heap.after)}` : "-",
        row.rss ? `${mb(row.rss.base)}/${mb(row.rss.peak)}/${mb(row.rss.after)}` : "-",
        row.send ?? "-",
        blocksText(row.sentBlocks),
        blocksText(row.nextBlocks),
        row.videoBlocks ? blocksText(row.videoBlocks) || "none" : "-",
        row.stagesLeft ? row.stagesLeft.join(", ") || "none" : "-",
        row.note ?? "-",
        row.problems.length ? row.problems.join("; ") : "none",
      ].join(" | "),
    );
    return [head, `|${"---|".repeat(18)}`, ...lines.map((line) => `| ${line} |`)].join("\n");
  }

  for (const c of CASES)
    test(c.id, async () => {
      const row = await runCase(c);
      rows.push(row);
      console.log(`${c.id}: ${row.problems.length ? row.problems.join("; ") : "ok"}`);
      expect(row.problems).toEqual([]);
    });
});
