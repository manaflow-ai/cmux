// Labs (hq#1980): a page reads a flag the app turned on from `data-labs` on `<html>` (names,
// space separated); a flag the app did not list, or a page with no `data-labs`, is off.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { LABS_FLAGS, labsFlag } from "./labs";

test("a flag is on only when the app lists it in data-labs", () => {
  const root = new JSDOM("<!doctype html><html></html>").window.document.documentElement;
  expect(labsFlag("previewFeatures", root)).toBe(false);
  root.setAttribute("data-labs", "previewFeatures");
  expect(labsFlag("previewFeatures", root)).toBe(true);
  root.setAttribute("data-labs", "");
  expect(labsFlag("previewFeatures", root)).toBe(false);
});

test("every flag in the registry carries its owner, dates, cohort and intent", () => {
  for (const [name, flag] of Object.entries(LABS_FLAGS)) {
    expect(flag.owner.length, name).toBeGreaterThan(0);
    expect(flag.intent.length, name).toBeGreaterThan(0);
    expect(flag.created < flag.expires, name).toBe(true);
    expect(["off", "nightly-next", "default"]).toContain(flag.cohort);
  }
});
