// Experiments (src/experiments/experiment.ts) and the compare view's URL state (src/gallery/compare.ts).
import { afterEach, describe, expect, test } from "bun:test";
import { defineExperiment, experimentArm, validateExperiments } from "../src/experiments/experiment";
import { EXPERIMENTS } from "../src/experiments/registry";
import {
  compareSummary,
  DEFAULT_COMPARE,
  frameStats,
  readCompare,
  visibleArms,
  writeCompare,
} from "../src/gallery/compare";
import { validateEntries, componentEntry, type GalleryExperiment } from "../src/gallery/format";

const sample = defineExperiment({
  id: "sample-motion",
  title: "Sample",
  description: "Two ways to do one thing.",
  arms: { a: { label: "A", description: "First." }, b: { label: "B", description: "Second." } },
  defaultArm: "a",
});

const gallerySample: GalleryExperiment = {
  definition: sample,
  script: [
    { name: "open", run: async () => {} },
    { name: "close", run: async () => {} },
  ],
};

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});

describe("experimentArm", () => {
  test("the default arm when nothing overrides it", () => {
    expect(experimentArm(sample, { stored: {} })).toBe("a");
  });
  test("the host override wins over the debug key, which wins over the default", () => {
    expect(experimentArm(sample, { overrides: { "sample-motion": "b" }, stored: { "sample-motion": "a" } })).toBe("b");
    expect(experimentArm(sample, { overrides: {}, stored: { "sample-motion": "b" } })).toBe("b");
    globalThis.cmuxExperiments = { "sample-motion": "b" };
    expect(experimentArm(sample, { stored: {} })).toBe("b");
  });
  test("an unknown arm falls through to the next source", () => {
    expect(experimentArm(sample, { overrides: { "sample-motion": "z" }, stored: { "sample-motion": "b" } })).toBe("b");
    expect(experimentArm(sample, { overrides: { "sample-motion": "z" }, stored: { "sample-motion": "y" } })).toBe("a");
  });
});

describe("validateExperiments", () => {
  test("every registered experiment is valid", () => {
    expect(validateExperiments(EXPERIMENTS)).toEqual([]);
  });
  test("bad ids, one arm, a missing default and duplicates are reported", () => {
    const bad = { ...sample, id: "Bad_Id", arms: { a: sample.arms.a }, defaultArm: "q" as never };
    expect(validateExperiments([bad, sample, sample])).toEqual([
      "Bad_Id: the id must be lower kebab case",
      "Bad_Id: an experiment needs at least two arms",
      "Bad_Id: the default arm q is not an arm",
      "sample-motion: duplicate id",
    ]);
  });
  test("gallery entries check their experiment, script and measurements", () => {
    const entry = componentEntry({
      id: "ui.sample",
      title: "Sample",
      area: "Pages",
      covers: ["x"],
      load: async () => () => null,
      experiment: {
        ...gallerySample,
        script: [],
        measurements: { z: { run: "r", engine: "chromium", frames: 1, p50: 1, p95: 1, max: 1, over16: 0 } },
      },
      variants: { one: { props: {} } },
    });
    expect(validateEntries([entry])).toEqual([
      "ui.sample: the experiment script has no steps",
      "ui.sample: a measurement names no arm z",
    ]);
  });
});

describe("compare URL state", () => {
  test("defaults write nothing and read back", () => {
    expect(writeCompare(DEFAULT_COMPARE).toString()).toBe("");
    expect(readCompare(new URLSearchParams())).toEqual(DEFAULT_COMPARE);
  });
  test("every key round-trips", () => {
    const state = { arms: ["a", "c"], grid: "3" as const, speed: 0.25, loop: true, focus: "c", pick: "c", step: 2 };
    const params = writeCompare(state);
    expect(params.toString()).toBe("arms=a%2Cc&grid=3&speed=0.25&loop=1&focus=c&pick=c&step=2");
    expect(readCompare(params)).toEqual(state);
  });
  test("invalid values keep their defaults", () => {
    const state = readCompare(new URLSearchParams("arms=A,b,b,../x&grid=9&speed=3&loop=yes&pick=<x>&step=-1"));
    expect(state).toEqual({ ...DEFAULT_COMPARE, arms: ["b"] });
  });
  test("visible arms are the named arms that exist, else all", () => {
    expect(visibleArms(sample, { ...DEFAULT_COMPARE, arms: ["b", "z"] })).toEqual(["b"]);
    expect(visibleArms(sample, { ...DEFAULT_COMPARE, arms: ["z"] })).toEqual(["a", "b"]);
  });
  test("the summary names the experiment, the arms, the speed, the step and the pick", () => {
    expect(
      compareSummary(
        "ui.sample",
        "one",
        gallerySample,
        { ...DEFAULT_COMPARE, speed: 0.5, step: 1, pick: "b" },
        {
          theme: "Nord",
        },
      ),
    ).toBe(
      "experiment sample-motion, entry ui.sample/one, arms a,b, speed 0.5x, step 1 of 2 (open), theme Nord, picked b",
    );
    expect(compareSummary("ui.sample", "one", gallerySample, DEFAULT_COMPARE)).toBe(
      "experiment sample-motion, entry ui.sample/one, arms a,b, speed 1x, step 0 (start), no pick",
    );
  });
  test("frame stats", () => {
    expect(frameStats([])).toEqual({ frames: 0, p50: 0, p95: 0, max: 0, over16: 0 });
    const stats = frameStats([16.6, 16.7, 16.8, 33.4, 8.3]);
    expect(stats).toEqual({ frames: 5, p50: 16.7, p95: 33.4, max: 33.4, over16: 2 });
  });
});
