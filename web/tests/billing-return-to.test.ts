import { describe, expect, test } from "bun:test";
import { dashboardReturnPath } from "../services/billing/returnTo";

describe("checkout returnTo", () => {
  test("keeps same-origin dashboard paths, with or without a locale prefix", () => {
    expect(dashboardReturnPath("/dashboard/cloud")).toBe("/dashboard/cloud");
    expect(dashboardReturnPath("/dashboard")).toBe("/dashboard");
    expect(dashboardReturnPath("/ja/dashboard/testflight")).toBe("/ja/dashboard/testflight");
    expect(dashboardReturnPath("/dashboard/teams/abc-123/billing")).toBe("/dashboard/teams/abc-123/billing");
  });

  test("drops the query and fragment of an accepted path", () => {
    expect(dashboardReturnPath("/dashboard/cloud?welcome=max#x")).toBe("/dashboard/cloud");
  });

  test.each([
    null,
    "",
    "https://evil.example/dashboard",
    "//evil.example/dashboard",
    "/\\evil.example/dashboard",
    "\\\\evil.example",
    "/%2F%2Fevil.example/dashboard",
    "javascript:alert(1)",
    "/pricing",
    "/dashboardx",
    "/xx/dashboard",
    "/dashboard/../api/billing/portal",
    "/dashboard/%2e%2e/api/billing/portal",
    "/dashboard/cloud\nSet-Cookie: x=1",
    `/dashboard/${"a".repeat(300)}`,
  ])("rejects %p", (value) => {
    expect(dashboardReturnPath(value)).toBeNull();
  });
});
