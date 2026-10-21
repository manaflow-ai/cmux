// The fixed-wait ratchet (scripts/check-fixed-waits.ts): which waits it names, and the marker that
// lets one stay.
import { expect, test } from "bun:test";
import path from "node:path";
import { findFixedWaits } from "../scripts/check-fixed-waits";

const file = path.resolve(import.meta.dir, "a.test.ts");
const lines = (found: string[]) => found.map((at) => Number(at.split(":").at(-1)));

test("waitForTimeout, Bun.sleep and a setTimeout that resolves a promise later are fixed waits", () => {
  const source = [
    "await page.waitForTimeout(300);",
    "await Bun.sleep(50);",
    "await new Promise((resolve) => setTimeout(resolve, 120));",
    "await new Promise((done) => setTimeout(() => done(undefined), 1_000));",
  ].join("\n");
  expect(lines(findFixedWaits(file, source))).toEqual([1, 2, 3, 4]);
});

test("a zero-delay yield, a condition wait and an unrelated timer are not", () => {
  const source = [
    "await new Promise((resolve) => setTimeout(resolve, 0));",
    "await page.waitForFunction(() => document.querySelector('.card') !== null);",
    "setTimeout(sample, 16);",
    "const id = setTimeout(() => controller.abort(), 5000);",
  ].join("\n");
  expect(findFixedWaits(file, source)).toEqual([]);
});

test("a local sleep helper is named at each call, not at its definition", () => {
  const source = [
    "const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));",
    "function later(ms: number) {",
    "  return new Promise<void>((resolve) => setTimeout(resolve, ms));",
    "}",
    "await wait(200);",
    "await later(50);",
  ].join("\n");
  expect(lines(findFixedWaits(file, source))).toEqual([5, 6]);
});

test("a fixed-wait comment with a reason, on the line or the line above, lets one stay", () => {
  const source = [
    "// fixed-wait: the debounce under test is 300 ms of wall time in the real browser",
    "await page.waitForTimeout(300);",
    "await page.waitForTimeout(100); // fixed-wait: no event fires when nothing changes",
    "// fixed-wait:",
    "await page.waitForTimeout(100);",
  ].join("\n");
  expect(lines(findFixedWaits(file, source))).toEqual([5]);
});

test("TSX sources parse", () => {
  const source = "const view = <div />;\nawait page.waitForTimeout(10);";
  expect(lines(findFixedWaits(path.resolve(import.meta.dir, "a.test.tsx"), source))).toEqual([2]);
});
