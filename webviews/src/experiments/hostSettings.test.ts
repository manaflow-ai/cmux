import { afterEach, describe, expect, test } from "bun:test";
import { experimentArm } from "./experiment";
import { settingArms, switchFor } from "./hostSettings";
import { setExperimentSwitches } from "./switches";
import { menuStyleV2 } from "../ui/menuStyleV2.experiment";
import { menuRowStates } from "../ui/menuRowStates.experiment";
import { trayFoldHeadLook } from "../agent-session/acpmux/subagents/trayFoldHead.experiment";

afterEach(() => setExperimentSwitches({}));

describe("Settings switches pick experiment arms", () => {
  test("a switch that is off runs the default arm", () => {
    expect(settingArms()).toEqual({});
    expect(experimentArm(menuStyleV2, { overrides: {}, stored: {} })).toBe("off");
    expect(experimentArm(menuRowStates, { overrides: {}, stored: {} })).toBe("off");
    expect(experimentArm(trayFoldHeadLook, { overrides: {}, stored: {} })).toBe("line");
  });

  test("the composer hat switch is on by default; turned off it keeps the earlier look", () => {
    setExperimentSwitches({ composerHatGroups: false });
    expect(settingArms()).toEqual({ "subagent-tray-fold-head": "tally" });
    expect(experimentArm(trayFoldHeadLook, { overrides: {}, stored: {} })).toBe("tally");
    // The gallery's override still wins over a switch turned off.
    expect(experimentArm(trayFoldHeadLook, { overrides: { "subagent-tray-fold-head": "summary" }, stored: {} })).toBe(
      "summary",
    );
    // An off switch that is off by default changes nothing.
    setExperimentSwitches({ menuStyleV2: false });
    expect(settingArms()).toEqual({});
  });

  test("an on switch runs its arm, and the gallery's override still wins", () => {
    setExperimentSwitches({
      menuStyleV2: true,
      menuRowStates: true,
      composerHatGroups: true,
      glassToolbarGroups: true,
    });
    expect(settingArms()).toEqual({
      "menu-style-v2": "v2",
      "menu-row-states": "on",
      "subagent-tray-fold-head": "line",
    });
    expect(experimentArm(menuStyleV2, { overrides: {}, stored: {} })).toBe("v2");
    expect(experimentArm(menuStyleV2, { overrides: { "menu-style-v2": "v2-glass" }, stored: {} })).toBe("v2-glass");
    expect(experimentArm(trayFoldHeadLook, { overrides: {}, stored: {} })).toBe("line");
  });

  test("the arms are kept until a switch changes, then follow it", () => {
    const first = settingArms();
    expect(settingArms()).toBe(first);
    // A push that changes nothing keeps the store's object, so the kept arms stay.
    setExperimentSwitches({});
    expect(settingArms()).toBe(first);
    setExperimentSwitches({ menuStyleV2: true });
    expect(settingArms()).toEqual({ "menu-style-v2": "v2" });
    expect(experimentArm(menuStyleV2, { overrides: {}, stored: {} })).toBe("v2");
    setExperimentSwitches({});
    expect(settingArms()).toEqual({});
    expect(experimentArm(menuStyleV2, { overrides: {}, stored: {} })).toBe("off");
  });

  test("the debug key is read again when its value changes", () => {
    const storage = new Map<string, string>();
    const saved = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      value: { getItem: (key: string) => storage.get(key) ?? null },
    });
    try {
      expect(experimentArm(menuStyleV2, { overrides: {} })).toBe("off");
      storage.set("cmux.experiments", JSON.stringify({ "menu-style-v2": "v2" }));
      expect(experimentArm(menuStyleV2, { overrides: {} })).toBe("v2");
      storage.set("cmux.experiments", "{not json");
      expect(experimentArm(menuStyleV2, { overrides: {} })).toBe("off");
    } finally {
      if (saved) Object.defineProperty(globalThis, "localStorage", saved);
      else delete (globalThis as { localStorage?: unknown }).localStorage;
    }
  });

  test("each menu experiment has one switch", () => {
    expect(switchFor("menu-style-v2")).toBe("menuStyleV2");
    expect(switchFor("menu-row-states")).toBe("menuRowStates");
    expect(switchFor("subagent-tray-fold-head")).toBe("composerHatGroups");
    expect(switchFor("glass-toolbar")).toBeUndefined();
  });
});

test("an arm reads its default with no localStorage at all, on the first lookup", async () => {
  const saved = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  Object.defineProperty(globalThis, "localStorage", { value: undefined, configurable: true, writable: true });
  try {
    const { experimentArm } = await import(`./experiment?fresh=${Date.now()}`);
    const { tunableValue } = await import(`./tunable?fresh=${Date.now()}`);
    expect(() => experimentArm(menuStyleV2)).not.toThrow();
    expect(typeof tunableValue).toBe("function");
  } finally {
    if (saved) Object.defineProperty(globalThis, "localStorage", saved);
    else delete (globalThis as { localStorage?: unknown }).localStorage;
  }
});
