import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { EXPERIMENTS_STORAGE_KEY, experimentArm } from "./experiment";
import { currentSettingArms, settingArms, switchFor } from "./hostSettings";
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
    expect(experimentArm(trayFoldHeadLook, { overrides: {}, stored: {} })).toBe("groups");
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
      "subagent-tray-fold-head": "groups",
    });
    expect(experimentArm(menuStyleV2, { overrides: {}, stored: {} })).toBe("v2");
    expect(experimentArm(menuStyleV2, { overrides: { "menu-style-v2": "v2-glass" }, stored: {} })).toBe("v2-glass");
    expect(experimentArm(trayFoldHeadLook, { overrides: {}, stored: {} })).toBe("groups");
  });

  test("each menu experiment has one switch", () => {
    expect(switchFor("menu-style-v2")).toBe("menuStyleV2");
    expect(switchFor("menu-row-states")).toBe("menuRowStates");
    expect(switchFor("subagent-tray-fold-head")).toBe("composerHatGroups");
    expect(switchFor("glass-toolbar")).toBeUndefined();
  });

  test("a lookup builds the arms and parses the debug key only when they change", () => {
    // Before: every experimentArm call built the switches' arms and parsed the localStorage key
    // again, many a render (settled page, Leo 2026-11-21: "workspace switch, opening a recent
    // workspace, chat switch and restart reach a settled page (zero layout shift after first paint,
    // streaming included) within 2x of a derived bound").
    const saved = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
    let text: string | null = JSON.stringify({ "menu-row-states": "on" });
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      value: { getItem: (key: string) => (key === EXPERIMENTS_STORAGE_KEY ? text : null) },
    });
    const parse = spyOn(JSON, "parse");
    try {
      const arms = currentSettingArms();
      for (let i = 0; i < 100; i += 1) {
        expect(experimentArm(menuRowStates, { overrides: {} })).toBe("on");
        expect(currentSettingArms()).toBe(arms);
      }
      expect(parse).toHaveBeenCalledTimes(1);
      // A changed key and changed switches are read at once.
      text = JSON.stringify({ "menu-row-states": "off" });
      expect(experimentArm(menuRowStates, { overrides: {} })).toBe("off");
      setExperimentSwitches({ menuStyleV2: true });
      expect(currentSettingArms()).not.toBe(arms);
      expect(experimentArm(menuStyleV2, { overrides: {} })).toBe("v2");
    } finally {
      parse.mockRestore();
      if (saved) Object.defineProperty(globalThis, "localStorage", saved);
      else delete (globalThis as { localStorage?: unknown }).localStorage;
    }
  });
});
