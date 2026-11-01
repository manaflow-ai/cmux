import { expect, test } from "bun:test";
import { olderRowFadesOnMount } from "./olderRowFade";

const view = { top: 100, bottom: 800 };

test("an older row that mounts above the view draws at once, with no fade", () => {
  expect(olderRowFadesOnMount({ top: -400, bottom: 100 }, view)).toBe(false);
  expect(olderRowFadesOnMount({ top: -2000, bottom: -1600 }, view)).toBe(false);
});

test("an older row that mounts below the view draws at once, with no fade", () => {
  expect(olderRowFadesOnMount({ top: 800, bottom: 900 }, view)).toBe(false);
});

test("an older row that mounts inside the view (the reader got there first) fades", () => {
  expect(olderRowFadesOnMount({ top: 101 - 80, bottom: 101 }, view)).toBe(true);
  expect(olderRowFadesOnMount({ top: 300, bottom: 400 }, view)).toBe(true);
  expect(olderRowFadesOnMount({ top: 0, bottom: 1000 }, view)).toBe(true);
});
