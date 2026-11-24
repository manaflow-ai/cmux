// cmux-web-test-timeout: 240
// A reader opens a finished run while the running turn's live line is held, and the live line stays
// where it was held (review of #41661, LOW 1: "a blank band above Thinking").
//
// While the view follows a running turn, the live line ("Thinking") holds still at the bottom against
// the follow chase: it wears a translate, and the row over it is clipped where the line is drawn
// (pinnedLiveLine.ts). A reader who scrolls up in that motion takes the view, and the line and the
// clip hold where they are drawn until the view follows again. A fold above it (the reader opens a
// finished run) then moved the rows under the run by translate (foldRide.ts), the live line among
// them: the ride wrote over the held translate and took it off at the fold's end. The line went to
// its layout place, the row over it kept the clip made for the held place, and a blank band showed
// between them.
//
// The page is send-stream-motion's (browser/send-stream-motion.harness.tsx, `heldFold`) on the frames'
// own clock, on the blocks follow arm (below), with live-turn-work `runs` as the app ships it (each
// finished run of a running turn is a closed line that a click opens).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { HeldFold, RowSample, Sample } from "./browser/send-stream-motion.harness";
import { FramesUnsupported, open120Hz } from "./support/frames120";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { FRAME_MS } from "./support/rowArrivalReport";
import { LIVE_THINKING } from "../src/agent-session/acpmux/conversation/turns";

