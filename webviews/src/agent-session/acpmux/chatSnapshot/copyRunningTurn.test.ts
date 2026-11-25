// A copy showing a running turn's live line holds until acpmux's attach (App.tsx `chatRead` over
// the copy): a kept tail cannot draw that line, and taking over with it shifted the bottom row
// twice in each restart while a turn ran (bench/settled-page.bench.ts restart.stream).
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { copyShowsRunningTurn } from "./live";
import { SNAPSHOT_HOST_TAG, SNAPSHOT_SHOWN_GLOBAL } from "./shared";

const globals = globalThis as unknown as Record<string, unknown>;
const had = { window: "window" in globals, document: "document" in globals };
const saved = { window: globals.window, document: globals.document };
afterEach(() => {
  for (const key of ["window", "document"] as const) {
    if (had[key]) globals[key] = saved[key];
    else delete globals[key];
  }
});

function copyWith(rowIds: string[]): void {
  const win = new JSDOM('<!doctype html><body><div id="root"></div></body>').window;
  Object.assign(globals, { window: win, document: win.document });
  (win as unknown as Record<string, unknown>)[SNAPSHOT_SHOWN_GLOBAL] = { at: 1 };
  const host = win.document.createElement(SNAPSHOT_HOST_TAG);
  const shadow = host.attachShadow({ mode: "open" });
  for (const id of rowIds) {
    const row = win.document.createElement("div");
    row.className = "acpmux-row";
    row.dataset.rowId = id;
    shadow.append(row);
  }
  win.document.body.append(host);
}

test("a copy whose last row is the running turn's live line says so", () => {
  copyWith(["user-1", "activity-2", "thinking-live"]);
  expect(copyShowsRunningTurn()).toBe(true);
});

test("a copy of an ended turn does not hold the takeover", () => {
  copyWith(["user-1", "assistant-2"]);
  expect(copyShowsRunningTurn()).toBe(false);
});

test("with the copy gone nothing holds", () => {
  copyWith(["thinking-live"]);
  document.querySelector(SNAPSHOT_HOST_TAG)!.remove();
  expect(copyShowsRunningTurn()).toBe(false);
});
