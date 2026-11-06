import { afterEach, expect, test } from "bun:test";
import { panelAction } from "../src/agent-session/acpmux/session-info/native/panelActions";
import type { NativeInfoSection } from "../src/agent-session/acpmux/session-info/native/model";
import { resetSectionOrderForTests, sectionOrder } from "../src/agent-session/acpmux/session-info/sectionOrder";
import { resetSessionInfoState, sessionInfoState } from "../src/agent-session/acpmux/session-info/sessionInfoState";

afterEach(() => {
  resetSessionInfoState();
  resetSectionOrderForTests();
});

test("native chrome changes the existing pane state and clamps edge drags", () => {
  panelAction("close");
  expect(sessionInfoState().open).toBe(false);
  panelAction("width:9999");
  expect(sessionInfoState().width).toBe(560);
  panelAction("width:1");
  expect(sessionInfoState().width).toBe(260);
  panelAction("fold:context:0");
  expect(sessionInfoState().sections.context).toBe(false);
  panelAction("fold:context:1");
  expect(sessionInfoState().sections.context).toBe(true);
  for (const id of ["width:NaN", "width:-10", "fold:bogus:0", "fold:context:true"]) expect(panelAction(id)).toBe(false);
});

test("a drag crosses groups in the saved order while hidden sections keep their slots", () => {
  const ids = ["environment", "context", "outputs", "tasks"] as const;
  const sections: NativeInfoSection[] = ids.map((id) => ({
    id,
    group: id === "tasks" ? "running" : id === "outputs" ? "made" : "about",
    title: id,
    open: true,
    foldable: true,
    reorderable: true,
    rows: [],
  }));
  expect(panelAction("move:tasks:context", sections)).toBe(true);
  expect(sectionOrder().filter((id) => ids.includes(id as (typeof ids)[number]))).toEqual([
    "environment",
    "tasks",
    "context",
    "outputs",
  ]);
  expect(sectionOrder().includes("usage")).toBe(true);
  expect(panelAction("move:usage:context", sections)).toBe(false);
  expect(panelAction("move:tasks:missing", sections)).toBe(false);
});
