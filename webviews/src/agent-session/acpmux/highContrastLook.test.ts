import { describe, expect, test } from "bun:test";
import { HIGH_CONTRAST_CHAT_VARIABLES, highContrastLook, highContrastLookValues } from "./highContrastLook.experiment";

describe("high contrast chat experiment", () => {
  test("is default off and leaves saved values untouched", () => {
    expect(highContrastLook.defaultArm).toBe("off");
    const saved = {
      "agentPane.display.font.size": 12,
      "agentPane.display.width": 640,
    };
    expect(highContrastLookValues(saved, "off")).toEqual(saved);
  });

  test("applies the first useful accessible look slice without mutating saved values", () => {
    const saved = {
      "agentPane.display.font.size": 12,
      "agentPane.display.width": 640,
    };
    expect(highContrastLookValues(saved, "high")).toEqual({
      ...saved,
      "agentPane.display.font.preset": "system",
      "agentPane.display.font.size": 18,
      "agentPane.display.font.lineHeight": 1.6,
      "agentPane.display.width": 900,
      "agentPane.display.fullWidth": false,
    });
    expect(saved).toEqual({
      "agentPane.display.font.size": 12,
      "agentPane.display.width": 640,
    });
    expect(HIGH_CONTRAST_CHAT_VARIABLES["--cv-text"]).toBe("#ffffff");
    expect(HIGH_CONTRAST_CHAT_VARIABLES["--cv-link"]).toBe("#ffd400");
  });
});
