import { afterEach, describe, expect, test } from "bun:test";
import { experimentArm } from "../../experiments/experiment";
import {
  chatDisplay,
  chatDisplayValues,
  chatDisplayVariables,
  chatMetrics,
  resolveChatDisplay,
  setChatDisplay,
} from "./chatDisplay";
import { readingLook, readingLookValues } from "./readingLook.experiment";

describe("reading layout experiment", () => {
  const previousOverrides = globalThis.cmuxExperiments;
  afterEach(() => {
    globalThis.cmuxExperiments = previousOverrides;
    setChatDisplay({});
  });
  const saved = Object.freeze({
    "agentPane.display.width": 960,
    "agentPane.display.fullWidth": true,
    "agentPane.display.font.size": 18,
    "agentPane.display.font.preset": "serif",
    "agentPane.display.code.family": "Menlo",
  });

  test("unset and stale experiment arms leave saved settings untouched", () => {
    for (const overrides of [{}, { [readingLook.id]: "retired-arm" }]) {
      const arm = experimentArm(readingLook, { overrides, stored: {} });
      expect(arm).toBe("off");
      expect(readingLookValues(saved, arm)).toBe(saved);
    }
  });

  test("reading uses public display settings for both drawing and measurement", () => {
    const display = resolveChatDisplay(readingLookValues(saved, "reading"));
    expect(display).toMatchObject({ width: 720, fullWidth: false, font: "system", fontSize: 15, lineHeight: 1.5 });
    const metrics = chatMetrics(display, 1);
    const variables = chatDisplayVariables(display, 1);
    expect(variables["--cv-font-size"]).toBe("15px");
    expect(variables["--cv-line-height"]).toBe("22.5px");
    expect(metrics.measureFont).toStartWith("15px ");
    expect(metrics.lineHeight).toBe(22.5);
  });

  test("type-only preserves full width and unrelated display preferences", () => {
    const values = readingLookValues(saved, "type");
    expect(values["agentPane.display.width"]).toBe(960);
    expect(values["agentPane.display.fullWidth"]).toBe(true);
    expect(values["agentPane.display.code.family"]).toBe("Menlo");
    expect(resolveChatDisplay(values).fontSize).toBe(15);
  });

  test("turning off restores every saved value after either preview", () => {
    for (const arm of ["reading", "type"] as const) {
      readingLookValues(saved, arm);
      expect(resolveChatDisplay(readingLookValues(saved, "off"))).toEqual(resolveChatDisplay(saved));
    }
    expect(saved["agentPane.display.font.size"]).toBe(18);
    expect(saved["agentPane.display.font.preset"]).toBe("serif");
  });

  test("the real display event applies the arm without replacing saved preferences", () => {
    globalThis.cmuxExperiments = { [readingLook.id]: "reading" };
    setChatDisplay(saved);
    expect(chatDisplay().width).toBe(720);
    expect(chatDisplay().fontSize).toBe(15);
    expect(chatDisplayValues()).toEqual(saved);

    globalThis.cmuxExperiments = { [readingLook.id]: "off" };
    setChatDisplay(saved);
    expect(chatDisplay()).toEqual(resolveChatDisplay(saved));
    expect(chatDisplayValues()).toEqual(saved);
  });
});
