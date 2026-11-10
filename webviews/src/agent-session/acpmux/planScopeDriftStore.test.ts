import { describe, expect, test } from "bun:test";
import {
  approvePlan,
  clearPlanScope,
  currentPlanScopeDrift,
  editPaths,
  keepPlanScopeArea,
  rememberPlanEdit,
  observePlanEdit,
  planScopeFromMarkdown,
} from "./planScopeDriftStore";

const session = "scope-test";

describe("plan scope drift", () => {
  test("extracts file and directory paths from a plan", () => {
    expect(
      planScopeFromMarkdown("Update `ui/settings/*`, `src/**`, `assets/**/*` and auth/session.rs; leave docs alone."),
    ).toEqual(["ui/settings/", "src/", "assets/", "auth/session.rs"]);
  });

  test("extracts absolute paths from a plan", () => {
    expect(planScopeFromMarkdown("Edit /Users/leo/repo/auth/session.rs")).toEqual(["/Users/leo/repo/auth/session.rs"]);
  });

  test("alerts once per area, then Keep going adds that area", () => {
    approvePlan(session, "Edit ui/settings/*");
    expect(observePlanEdit(session, ["ui/settings/panel.tsx"])).toBeUndefined();
    expect(observePlanEdit(session, ["auth/session.rs"])?.path).toBe("auth/session.rs");
    expect(observePlanEdit(session, ["auth/routes.rs"])).toBeUndefined();
    keepPlanScopeArea(session, "auth/");
    expect(observePlanEdit(session, ["auth/routes.rs"])).toBeUndefined();
    clearPlanScope(session);
    expect(currentPlanScopeDrift(session)).toBeUndefined();
  });

  test("matches recursive directory globs", () => {
    approvePlan(session, "Edit src/**");
    expect(observePlanEdit(session, ["src/deep/file.ts"])).toBeUndefined();
    clearPlanScope(session);
  });

  test("replays edits captured before plan approval", () => {
    rememberPlanEdit(session, ["auth/session.rs"]);
    approvePlan(session, "Edit ui/settings/*");
    expect(currentPlanScopeDrift(session)?.path).toBe("auth/session.rs");
    clearPlanScope(session);
  });

  test("reads edit locations before canonical metadata", () => {
    expect(
      editPaths({
        locations: [{ path: "auth/session.rs", _meta: { acpmux: { canonicalPath: "/tmp/auth/session.rs" } } }],
        rawInput: { file_path: "/tmp/auth/session.rs" },
      }),
    ).toEqual(["auth/session.rs", "/tmp/auth/session.rs"]);
  });

  test("reads file change locations", () => {
    expect(editPaths({ kind: "fileChange", locations: [{ path: "auth/session.rs" }] })).toEqual(["auth/session.rs"]);
  });

  test("reads delete and move locations", () => {
    expect(editPaths({ kind: "delete", locations: [{ path: "auth/old.rs" }] })).toEqual(["auth/old.rs"]);
    expect(editPaths({ kind: "move", locations: [{ path: "auth/new.rs" }] })).toEqual(["auth/new.rs"]);
  });

  test("keeps absolute edit areas distinct", () => {
    approvePlan(session, "Edit ui/settings/*");
    expect(observePlanEdit(session, ["/Users/leo/project/auth/session.rs"])?.area).toBe("/Users/leo/project/auth/");
    expect(observePlanEdit(session, ["/Users/leo/project/web/session.ts"])?.area).toBe("/Users/leo/project/web/");
    clearPlanScope(session);
  });

  test("an edit is in scope when any of its spellings is", () => {
    approvePlan(session, "Edit /Users/leo/project/ui/settings/");
    // The relative spelling alone misses an absolute scope; the absolute one covers the edit.
    expect(
      observePlanEdit(session, ["ui/settings/panel.tsx", "/Users/leo/project/ui/settings/panel.tsx"]),
    ).toBeUndefined();
    expect(currentPlanScopeDrift(session)).toBeUndefined();
    clearPlanScope(session);
  });

  test("the plan's own file is never drift, before or after approval", () => {
    rememberPlanEdit(session, ["/Users/leo/.claude/plans/quiet-otter.md"]);
    approvePlan(session, "Edit ui/settings/*");
    expect(currentPlanScopeDrift(session)).toBeUndefined();
    expect(observePlanEdit(session, ["/Users/leo/.claude/plans/quiet-otter.md"])).toBeUndefined();
    clearPlanScope(session);
  });
});
