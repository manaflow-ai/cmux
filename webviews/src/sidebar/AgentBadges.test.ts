import { describe, expect, test } from "bun:test";
import {
  COUNT_SIZERS,
  countSlot,
  formatCount,
  PILL_SIZERS,
  pillSlot,
  showsBeam,
  STATUS_LABEL,
  tabCount,
  type AgentStatus,
} from "./AgentBadgesModel";

const statuses: AgentStatus[] = ["idle", "running", "approval", "done"];
const counts = [0, 1, 9, 10, 42, 99, 100, 120, 5000];

describe("agent badges", () => {
  test("formatCount: empty at 0, the number up to 99, then 99+", () => {
    expect(formatCount(0)).toBe("");
    expect(formatCount(-3)).toBe("");
    expect(formatCount(Number.NaN)).toBe("");
    expect(formatCount(1)).toBe("1");
    expect(formatCount(99)).toBe("99");
    expect(formatCount(100)).toBe("99+");
    expect(formatCount(120)).toBe("99+");
  });

  test("the tab count slot is sized by the same text for every count, and every count fits it", () => {
    for (const count of counts) {
      const slot = countSlot(count);
      expect(slot.sizers).toEqual(COUNT_SIZERS);
      expect(slot.text.length).toBeLessThanOrEqual(Math.max(...COUNT_SIZERS.map((text) => text.length)));
    }
    expect(countSlot(0).sizers).toBe(countSlot(120).sizers);
  });

  test("the row pill slot is sized by every label for every state, so titles never move", () => {
    for (const status of statuses) {
      const slot = pillSlot(status);
      expect(slot.sizers).toEqual(PILL_SIZERS);
      if (slot.text) expect(PILL_SIZERS).toContain(slot.text);
    }
    expect(PILL_SIZERS).toEqual(["Running", "Needs approval", "Done"]);
    expect(STATUS_LABEL.idle).toBe("");
  });

  test("tab count is unread messages plus pending approvals", () => {
    expect(tabCount(2, 1)).toBe(3);
    expect(tabCount(0, 0)).toBe(0);
    expect(formatCount(tabCount(118, 2))).toBe("99+");
  });

  test("the beam runs only in the beam look on a running row", () => {
    for (const status of statuses) {
      expect(showsBeam("beam", status)).toBe(status === "running");
      expect(showsBeam("pills", status)).toBe(false);
      expect(showsBeam("off", status)).toBe(false);
    }
  });
});
