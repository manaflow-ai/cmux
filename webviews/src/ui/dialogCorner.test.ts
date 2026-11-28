import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { experimentById } from "../experiments/registry";
import { dialogCorner } from "./dialogCorner.experiment";

const css = readFileSync(join(import.meta.dir, "popupSurface.css"), "utf8");
const dialogTsx = readFileSync(join(import.meta.dir, "Dialog.tsx"), "utf8");

describe("dialog-corner experiment (RFD 0207 Dialog corner)", () => {
  test("is registered and off by default", () => {
    expect(dialogCorner.defaultArm).toBe("page");
    expect(experimentById("dialog-corner")).toBe(dialogCorner);
  });

  test("the native arm pads 16, so the corner is the button corner plus 16 (the native 24)", () => {
    const rule = css.match(/\.ui-dialog\.ui-glass\[data-dialog-corner="native"\]\s*\{([^}]*)\}/);
    expect(rule).not.toBeNull();
    expect(rule![1]).toContain("--ui-dialog-padding: var(--cmux-dialog-padding, var(--ds-space-4))");
    // The corner stays derived from the padding, so it stays concentric with the buttons.
    expect(css).toContain("calc(var(--role-control-radius) + var(--ui-dialog-padding))");
  });

  test("Dialog puts the arm on the popup", () => {
    expect(dialogTsx).toContain("data-dialog-corner={corner}");
    expect(dialogTsx).toContain("useExperimentArm(dialogCorner)");
  });
});
