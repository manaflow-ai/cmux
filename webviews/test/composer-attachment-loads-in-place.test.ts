// Leo, 2026-11-09: "oh the other situation where when the loading placeholder for attachments goes to
// the top... it means that when it actually loads, it gets smashed in between text that you were
// typing if u were typing as it loaded. so the placeholders should be right at the composer in and
// instant"
//
// An attachment's loading placeholder shows at once in its final place, and what the read makes
// takes that same place: the node in the text is the same element from the first frame to the last,
// at the same spot, and the words typed while it loads stay whole around it. Nothing shows in the
// strip above the text first, and nothing is put in at the caret when the read ends.
//
// Each test types key by key while a slow read is held (the page's file reads wait on a gate the
// test opens), and samples every painted frame (support/paintedFrames.ts):
// - a screenshot pasted while the chat's saved draft is still being read: the read answering took
//   the placeholder out of the text (into the strip at the top), and the read picture then went in
//   at the caret, between the words typed meanwhile;
// - a screenshot dropped between words: it loads in its node, the words around it whole;
// - a screenshot pasted where no attachment can go (a code block): it loads where it shows, in the
//   strip, and is never put in at the caret the person moved on to.
//
// The page is the pane's dev entry with the in-page mock daemon. Real Chromium from Playwright; CI
// fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rect = { x: number; y: number; width: number; height: number };
/// One painted frame: the attachment tiles in the strip, and each node in the text (its element's
/// mark, which a remount loses, its place against the prompt, and its state).
type Frame = { strip: Rect[]; nodes: { mark: string; rect: Rect; state: string }[] };
type ProbeWindow = Window & {
  __frames?: Frame[];
  __stopFrames?: () => void;
  __holdReads?: boolean;
  __releaseReads?: () => void;
  __holdDraft?: boolean;
  __releaseDraft?: () => void;
  __draftReads?: Record<string, { asked: number; answered: number }>;
  __shot?: File;
};