await requireBrowserLane("held-live-line-fold-browser.test.ts", async () => {
  const PAGE = "/test/browser/send-stream-motion.html";
  setDefaultTimeout(120_000);
  try {
    await (await open120Hz("about:blank")).close();
  } catch (error) {
    if (!(error instanceof FramesUnsupported) || process.env.GITHUB_ACTIONS === "true") throw error;
    console.warn("held-live-line-fold: skipping, this Chrome draws no frames on the test's clock");
    describe.skip("held live line", () => test("no chrome-headless-shell", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      mode: "production",
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      cacheDir: path.join(webviews, "node_modules/.vite-send-stream-motion"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
  });
  afterAll(async () => {
    await vite?.close();
  });

  const HISTORY = 17;
  const round = (px: number) => Math.round(px * 10) / 10;
  const liveOf = (sample: Sample) => sample.rows?.find((row) => row.id === LIVE_THINKING);
  /// The row drawn just over the live line: the one its held place is clipped out of.
  const overLive = (sample: Sample, live: RowSample) =>
    (sample.rows ?? [])
      .filter((row) => row.id !== live.id && (row.layoutTop ?? 0) < (live.layoutTop ?? 0))
      .sort((a, b) => (b.layoutTop ?? 0) - (a.layoutTop ?? 0))[0];
  /// The blank band between the live line's drawn top and what shows of the row over it, px.
  const band = (sample: Sample): number | undefined => {
    const live = liveOf(sample);
    const over = live ? overLive(sample, live) : undefined;
    return live && over ? live.top - (over.top + over.height - (over.clip ?? 0)) : undefined;
  };

  test("a run opened over a held live line leaves the line where it is held, with no blank band over it", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    // The blocks follow arm: a held live line is its chase's (the reader's input holds the chase where
    // it is drawn). The slim `send` arm, the product's, ends every follow motion where the rows lay
    // out on the reader's input, so nothing is held and no band can open over the line (Leo,
    // 2026-11-09: "when i scroll down now there's a little readjustment sometimes that shold never
    // happen").
    const frames = await open120Hz(
      `http://127.0.0.1:${port}${PAGE}?clock=frames&rows=1&history=${HISTORY}&arm=blocks`,
      {
        clock: "frames",
      },
    );
    let out: HeldFold;
    try {
      await frames.page.waitForFunction(() => "__sendStream" in window);
      await frames.page.getByText(`History answer ${HISTORY - 1}.`).waitFor();
      frames.start();
      out = (await frames.page.evaluate(() =>
        (window as unknown as { __sendStream: { heldFold(): Promise<HeldFold> } }).__sendStream.heldFold(),
      )) as HeldFold;
      await frames.stop();
    } finally {
      await frames.close();
    }
    const samples = out.samples;
    const before = samples.filter((sample) => sample.t < out.clickedAt && liveOf(sample) !== undefined).at(-1);
    const after = samples.filter((sample) => sample.phase === "after");
    const folding = samples.filter((sample) => sample.t >= out.clickedAt && sample.phase === "click");
    const liveBefore = before ? liveOf(before) : undefined;
    const bandBefore = before ? band(before) : undefined;
    const bands = after.map(band).filter((each): each is number => each !== undefined);
    const worst = bands.length ? Math.max(...bands) : undefined;
    const offsets = (list: Sample[]) => list.map((sample) => liveOf(sample)?.offset ?? 0);
    console.log(
      `held-live-line-fold: wheel ${out.px} px; view ${round(out.view.top)} to ${round(out.view.bottom)}, composer ${round(out.view.composer)}; ` +
        `line "${out.line?.text ?? "none"}" ${round(out.line?.top ?? 0)} to ${round(out.line?.bottom ?? 0)}, opened ${out.line?.opened}; ` +
        `live line before the click: top ${round(liveBefore?.top ?? 0)}, height ${round(liveBefore?.height ?? 0)}, held ${round(liveBefore?.offset ?? 0)} px; ` +
        `during the fold its translate ${round(Math.min(...offsets(folding), 0))} to ${round(Math.max(...offsets(folding), 0))} px; ` +
        `after: ${round(Math.min(...offsets(after), 0))} to ${round(Math.max(...offsets(after), 0))} px; ` +
        `band before ${round(bandBefore ?? Number.NaN)} px, after ${round(worst ?? Number.NaN)} px (${bands.length} frames)`,
    );
    console.log(`held-live-line-fold rows at the click:\n  ${out.rows.join("\n  ")}`);
    // Where the view was when the wheel came: how far from its end, and how far the chase drew the thread.
    const atWheel = samples.filter((sample) => sample.t < out.wheeledAt).at(-1);
    console.log(
      `held-live-line-fold before the wheel: ${round(atWheel?.fromEnd ?? Number.NaN)} px from the end, ` +
        `thread drawn ${round(atWheel?.lag ?? Number.NaN)} px from its layout, step ${atWheel?.phase}`,
    );

    // The scene is the one the words above say.
    // The wheel came while the follow chase was in flight: the thread was drawn away from its layout.
    const wheeled = samples.filter((sample) => sample.t >= out.wheeledAt && sample.t < out.wheeledAt + 4 * FRAME_MS);
    expect(Math.max(...wheeled.map((sample) => Math.abs(sample.lag)))).toBeGreaterThan(1);
    // The live line is held: drawn over its layout place, and the row over it is clipped to meet it.
    expect(liveBefore).toBeDefined();
    expect(liveBefore!.offset ?? 0).toBeLessThan(-1);
    // The band before the click is the measure's rest value (the gap between two rows' boxes).
    expect(bandBefore).toBeDefined();
    // Its foot is under the view's end where the transcript placed it, so the end is not in view.
    expect(liveBefore!.top + liveBefore!.height - (liveBefore!.offset ?? 0)).toBeGreaterThanOrEqual(
      before!.viewBottom!,
    );
    // The reader can click the run's line: it is closed, in the view and over the composer.
    expect(out.line).toBeDefined();
    expect(out.line!.top).toBeGreaterThanOrEqual(out.view.top);
    expect(out.line!.bottom).toBeLessThanOrEqual(out.view.composer);
    // The click opened the run: its row grew.
    expect(out.line!.opened).toBe(true);
    const clicked = before!.rows!.find(
      (row) => row.top <= out.line!.top + 1 && row.top + row.height >= out.line!.bottom - 1,
    );
    expect(clicked).toBeDefined();
    const grown = after.at(-1)?.rows?.find((row) => row.id === clicked!.id);
    expect(grown).toBeDefined();
    expect(grown!.height - clicked!.height).toBeGreaterThan(20);

    // After the fold, with the view still the reader's and the turn still running: the live line is
    // drawn, and what shows of the row over it still meets it.
    expect(after.length).toBeGreaterThan(10);
    expect(bands.length).toBe(after.length);
    expect(round(worst! - bandBefore!)).toBeLessThanOrEqual(0.5);
  });
});
