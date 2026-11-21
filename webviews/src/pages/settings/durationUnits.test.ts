// Durations read in a human unit (Leo 2026-10-30, Check Every read "3600 s": "look for wastage";
// leo-workspace design/settings.md, "Human units"). The stored value keeps the schema's unit: the
// page converts only where it shows and reads the number, so no setting migrates.
import { expect, test } from "bun:test";
import "./testCatalog";
import { displayNumber, parseNumber, shownUnit, unitLabel } from "./format";
import { rowsByKey, type NumberRange } from "./schema";

const range = (key: string): NumberRange => rowsByKey.get(key)!.range!;

test("Check Every reads in hours and stores seconds", () => {
  const every = range("updates.checkIntervalSeconds");
  expect(shownUnit(every)).toEqual({ unit: "hours", factor: 3600 });
  expect(unitLabel(every)).toBe("hr");
  expect(displayNumber(3600, every)).toBe("1");
  expect(displayNumber(900, every)).toBe("0.25");
  expect(displayNumber(604_800, every)).toBe("168");
  expect(parseNumber("1", every)).toBe(3600);
  expect(parseNumber("1.5", every)).toBe(5400);
  expect(parseNumber("24", every)).toBe(86_400);
});

test("a duration in whole minutes reads in minutes", () => {
  const wait = range("updates.idleInstallMaxWaitSeconds");
  expect(unitLabel(wait)).toBe("min");
  expect(displayNumber(600, wait)).toBe("10");
  expect(parseNumber("10", wait)).toBe(600);
});

test("finer durations and other units keep their own unit", () => {
  // Seconds in steps under a minute stay seconds.
  const quiet = range("updates.idleInstallQuietSeconds");
  expect(shownUnit(quiet)).toEqual({ unit: "seconds", factor: 1 });
  expect(displayNumber(60, quiet)).toBe("60");
  expect(parseNumber("60", quiet)).toBe(60);
  // A minutes range with five-minute steps stays minutes.
  const minutes: NumberRange = { min: 5, max: 10_080, step: 5, unit: "minutes", placeholder: 30 };
  expect(shownUnit(minutes)).toEqual({ unit: "minutes", factor: 1 });
  // Counts and fractions are untouched.
  expect(displayNumber(1, range("updates.keepPreviousVersions"))).toBe("1");
  const fraction: NumberRange = { min: 0, max: 1, step: 0.01, unit: "fraction", placeholder: 1 };
  expect(displayNumber(0.6, fraction)).toBe("60");
  expect(parseNumber("60", fraction)).toBe(0.6);
});
