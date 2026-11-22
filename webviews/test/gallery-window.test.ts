// Window mode computes the surface's real pane size from the app's metrics; it draws nothing of
// the native window. These sizes are what the shell scales and the matrix renders.
import { expect, test } from "bun:test";
import { readChromeMetrics } from "../dev-server/galleryHost";
import { entryPaneSize, fitScale, windowSize } from "../src/gallery/window";

const metrics = readChromeMetrics();

test("the pane sizes follow the window, the layout and the density", () => {
  // 1920 - sidebar 240 - 2 gaps of 8; 1080 - 2 gaps - the tab strip 36.
  expect(entryPaneSize("16x9", "one", "comfortable", metrics)).toEqual({ width: 1664, height: 1028 });
  const two = entryPaneSize("16x9", "two", "comfortable", metrics);
  expect(two.width).toBe(Math.floor((1664 - 8) / 2));
  const right = entryPaneSize("16x9", "agent-right", "comfortable", metrics);
  expect(right.width).toBe(Math.round(1664 * 0.4));
  // Compact: a narrower sidebar and a shorter strip leave a bigger pane.
  expect(entryPaneSize("16x9", "one", "compact", metrics).width).toBeGreaterThan(1664);
});

test("window sizes: presets, custom sizes, and 16:9 for anything else", () => {
  expect(windowSize("air13")).toMatchObject({ width: 1470, height: 956 });
  expect(windowSize("1440x900")).toEqual({ width: 1440, height: 900 });
  expect(windowSize("huge").width).toBe(1920);
});

test("fit keeps the aspect ratio and never scales up", () => {
  expect(fitScale({ width: 1664, height: 1028 }, { width: 832, height: 2000 })).toBe(0.5);
  expect(fitScale({ width: 400, height: 300 }, { width: 2000, height: 2000 })).toBe(1);
});
