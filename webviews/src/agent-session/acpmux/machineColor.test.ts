// A machine keeps one color everywhere (machineColor.ts): the hash is the app's AgentPresenceColor
// (FNV-1a, then red, green, yellow, purple, cyan, orange, pink, blue), so the sidebar matches, and
// case or stray space never moves a machine to another color.
import { describe, expect, test } from "bun:test";
import { machineColor, machineHue } from "./machineColor";

describe("machineHue", () => {
  test("matches the app's FNV-1a pick", () => {
    expect(machineHue("big-red")).toBe("purple");
    expect(machineHue("air-blue")).toBe("pink");
    expect(machineHue("cosmic-gray")).toBe("orange");
  });

  test("ignores case and surrounding space", () => {
    expect(machineHue(" Big-Red ")).toBe(machineHue("big-red"));
  });

  test("reads the pane's terminal palette", () => {
    expect(machineColor("big-red")).toContain("--agent-ansi-5");
  });
});
