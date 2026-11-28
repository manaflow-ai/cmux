// Mission control mounts the same tiles for 200 sessions as for 20 in the same viewport (wow-20
// idea 8's measure: open cost must not grow with the session count).
import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { FIXTURE_STRINGS, fixtureTiles } from "./fixtures";
import { MissionControl } from "./MissionControl";
import { countByState, gridLayout, visibleRange } from "./model";

const VIEWPORT = { width: 1200, height: 800 };

function mountedTiles(count: number, top = 0): number {
  const html = renderToStaticMarkup(
    <MissionControl tiles={fixtureTiles(count)} strings={FIXTURE_STRINGS} initialViewport={{ ...VIEWPORT, top }} />,
  );
  return html.match(/data-tile="/g)?.length ?? 0;
}

describe("mission control grid", () => {
  test("layout fits columns to the width", () => {
    const layout = gridLayout(10, 1200);
    expect(layout.columns).toBe(4);
    expect(layout.tileWidth * 4 + 16 * 3).toBeCloseTo(1200);
    expect(layout.height).toBe(Math.ceil(10 / 4) * layout.stride - 16);
  });

  test("the visible range is the viewport's rows plus one viewport each side", () => {
    const layout = gridLayout(1000, 1200);
    const range = visibleRange(1000, layout, { top: 4000, height: 800 });
    expect(range.start % layout.columns).toBe(0);
    expect(range.start * 0 + Math.floor(range.start / layout.columns) * layout.stride).toBeLessThanOrEqual(3200);
    expect(Math.ceil(range.end / layout.columns) * layout.stride).toBeGreaterThanOrEqual(5600);
    expect(visibleRange(1000, layout, { top: 0, height: 0 })).toEqual({ start: 0, end: 0 });
  });

  test("200 sessions mount as many tiles as the viewport holds, not 200", () => {
    const twenty = mountedTiles(20);
    const twoHundred = mountedTiles(200);
    expect(twenty).toBe(20);
    expect(twoHundred).toBeLessThan(40);
    // Past what fits, more sessions mount nothing more.
    expect(mountedTiles(2000)).toBe(twoHundred);
    expect(mountedTiles(2000, 20_000)).toBeLessThanOrEqual(twoHundred + gridLayout(1, 1200).columns * 2);
  });

  test("an unmeasured scroller mounts nothing", () => {
    const html = renderToStaticMarkup(<MissionControl tiles={fixtureTiles(50)} strings={FIXTURE_STRINGS} />);
    expect(html.match(/data-tile="/g)).toBeNull();
  });

  test("the header counts each state", () => {
    expect(countByState(fixtureTiles(10))).toEqual({ working: 6, waiting: 2, done: 2 });
  });
});
