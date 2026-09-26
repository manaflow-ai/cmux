import { expect, test } from "bun:test";

import {
  dashboardReturnPathForRequest,
  normalizeDashboardReturnPath,
} from "../app/lib/dashboard-return-path";

const locales = ["en", "ja", "de"] as const;

test("derives an unlocalized dashboard path while preserving its query", () => {
  expect(
    dashboardReturnPathForRequest(
      "/ja/dashboard/coderouter",
      "?team=team-1",
      locales,
    ),
  ).toBe("/dashboard/coderouter?team=team-1");
  expect(
    dashboardReturnPathForRequest("/dashboard/testflight", "", locales),
  ).toBe("/dashboard/testflight");
});

test("does not turn public or external paths into auth return targets", () => {
  expect(dashboardReturnPathForRequest("/ja/pricing", "", locales)).toBeNull();
  expect(normalizeDashboardReturnPath("https://evil.example/dashboard")).toBe(
    "/dashboard",
  );
  expect(normalizeDashboardReturnPath("//evil.example/dashboard")).toBe(
    "/dashboard",
  );
  expect(normalizeDashboardReturnPath("/pricing")).toBe("/dashboard");
});

test("keeps a valid dashboard path bounded", () => {
  expect(
    normalizeDashboardReturnPath("/dashboard/coderouter?team=team-1"),
  ).toBe("/dashboard/coderouter?team=team-1");
  expect(normalizeDashboardReturnPath(`/dashboard/${"x".repeat(2_100)}`)).toBe(
    "/dashboard",
  );
});

test("preserves localized portal destinations through the shared authentication gate", () => {
  expect(dashboardReturnPathForRequest("/ja/home/machines/vm-1", "?view=sessions", locales))
    .toBe("/home/machines/vm-1?view=sessions");
  expect(dashboardReturnPathForRequest("/home", "", locales)).toBe("/home");
  expect(normalizeDashboardReturnPath("/home/activity")).toBe("/home/activity");
  expect(normalizeDashboardReturnPath("/home?view=machines")).toBe("/home?view=machines");
  expect(normalizeDashboardReturnPath("/home/../../pricing")).toBe("/dashboard");
  expect(normalizeDashboardReturnPath("/homepage")).toBe("/dashboard");
  expect(dashboardReturnPathForRequest("/ja/homepage", "", locales)).toBeNull();
});