await requireBrowserLane("composer-attachment-loads-in-place.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-attachment-loads-in-place: skipping (run `bunx playwright install chromium`)");
    describe.skip("attachments load in place", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const PROMPT = ".acpmux-composer-prompt [contenteditable='true']";

  /// The mock pane, with two holds the test opens: the page's file reads (a pasted image's bytes and
  /// its decode in the image worker) and the chat's draft read from acpmux.
  async function openPane(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(() => {
      const state = window as ProbeWindow;
      let releaseReads = () => {};
      let reads = new Promise<void>((resolve) => (releaseReads = resolve));
      state.__releaseReads = () => {
        state.__holdReads = false;
        releaseReads();
      };
      const held = () => (state.__holdReads ? reads : Promise.resolve());
      // The file's bytes, not its header: a few bytes read at once give the tile its shape.
      const buffer = Blob.prototype.arrayBuffer;
      Blob.prototype.arrayBuffer = async function (this: Blob) {
        if (this.size > 4096) await held();
        return buffer.call(this);
      };
      const post = Worker.prototype.postMessage as (this: Worker, ...args: unknown[]) => void;
      Worker.prototype.postMessage = function (this: Worker, ...args: unknown[]) {
        if (!state.__holdReads) return post.apply(this, args);
        void held().then(() => post.apply(this, args));
      } as Worker["postMessage"];
      // The chat's draft read (composerDraft.ts readDurableDraftState), held while `__holdDraft`.
      let releaseDraft = () => {};
      const draft = new Promise<void>((resolve) => (releaseDraft = resolve));
      state.__releaseDraft = () => releaseDraft();
      state.__draftReads = {};
      type Actions = Record<string, (params: Record<string, unknown>) => Promise<unknown>> & { __held?: true };
      const wrap = (actions: Actions | undefined) => {
        const read = actions?.["chat.readDraft"];
        if (!actions || !read || actions.__held) return;
        actions.__held = true;
        actions["chat.readDraft"] = async (params) => {
          const id = String(params.sessionId);
          const count = (state.__draftReads![id] ??= { asked: 0, answered: 0 });
          count.asked += 1;
          if (state.__holdDraft) await draft;
          const answer = await read(params);
          count.answered += 1;
          return answer;
        };
      };
      let actions: Actions | undefined;
      Object.defineProperty(window, "cmuxAcpmuxActions", {
        configurable: true,
        get: () => actions,
        set: (next: Actions | undefined) => {
          wrap(next);
          actions =
            next &&
            new Proxy(next, {
              set(target, key, value) {
                (target as Record<string | symbol, unknown>)[key] = value;
                wrap(target);
                return true;
              },
            });
        },
      });
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    await installPaintedFrames(page);
    return page;
  }

  /// Shows chat `id` and waits until its draft read was asked (and, unless held, answered).
  async function select(page: Page, id: string) {
    await page.evaluate((id) => (window as any).cmuxAcpmuxDebug.selectSession(id), id);
    await page.waitForFunction(
      (id) => {
        const state = window as ProbeWindow;
        const count = state.__draftReads?.[id];
        return (
          (window as any).cmuxAcpmuxDebug.chatState().sessionId === id &&
          count !== undefined &&
          (state.__holdDraft ? count.asked > count.answered : count.answered > 0 && count.answered === count.asked)
        );
      },
      id,
      { timeout: 30_000 },
    );
    await page.locator(PROMPT).waitFor();
  }

  /// A screenshot-sized PNG, made in the page before any hold.
  const makeShot = (page: Page) =>
    page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 1440;
      canvas.height = 900;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#1b1c20";
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = "#d6d7db";
      context.fillRect(40, 40, 600, 200);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      (window as ProbeWindow).__shot = new File([blob], "Screenshot.png", { type: "image/png" });
    });

  /// Pastes (as the Edit menu's Paste does, no key in the prompt) or drops the screenshot.
  const attachShot = (page: Page, way: "paste" | "drop") =>
    page.evaluate(
      ({ way, prompt }) => {
        const data = new DataTransfer();
        data.items.add((window as ProbeWindow).__shot!);
        if (way === "paste") {
          const paste = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
          if (paste.clipboardData !== data) Object.defineProperty(paste, "clipboardData", { value: data });
          document.querySelector(prompt)!.dispatchEvent(paste);
          return;
        }
        const target = document.querySelector(".acpmux-composer-box")!;
        const box = target.getBoundingClientRect();
        const init = {
          dataTransfer: data,
          bubbles: true,
          cancelable: true,
          clientX: box.left + 40,
          clientY: box.top + box.height / 2,
        };
        for (const type of ["dragenter", "dragover", "drop"]) {
          const drag = new DragEvent(type, init);
          if (drag.dataTransfer !== data) Object.defineProperty(drag, "dataTransfer", { value: data });
          target.dispatchEvent(drag);
        }
      },
      { way, prompt: PROMPT },
    );

  /// Samples every painted frame from now until `stopFrames`.
  const startFrames = (page: Page) =>
    page.evaluate((prompt) => {
      const state = window as ProbeWindow;
      const frames: Frame[] = [];
      state.__frames = frames;
      let marks = 0;
      const rect = (element: Element, from: DOMRect): Rect => {
        const { x, y, width, height } = element.getBoundingClientRect();
        return { x: x - from.x, y: y - from.y, width, height };
      };
      state.__stopFrames = window.cmuxAfterPaint(() => {
        const box = document.querySelector(".acpmux-composer-box");
        const field = document.querySelector(prompt);
        if (!box || !field) return true;
        const from = field.getBoundingClientRect();
        frames.push({
          strip: [...box.querySelectorAll(".acpmux-attachments .acpmux-attachment")]
            .filter((tile) => tile.getBoundingClientRect().width > 0)
            .map((tile) => rect(tile, box.getBoundingClientRect())),
          nodes: [...field.querySelectorAll<HTMLElement>("[data-inline-attachment]")].map((node) => {
            node.dataset.probeMark ??= String((marks += 1));
            return {
              mark: node.dataset.probeMark,
              rect: rect(node, from),
              state: node.querySelector(".acpmux-md-inline-chip")?.getAttribute("data-state") ?? "empty",
            };
          }),
        });
        return true;
      });
    }, PROMPT);

  const stopFrames = (page: Page) =>
    page.evaluate(() => {
      const state = window as ProbeWindow;
      state.__stopFrames?.();
      return state.__frames!;
    });

  /// The prompt's text, each attachment node as [ATT].
  const promptText = (page: Page) =>
    page.locator(PROMPT).evaluate((field) => {
      const walk = (node: Node): string =>
        node.nodeType === Node.TEXT_NODE
          ? (node.textContent ?? "").replace(/ /g, " ")
          : (node as Element).hasAttribute?.("data-inline-attachment")
            ? "[ATT]"
            : [...node.childNodes].map(walk).join("");
      return walk(field);
    });

  /// The read ends: every tile in the composer is its read picture.
  async function releaseAndSettle(page: Page) {
    await page.evaluate(() => (window as ProbeWindow).__releaseReads!());
    await page.waitForFunction(
      () => {
        const box = document.querySelector(".acpmux-composer-box");
        if (!box || box.querySelector('[aria-busy="true"], .acpmux-attachment-pending')) return false;
        const images = [...box.querySelectorAll<HTMLImageElement>(".acpmux-attachment-image img")];
        return images.length === 1 && images.every((img) => img.complete && img.naturalWidth > 0);
      },
      null,
      { polling: 20, timeout: 30_000 },
    );
    // Two more painted frames, so the last sample is the settled layout.
    await page.evaluate(() => window.cmuxPaintFrame());
    await page.evaluate(() => window.cmuxPaintFrame());
  }

  const near = (a: Rect, b: Rect) =>
    Math.abs(a.x - b.x) <= 1 &&
    Math.abs(a.y - b.y) <= 1 &&
    Math.abs(a.width - b.width) <= 1 &&
    Math.abs(a.height - b.height) <= 1;

  /// Every frame from the gesture on drew the attachment as one node in the text: the same element,
  /// at the same place, loading and then ready, and never a tile in the strip.
  function expectInPlace(frames: Frame[]) {
    // A loading image's tile is held unseen (no width) for the frame its header takes to read.
    const drawn = frames.filter((frame) => frame.strip.length || frame.nodes.some((node) => node.rect.width > 0));
    const trace = drawn
      .map((frame) =>
        [
          ...frame.strip.map((tile) => `strip@${Math.round(tile.x)},${Math.round(tile.y)}`),
          ...frame.nodes.map(
            (node) =>
              `#${node.mark}:${node.state}@${Math.round(node.rect.x)},${Math.round(node.rect.y)} ${Math.round(node.rect.width)}x${Math.round(node.rect.height)}`,
          ),
        ].join(" "),
      )
      .filter((line, index, all) => index === 0 || line !== all[index - 1]);
    console.log(`composer-attachment-loads-in-place: ${trace.join(" | ")}`);
    expect(drawn.length).toBeGreaterThan(0);
    const first = drawn[0]!.nodes[0];
    expect(first?.state).toBe("loading");
    for (const frame of drawn) {
      expect(frame.strip).toEqual([]);
      expect(frame.nodes.length).toBe(1);
      expect(frame.nodes[0]!.mark).toBe(first!.mark);
      expect(near(frame.nodes[0]!.rect, first!.rect)).toBe(true);
    }
    expect(drawn.at(-1)!.nodes[0]!.state).toBe("ready");
  }

  test("a screenshot pasted while the chat's draft is read stays in its node, and the words typed meanwhile stay whole", async () => {
    const page = await openPane();
    // The chat was shown before, so its draft was read before; coming back reads it again.
    await select(page, "mock-session");
    await select(page, "mock-tab-strip");
    await page.evaluate(() => ((window as ProbeWindow).__holdDraft = true));
    await select(page, "mock-session");
    await page.locator(PROMPT).click();
    await makeShot(page);
    await page.evaluate(() => ((window as ProbeWindow).__holdReads = true));
    await startFrames(page);
    await attachShot(page, "paste");
    // The draft read answers while the screenshot still loads, and the person types on.
    await page.evaluate(() => (window as ProbeWindow).__releaseDraft!());
    await page.waitForFunction(() => {
      const count = (window as ProbeWindow).__draftReads!["mock-session"]!;
      return count.answered === count.asked;
    });
    await page.evaluate(() => window.cmuxPaintFrame());
    await page.keyboard.type("hello world", { delay: 20 });
    await releaseAndSettle(page);
    await page.keyboard.type(" end", { delay: 20 });
    await page.evaluate(() => window.cmuxPaintFrame());
    const frames = await stopFrames(page);
    expect(await promptText(page)).toBe("[ATT]hello world end");
    expectInPlace(frames);
    await page.close();
  });

  test("a screenshot dropped between words loads in its node while the person types on", async () => {
    const page = await openPane();
    await select(page, "mock-session");
    await page.locator(PROMPT).click();
    await page.keyboard.type("compare ");
    await makeShot(page);
    await page.evaluate(() => ((window as ProbeWindow).__holdReads = true));
    await startFrames(page);
    await attachShot(page, "drop");
    await page.keyboard.type("with the old one", { delay: 20 });
    await releaseAndSettle(page);
    await page.keyboard.type(" please", { delay: 20 });
    await page.evaluate(() => window.cmuxPaintFrame());
    const frames = await stopFrames(page);
    expect(await promptText(page)).toBe("compare [ATT]with the old one please");
    expectInPlace(frames);
    await page.close();
  });

  test("a screenshot that loads in the strip stays there, never put in at the caret the person moved to", async () => {
    const page = await openPane();
    await select(page, "mock-session");
    // A code block takes no attachment: the paste's placeholder shows in the strip.
    await page.evaluate((prompt) => {
      const field = document
        .querySelector(prompt)!
        .closest<HTMLElement & { acpmuxMarkdownField?: any }>(".acpmux-composer-prompt")!;
      field.acpmuxMarkdownField.type("```\nnpm test\n```\n\nafter");
    }, PROMPT);
    await page.locator(`${PROMPT} pre`).click();
    await makeShot(page);
    await page.evaluate(() => ((window as ProbeWindow).__holdReads = true));
    await startFrames(page);
    await attachShot(page, "paste");
    // The person moves on to the line after the block and types while it loads.
    await page.locator(`${PROMPT} p`).last().click();
    await page.keyboard.press("End");
    await page.keyboard.type(" hello world", { delay: 20 });
    await releaseAndSettle(page);
    await page.keyboard.type(" end", { delay: 20 });
    await page.evaluate(() => window.cmuxPaintFrame());
    const frames = await stopFrames(page);
    expect(await promptText(page)).toBe("npm testafter hello world end");
    const drawn = frames.filter((frame) => frame.nodes.length || frame.strip.length);
    expect(drawn.length).toBeGreaterThan(0);
    for (const frame of drawn) {
      expect(frame.nodes).toEqual([]);
      expect(frame.strip.length).toBe(1);
      expect(frame.strip[0]!.x).toBeCloseTo(drawn[0]!.strip[0]!.x, 0);
      expect(frame.strip[0]!.y).toBeCloseTo(drawn[0]!.strip[0]!.y, 0);
    }
    await page.close();
  });
});
