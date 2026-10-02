"use client";

import { getRouteApi } from "@tanstack/react-router";
import { TestflightScreen } from "./testflight-screen";

const routeApi = getRouteApi("/shell/dashboard/testflight");

export function TestflightRouteComponent() {
  const { testflight } = routeApi.useSearch();
  return <TestflightScreen testflight={testflight} />;
}
