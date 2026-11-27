import { describe, expect, test } from "bun:test";
import { findUiGuidelineViolations } from "../scripts/check-ui-guidelines";

const rule = (gap: string, height = "var(--acpmux-tray-pull-control-height)") => `
.acpmux-tray-pull__slot[data-shown] { width: calc(${gap} + var(--acpmux-tray-pull-mark, 0px)); }
.acpmux-tray-pull__tab { height: ${height}; transition: width var(--agent-motion-move) ease; }
`;

describe("ui guidelines", () => {
  test("flags the pre-fix chevron spacing", () => {
    expect(findUiGuidelineViolations("before.css", rule("var(--ds-space-1)"))).toEqual([
      expect.objectContaining({ rule: "spacing" }),
    ]);
  });

  test("accepts tokenized spacing and hit target", () => {
    expect(findUiGuidelineViolations("after.css", rule("var(--ds-space-2)"))).toEqual([]);
  });

  test("flags a raw long animation and a short hit target", () => {
    const findings = findUiGuidelineViolations("bad.css", rule("var(--ds-space-2)", "20px"));
    expect(findings.map(({ rule }) => rule)).toEqual(["hit-target"]);
    expect(
      findUiGuidelineViolations("motion.css", `.acpmux-tray-pull__slot { transition: width 240ms ease; }`),
    ).toEqual([expect.objectContaining({ rule: "animation-duration" })]);
  });
});
