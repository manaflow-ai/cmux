// A machine keeps one color everywhere (machineColor.ts): the hash is the app's AgentPresenceColor
// (FNV-1a, then red, green, yellow, purple, cyan, orange, pink, blue), so the sidebar matches, and
// case or stray space never moves a machine to another color.
import { describe, expect, test } from "bun:test";
import { assignMachineHues, machineColor, machineEmoji, machineHue, setHostMachineMarks } from "./machineColor";

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

describe("assignMachineHues", () => {
  test('two machines whose names hash to one hue take two (Leo: "we can have them be delineated")', () => {
    expect(machineHue("linux-box")).toBe(machineHue("gpu-box"));
    const hues = assignMachineHues(["linux-box", "gpu-box", "build-box"]);
    expect(new Set(Object.values(hues)).size).toBe(3);
    // The app's MachineColorOverrides.automaticAccents gives the same (MachineColorTests).
    expect(hues).toEqual({ "build-box": machineHue("build-box"), "gpu-box": "green", "linux-box": "yellow" });
  });

  test("keys by trimmed, lowercased name and keeps a lone machine's hash hue", () => {
    expect(assignMachineHues([" Big-Red ", "big-red"])).toEqual({ "big-red": "purple" });
  });

  test("the host's colors and icons win over the hash", () => {
    setHostMachineMarks({ "Linux-Box": "#123456" }, { "linux-box": "🐧" });
    expect(machineColor("linux-box")).toBe("#123456");
    expect(machineEmoji(" LINUX-BOX ")).toBe("🐧");
    setHostMachineMarks();
    expect(machineColor("linux-box")).toContain("--agent-ansi-");
  });
});
