import { afterEach, describe, expect, test } from "bun:test";
import { experimentArm } from "./experiment";
import { settingArms, switchFor } from "./hostSettings";
import { setExperimentSwitches } from "./switches";
import { menuStyleV2 } from "../ui/menuStyleV2.experiment";
import { menuRowStates } from "../ui/menuRowStates.experiment";
import { trayFoldHeadLook } from "../agent-session/acpmux/subagents/trayFoldHead.experiment";
import { trayColumnLook } from "../agent-session/acpmux/subagents/trayColumn.experiment";

afterEach(() => setExperimentSwitches({}));

describe("Settings switches pick experiment arms", () => {
  test("a switch that is off runs the default arm", () => {
    expect(settingArms()).toEqual({});
    expect(experimentArm(menuStyleV2, { overrides: {}, stored: {} })).toBe("off");
    expect(experimentArm(menuRowStates, { overrides: {}, stored: {} })).toBe("off");
    expect(experimentArm(trayFoldHeadLook, { overrides: {}, stored: {} })).toBe("tally");
    expect(experimentArm(trayColumnLook, { overrides: {}, stored: {} })).toBe("chip");
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
      "subagent-tray-column": "glyph",
    });
    expect(experimentArm(menuStyleV2, { overrides: {}, stored: {} })).toBe("v2");
    expect(experimentArm(menuStyleV2, { overrides: { "menu-style-v2": "v2-glass" }, stored: {} })).toBe("v2-glass");
    expect(experimentArm(trayFoldHeadLook, { overrides: {}, stored: {} })).toBe("groups");
    expect(experimentArm(trayColumnLook, { overrides: {}, stored: {} })).toBe("glyph");
  });

  test("each menu experiment has one switch", () => {
    expect(switchFor("menu-style-v2")).toBe("menuStyleV2");
    expect(switchFor("menu-row-states")).toBe("menuRowStates");
    expect(switchFor("subagent-tray-fold-head")).toBe("composerHatGroups");
    expect(switchFor("subagent-tray-column")).toBe("composerHatGroups");
    expect(switchFor("glass-toolbar")).toBeUndefined();
  });
});
