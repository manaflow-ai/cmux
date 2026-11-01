import { expect, test } from "bun:test";
import { invalidEngineSelection, launchSelectedEngines, shouldFailRun } from "../scripts/latency/engine-selection";

test("records complete coverage when every selected engine launches", async () => {
  const selection = await launchSelectedEngines(["chromium", "webkit"], async (engine) => `${engine}-browser`);
  expect(selection.coverage).toEqual({
    expectedEngines: ["chromium", "webkit"],
    measuredEngines: ["chromium", "webkit"],
    expectedCount: 2,
    measuredCount: 2,
    complete: true,
  });
  expect(selection.failures).toEqual([]);
});

test("keeps a structured failure and partial coverage when one engine fails", async () => {
  const selection = await launchSelectedEngines(["chromium", "webkit"], async (engine) => {
    if (engine === "webkit") throw new Error("shared library missing");
    return "chromium-browser";
  });
  expect(selection.coverage.measuredEngines).toEqual(["chromium"]);
  expect(selection.coverage.complete).toBe(false);
  expect(selection.failures).toEqual([{ engine: "webkit", error: "shared library missing", stage: "launch" }]);
});

test("reports both launch failures without pretending that zero engines were selected", async () => {
  const selection = await launchSelectedEngines(["chromium", "webkit"], async (engine) => {
    throw `${engine} crashed`;
  });
  expect(selection.coverage).toMatchObject({
    expectedEngines: ["chromium", "webkit"],
    measuredEngines: [],
    expectedCount: 2,
    measuredCount: 0,
    complete: false,
  });
  expect(selection.failures.map(({ engine, stage }) => ({ engine, stage }))).toEqual([
    { engine: "chromium", stage: "launch" },
    { engine: "webkit", stage: "launch" },
  ]);
});

test("explicit engine selection measures only the requested engine", async () => {
  const selection = await launchSelectedEngines(["chromium"], async (engine) => engine);
  expect(selection.coverage).toEqual({
    expectedEngines: ["chromium"],
    measuredEngines: ["chromium"],
    expectedCount: 1,
    measuredCount: 1,
    complete: true,
  });
});

test("invalid engine selection is incomplete and carries a selection error", () => {
  const selection = invalidEngineSelection("firefox", "engine must be chromium or webkit");
  expect(selection.coverage.complete).toBe(false);
  expect(selection.coverage.expectedCount).toBe(1);
  expect(selection.failures).toEqual([
    { engine: "firefox", error: "engine must be chromium or webkit", stage: "selection" },
  ]);
});

test("ordinary runs fail on a partial engine sweep while CI remains nonblocking", () => {
  expect(shouldFailRun(0, 1, false)).toBe(true);
  expect(shouldFailRun(0, 1, true)).toBe(false);
  expect(shouldFailRun(1, 0, false)).toBe(true);
});
