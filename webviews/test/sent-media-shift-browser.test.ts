// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// cmux-web-test-timeout: 900
// Leo, 2026-11-22: "i meant there were various resizing things going on, and you guys didn't predict the
// placements in time. there should be no problem doing so for inline attachments after send." A sent prompt
// with images placed in its text draws them where they were put, and nothing moves while they load: the
// row is placed at its estimate before it mounts (model.ts `layoutConversation`), each image's slot holds
// the image's own box (the size acpmux read from its header) while its bytes are read, and the bytes land
// in that box.
//
// The real transcript (test/browser/transcript-follow.html) shows a chat whose latest prompts carry
// placed images, files and a pasted shot, the reader at the latest row. acpmux answers each image read
// after READ_MS. From the first frame to SETTLE_MS after the last read, every painted frame records the
// box of every row, bubble and attachment in view. What it reports, per engine and attachment view:
//   cls        Chromium's own layout-shift score over the window (WebKit has none: null);
//   moved      the boxes that moved or resized by more than half a px after they first drew;
//   estimate   the most any prompt's drawn height differs from the height the transcript placed it at.
// The bar: cls 0, no box moved, every estimate within a px.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

const READ_MS = 400;
const SETTLE_MS = 700;

await requireBrowserLane("sent-media-shift-browser.test.ts", async () => {
  setDefaultTimeout(600_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`sent-media-shift-browser: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("sent media shift", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Row = {
    id: string;
    kind: string;
    text?: string;
    version: number;
    at: number;
    [key: string]: unknown;
  };
  let at = 0;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  /// The shots the chat's images are (a title bar, a sidebar and lines of text), by id: width, height, hue.
  const SHOTS: Record<string, [number, number, number]> = {
    wide: [1550, 300, 210],
    tall: [800, 1200, 30],
    small: [96, 64, 120],
    square: [640, 640, 300],
  };
  const image = (id: string) => ({
    kind: "image",
    id,
    mimeType: "image/png",
    name: "image.png",
    // acpmux reads each image's size from its header (hub/prompt_images.rs) and records it with the prompt.
    width: SHOTS[id]![0],
    height: SHOTS[id]![1],
    placed: true,
  });
  const text = (value: string) => ({ kind: "text", text: value });
  const prompt = (id: string, parts: Record<string, unknown>[]) =>
    row(id, "user", parts.flatMap((part) => (part.kind === "text" ? [part.text as string] : [])).join(""), {
      inlineParts: parts,
      images: parts.filter((part) => part.kind === "image").map(({ kind: _, placed: __, ...rest }) => rest),
    });
  const rows: Row[] = [
    ...Array.from({ length: 4 }, (_, index) => [
      row(`t${index}-user`, "user", `Question ${index}`),
      row(`t${index}-answer`, "assistant", `Answer ${index}. The keeper wiped the salt from the lantern glass.`),
    ]).flat(),
    prompt("p-mid", [text("The header here "), image("wide"), text(" sits under the toolbar, and this one ")]),
    row("a-mid", "assistant", "The header's top inset is read before the toolbar lays out."),
    prompt("p-several", [
      text("Compare "),
      image("small"),
      text(" with "),
      image("square"),
      text(" and the tall one "),
      image("tall"),
      text(" before you change the spacing."),
    ]),
    row("a-several", "assistant", "The small one keeps its own size; the others scale to the row."),
    prompt("p-lead", [image("tall"), text("Why does the sidebar clip here?")]),
    row("a-lead", "assistant", "Its max-height is the window's, not the pane's."),
  ];

  /// Shots painted in the page as PNG data URLs, by id.
  const paintShots = (page: Page) =>
    page.evaluate((shots) => {
      const urls: Record<string, string> = {};
      for (const [id, [width, height, hue]] of Object.entries(shots)) {
        const canvas = document.createElement("canvas");
        canvas.width = width;
        canvas.height = height;
        const ink = canvas.getContext("2d")!;
        ink.fillStyle = `hsl(${hue} 30% 16%)`;
        ink.fillRect(0, 0, width, height);
        ink.fillStyle = `hsl(${hue} 30% 24%)`;
        ink.fillRect(0, 0, width, height * 0.07);
        ink.fillRect(0, 0, width * 0.22, height);
        urls[id] = canvas.toDataURL("image/png");
      }
      return urls;
    }, SHOTS);

  type Sample = {
    key: string;
    top: number;
    left: number;
    width: number;
    height: number;
  };
  /// Shows the chat, then samples every painted frame until `SETTLE_MS` after the reads land.
  const showAndSample = (page: Page, shown: Row[]) =>
    page.evaluate(
      async ([list, windowMs]) => {
        const cls = { score: 0, supported: false };
        try {
          new PerformanceObserver((entries) => {
            for (const entry of entries.getEntries() as (PerformanceEntry & {
              value: number;
              hadRecentInput: boolean;
            })[])
              if (!entry.hadRecentInput) cls.score += entry.value;
          }).observe({ type: "layout-shift", buffered: false });
          cls.supported = PerformanceObserver.supportedEntryTypes.includes("layout-shift");
        } catch {
          // WebKit: no layout-shift entries.
        }
        const sample = () => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
          if (!scroller) return [];
          const view = scroller.getBoundingClientRect();
          const out: {
            key: string;
            top: number;
            left: number;
            width: number;
            height: number;
          }[] = [];
          const push = (key: string, node: Element) => {
            const box = node.getBoundingClientRect();
            if (box.bottom < view.top || box.top > view.bottom || box.width === 0) return;
            out.push({
              key,
              top: box.top,
              left: box.left,
              width: box.width,
              height: box.height,
            });
          };
          for (const rowNode of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
            const id = rowNode.dataset.rowId!;
            push(`row:${id}`, rowNode);
            rowNode.querySelectorAll(".cv-user__bubble").forEach((node, index) => push(`bubble:${id}:${index}`, node));
            rowNode
              .querySelectorAll(".cv-user__image, .cv-user__image-placeholder, .cv-user__image-failed")
              .forEach((node, index) => push(`media:${id}:${index}`, node));
          }
          return out;
        };
        const frames: ReturnType<typeof sample>[] = [];
        (
          window as unknown as {
            __showSession(id: string, rows: unknown): void;
          }
        ).__showSession("session-1", list);
        const start = performance.now();
        let loadedAt: number | undefined;
        // The window: until every image drew and `windowMs` more passed (at most 5 s).
        while (performance.now() - start < 5_000) {
          await new Promise((done) => requestAnimationFrame(() => done(undefined)));
          frames.push(sample());
          const images = [...document.querySelectorAll<HTMLImageElement>(".acpmux-scroll img.cv-user__image")];
          const pending = document.querySelector(".acpmux-scroll .cv-user__image-placeholder");
          if (loadedAt === undefined && images.length > 0 && !pending && images.every((img) => img.complete))
            loadedAt = performance.now();
          if (loadedAt !== undefined && performance.now() - loadedAt > windowMs) break;
        }
        return {
          frames,
          cls: cls.supported ? cls.score : null,
          loaded: loadedAt !== undefined,
        };
      },
      [shown, SETTLE_MS] as const,
    );

  /// Each box's moves after it first drew: a box at a new place or size, frame to frame.
  const movesOf = (frames: Sample[][]) => {
    const last = new Map<string, Sample>();
    const moves: string[] = [];
    frames.forEach((frame, index) => {
      for (const box of frame) {
        const before = last.get(box.key);
        last.set(box.key, box);
        if (!before) continue;
        const moved = Math.max(
          Math.abs(box.top - before.top),
          Math.abs(box.left - before.left),
          Math.abs(box.width - before.width),
          Math.abs(box.height - before.height),
        );
        if (moved > 0.5)
          moves.push(
            `frame ${index} ${box.key}: ${Math.round(before.left)},${Math.round(before.top)} ${Math.round(before.width)}x${Math.round(before.height)} -> ${Math.round(box.left)},${Math.round(box.top)} ${Math.round(box.width)}x${Math.round(box.height)}`,
          );
      }
    });
    return moves;
  };

  for (const [name] of engines)
    for (const attachmentView of ["inline", "strip"] as const) {
      test(`${name} ${attachmentView}: sent images placed in the text draw in their boxes, and nothing moves as they load`, async () => {
        const page = await browsers.get(name)!.newPage({ viewport: { width: 1100, height: 900 } });
        const { port } = vite!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
        await page.waitForFunction(() => "__showSession" in window && "__imageReader" in window);
        await page.evaluate(() => document.fonts.ready.then(() => undefined));
        const urls = await paintShots(page);
        await page.evaluate(
          ([shots, delay, view]) => {
            const w = window as unknown as {
              __imageReader(urls: Record<string, string>, delayMs: number): void;
              __attachmentView(view: string): void;
              __showSession(id: string, rows: unknown): void;
            };
            w.__showSession("empty", []);
            w.__attachmentView(view);
            w.__imageReader(shots, delay);
          },
          [urls, READ_MS, attachmentView] as const,
        );
        const { frames, cls, loaded } = await showAndSample(page, rows);
        expect(loaded).toBe(true);
        const moves = movesOf(frames);

        // Each prompt with attachments: its drawn height against the transcript's own estimate at its width.
        const prompts = rows.filter((one) => one.inlineParts);
        const drawn = await page.evaluate(
          (ids) =>
            ids.map((id) => {
              const node = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`);
              const box = node?.getBoundingClientRect();
              return box ? { width: box.width, height: box.height } : null;
            }),
          prompts.map((one) => one.id),
        );
        const estimates = await page.evaluate(
          async ([shown, widths]) => {
            const model = (await import(
              /* @vite-ignore */ `${location.origin}/src/agent-session/acpmux/model.ts`
            )) as typeof import("../src/agent-session/acpmux/model");
            return shown.map((one, index) =>
              widths[index]
                ? model.layoutConversation(
                    [one as never],
                    widths[index]!.width,
                    undefined,
                    undefined,
                    undefined,
                    undefined,
                    "session-1",
                  ).heights[0]!
                : null,
            );
          },
          [prompts, drawn] as const,
        );
        const misses = prompts.flatMap((one, index) =>
          drawn[index] && estimates[index] !== null && Math.abs(estimates[index]! - drawn[index]!.height) > 1
            ? [`${one.id}: estimated ${estimates[index]}, drawn ${drawn[index]!.height}`]
            : [],
        );
        const inlineDrawn = await page.evaluate(
          () => document.querySelectorAll(".acpmux-scroll .cv-user__bubble .cv-user__image").length,
        );
        console.log(
          `SENT-MEDIA-SHIFT ${name} ${attachmentView}: cls ${cls === null ? "n/a" : cls.toFixed(4)} moved ${moves.length} estimate-misses ${misses.length} inline-in-bubble ${inlineDrawn} frames ${frames.length}`,
        );
        for (const line of [...moves.slice(0, 20), ...misses]) console.log(`  ${line}`);
        if (attachmentView === "inline") expect(inlineDrawn).toBeGreaterThan(0);
        expect(misses).toEqual([]);
        expect(moves).toEqual([]);
        if (cls !== null) expect(cls).toBe(0);
        await page.close();
      });
    }
});
