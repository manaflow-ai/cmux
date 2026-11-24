// The frame classification of bench/surface-loading.bench.ts (bench/surfaceLoadingFrames.ts): a surface's time to
// content is when its settled content first painted, and one still blank or loading at the window's end is held (Leo,
// 2026-11-10: "Anything fucking slow, anything fucking bullshit, anything with a stupid ass fucking loading state.").
import { describe, expect, test } from "bun:test";
import { classifySurface, LOADING_TEXT, median, type SurfaceFrame } from "../bench/surfaceLoadingFrames";

const blank = (t: number): SurfaceFrame => ({ t, state: "blank" });
const loading = (t: number, loader = "div.spinner"): SurfaceFrame => ({ t, state: "loading", loaders: [loader] });
const content = (t: number): SurfaceFrame => ({ t, state: "content" });

describe("surface loading frames", () => {
  test("content on the first frame settles there, with no loading or blank time", () => {
    const metrics = classifySurface([content(40), content(56), content(72)], 2000);
    expect(metrics.timeToContentMs).toBe(40);
    expect(metrics.firstContentMs).toBe(40);
    expect(metrics.loadingMs).toBe(0);
    expect(metrics.blankMs).toBe(0);
    expect(metrics.held).toBe(false);
  });

  test("a blank pane, then a spinner, then content counts each and settles at the content", () => {
    const metrics = classifySurface([blank(16), blank(32), loading(48), loading(300), content(900)], 2000);
    expect(metrics.timeToContentMs).toBe(900);
    expect(metrics.blankMs).toBe(32);
    expect(metrics.loadingMs).toBe(852);
    expect(metrics.longestLoadingMs).toBe(852);
    expect(metrics.loaders).toEqual([{ name: "div.spinner", frames: 2 }]);
  });

  test("content that goes back to a spinner settles only at its last return", () => {
    const metrics = classifySurface([content(30), loading(100, "div.apps-skeleton"), content(700), content(800)], 2000);
    expect(metrics.firstContentMs).toBe(30);
    expect(metrics.timeToContentMs).toBe(700);
    expect(metrics.held).toBe(false);
  });

  test("a spinner still up at the window's end is held, its run counted to the end", () => {
    const metrics = classifySurface([blank(16), loading(40), loading(1000)], 4000);
    expect(metrics.held).toBe(true);
    expect(metrics.timeToContentMs).toBeNull();
    expect(metrics.longestLoadingMs).toBe(3960);
    expect(metrics.loadingMs).toBe(3960);
  });

  test("a row's small status spinner beside content settles, and is named apart from loaders", () => {
    const row = (t: number): SurfaceFrame => ({ t, state: "content", status: ["svg.machines-spinner"] });
    const metrics = classifySurface([blank(16), row(60), row(76)], 2000);
    expect(metrics.timeToContentMs).toBe(60);
    expect(metrics.held).toBe(false);
    expect(metrics.loaders).toEqual([]);
    expect(metrics.status).toEqual([{ name: "svg.machines-spinner", frames: 2 }]);
  });

  test("no frame at all is held", () => {
    const metrics = classifySurface([], 4000);
    expect(metrics.held).toBe(true);
    expect(metrics.frames).toBe(0);
  });

  test("frames out of order are read in time order", () => {
    expect(classifySurface([content(500), loading(20)], 1000).timeToContentMs).toBe(500);
  });

  test("a line that only says it loads is a loading line; one that says more is not", () => {
    const pattern = new RegExp(LOADING_TEXT.source, "i");
    expect(pattern.test("Loading…")).toBe(true);
    expect(pattern.test("Loading machines...")).toBe(true);
    expect(pattern.test("Connecting")).toBe(true);
    expect(pattern.test("Loading took 3 s on the last run because the daemon restarted")).toBe(false);
    expect(pattern.test("Downloading")).toBe(false);
  });

  test("median of odd and even counts", () => {
    expect(median([3, 1, 2])).toBe(2);
    expect(median([4, 1, 3, 2])).toBe(2.5);
    expect(median([])).toBeNull();
  });
});
