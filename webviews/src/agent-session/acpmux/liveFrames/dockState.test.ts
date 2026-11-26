import { expect, test } from "bun:test";
import {
  dockReducer,
  framesPaneKey,
  initialDock,
  loadDock,
  MIN_HEIGHT,
  MIN_WIDTH,
  parseDock,
  saveDock,
  shownSize,
} from "./dockState";

const pane = { width: 800, height: 600 };
const base = { x: 100, y: 100, width: 300, height: 200, mode: "open" as const };

test("move stays inside the pane", () => {
  expect(dockReducer(base, { type: "move", dx: 50, dy: -20, pane })).toMatchObject({ x: 150, y: 80 });
  expect(dockReducer(base, { type: "move", dx: -999, dy: -999, pane })).toMatchObject({ x: 0, y: 0 });
  expect(dockReducer(base, { type: "move", dx: 9999, dy: 9999, pane })).toMatchObject({ x: 500, y: 400 });
});

test("resize clamps to the minimum and the pane edge", () => {
  expect(dockReducer(base, { type: "resize", dw: -999, dh: -999, pane })).toMatchObject({
    width: MIN_WIDTH,
    height: MIN_HEIGHT,
  });
  expect(dockReducer(base, { type: "resize", dw: 9999, dh: 9999, pane })).toMatchObject({ width: 700, height: 500 });
});

test("mode changes keep the box, a pill is drawn small", () => {
  const pill = dockReducer(base, { type: "mode", mode: "pill" });
  expect(pill.width).toBe(300);
  expect(shownSize(pill).width).toBeLessThan(300);
  expect(dockReducer(pill, { type: "mode", mode: "open" })).toEqual(base);
  expect(dockReducer(base, { type: "mode", mode: "hidden" }).mode).toBe("hidden");
});

test("fit pulls the window back into a smaller pane", () => {
  const fitted = dockReducer({ ...base, x: 500, y: 400 }, { type: "fit", pane: { width: 400, height: 300 } });
  expect(fitted.x + fitted.width).toBeLessThanOrEqual(400);
  expect(fitted.y + fitted.height).toBeLessThanOrEqual(300);
});

test("initialDock fits the pane", () => {
  const dock = initialDock(pane);
  expect(dock.x + dock.width).toBeLessThanOrEqual(pane.width);
  expect(dock.y + dock.height).toBeLessThanOrEqual(pane.height);
});

test("parse, save and load round-trip per pane, and refuse junk", () => {
  const store = new Map<string, string>();
  const storage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
  };
  saveDock("a", base, storage);
  expect(loadDock("a", storage)).toEqual(base);
  expect(loadDock("b", storage)).toBeUndefined();
  expect(parseDock("{")).toBeUndefined();
  expect(parseDock(JSON.stringify({ ...base, mode: "weird" }))).toBeUndefined();
  expect(parseDock(JSON.stringify({ ...base, x: "1" }))).toBeUndefined();
  expect(parseDock(null)).toBeUndefined();
});

test("framesPaneKey prefers the host's pane id, then the chat", () => {
  expect(framesPaneKey("chat", "?pane=p1")).toBe("p1");
  expect(framesPaneKey("chat", "")).toBe("chat");
  expect(framesPaneKey(undefined, "")).toBe("default");
});
