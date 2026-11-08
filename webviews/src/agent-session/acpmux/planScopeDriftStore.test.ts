import { describe, expect, test } from "bun:test";
import {
  approvePlan,
  clearPlanScope,
  currentPlanScopeDrift,
  editPaths,
  keepPlanScopeArea,
  observePlanEdit,
  planScopeFromMarkdown,
} from "./planScopeDriftStore";

const session = "scope-test";

describe("plan scope drift", () => {
  test("extracts file and directory paths from a plan", () => {
    expect(planScopeFromMarkdown("Update `ui/settings/*` and auth/session.rs; leave docs alone.")).toEqual([
      "ui/settings/",
      "auth/session.rs",
    ]);
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

  test("reads edit locations before canonical metadata", () => {
    expect(
      editPaths({
        locations: [{ path: "auth/session.rs", _meta: { acpmux: { canonicalPath: "/tmp/auth/session.rs" } } }],
        rawInput: { file_path: "/tmp/auth/session.rs" },
      }),
    ).toEqual(["auth/session.rs", "/tmp/auth/session.rs"]);
  });

  test("keeps absolute edit areas distinct", () => {
    approvePlan(session, "Edit ui/settings/*");
    expect(observePlanEdit(session, ["/Users/leo/project/auth/session.rs"])?.area).toBe(
      "/Users/leo/project/auth/",
    );
    expect(observePlanEdit(session, ["/Users/leo/project/web/session.ts"])?.area).toBe(
      "/Users/leo/project/web/",
    );
    clearPlanScope(session);
  });
});
