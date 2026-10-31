// The fixed-wait ratchet (scripts/check-fixed-waits.ts): which waits it names, and the marker that
// lets one stay.
import { expect, test } from "bun:test";
import path from "node:path";
import { compareToBaseline, findFixedWaits } from "../scripts/check-fixed-waits";

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

test("a local sleep helper counts at its wait and at each call", () => {
  const source = [
    "const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));",
    "function later(ms: number) {",
    "  return new Promise<void>((resolve) => setTimeout(resolve, ms));",
    "}",
    "await wait(200);",
    "await later(50);",
  ].join("\n");
  expect(lines(findFixedWaits(file, source))).toEqual([1, 3, 5, 6]);
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

test("a helper with no delay parameter counts at each call, and helpers built on helpers too", () => {
  const source = [
    "const settle = () => new Promise((resolve) => setTimeout(resolve, 50));",
    "const twice = async () => {",
    "  await settle();",
    "  await settle();",
    "};",
    "await settle();",
    "await twice();",
    "await twice();",
  ].join("\n");
  expect(lines(findFixedWaits(file, source))).toEqual([1, 3, 4, 6, 7, 8]);
});

test("a helper whose delay defaults to 0 waits only when a call passes a delay", () => {
  const source = [
    "async function settle(ms = 0) {",
    "  await new Promise((resolve) => setTimeout(resolve, ms));",
    "}",
    "await settle();",
    "await settle(0);",
    "await settle(80);",
  ].join("\n");
  expect(lines(findFixedWaits(file, source))).toEqual([6]);
});

test("a timer callback with a block body, and window.setTimeout, are fixed waits", () => {
  const source = [
    "await new Promise((resolve) =>",
    "  setTimeout(() => {",
    "    seen.push(1);",
    "    resolve(undefined);",
    "  }, 600),",
    ");",
    "await new Promise((resolve) => window.setTimeout(resolve, 40));",
  ].join("\n");
  expect(lines(findFixedWaits(file, source))).toEqual([2, 7]);
});

test("an exported helper counts at its wait, since its callers are elsewhere", () => {
  const source = "export const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));";
  expect(lines(findFixedWaits(file, source))).toEqual([1]);
});

test("a marker covers its whole statement, and a helper's marker covers its calls", () => {
  const source = [
    "// fixed-wait: the card's 250 ms delay is the behavior; measured against it below",
    "await new Promise((resolve) =>",
    "  setTimeout(resolve, 250),",
    ");",
    "await page.waitForTimeout(",
    "  100, // fixed-wait: nothing fires when the list stays put",
    ");",
    "await step(); // fixed-wait: this marker is for step() only",
    "await page.waitForTimeout(20);",
    "const nap = () => new Promise((resolve) => setTimeout(resolve, 30)); // fixed-wait: a 30 ms debounce under test",
    "await nap();",
  ].join("\n");
  expect(lines(findFixedWaits(file, source))).toEqual([9]);
});

test("TSX sources parse", () => {
  const source = "const view = <div />;\nawait page.waitForTimeout(10);";
  expect(lines(findFixedWaits(path.resolve(import.meta.dir, "a.test.tsx"), source))).toEqual([2]);
});

test("a helper passed or returned as a value counts where it is passed", () => {
  const source = [
    "const settle = () => new Promise((resolve) => setTimeout(resolve, 80));",
    "await act(settle);",
    "export function chat() {",
    "  const open = async () => {",
    "    await page.waitForTimeout(500);",
    "  };",
    "  return { open };",
    "}",
  ].join("\n");
  expect(lines(findFixedWaits(file, source))).toEqual([1, 2, 5, 7]);
});

test("a new wait or helper call inside an existing helper raises the count", () => {
  const helper = [
    "const settle = () => new Promise((resolve) => setTimeout(resolve, 50));",
    "async function connect() {",
    "  await settle();",
    "}",
    "await connect();",
  ];
  const before = findFixedWaits(file, helper.join("\n")).length;
  const withWait = [...helper.slice(0, 3), "  await page.waitForTimeout(2000);", ...helper.slice(3)];
  const withCall = [...helper.slice(0, 3), "  await settle();", ...helper.slice(3)];
  expect(findFixedWaits(file, withWait.join("\n")).length).toBe(before + 1);
  expect(findFixedWaits(file, withCall.join("\n")).length).toBe(before + 1);
});

test("an export list, a typeof and a recursive call are not uses", () => {
  const source = [
    "const settle = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 50));",
    "type Settle = typeof settle;",
    "export { settle as nap };",
    "async function poll(): Promise<void> {",
    "  await page.waitForTimeout(10);",
    "  return poll();",
    "}",
  ].join("\n");
  expect(lines(findFixedWaits(file, source))).toEqual([1, 5]);
});

test("a baseline row for a deleted file passes, and a file still there below its row fails", () => {
  // #23339 deleted a test that still had a row; every PR then failed the check.
  const found = new Map([["test/kept.test.ts", ["test/kept.test.ts:4"]]]);
  const baseline = new Map([
    ["test/deleted.test.ts", 6],
    ["test/kept.test.ts", 1],
    ["test/cleaned.test.ts", 2],
  ]);
  const { grew, shrank } = compareToBaseline(found, baseline, (file) => file !== "test/deleted.test.ts");
  expect(grew).toEqual([]);
  expect(shrank).toEqual(["  test/cleaned.test.ts: 0 fixed waits, baseline 2"]);
});
