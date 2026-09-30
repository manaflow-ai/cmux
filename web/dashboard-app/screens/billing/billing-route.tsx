"use client";

import { getRouteApi } from "@tanstack/react-router";
import { BillingScreen } from "./billing-screen";

const routeApi = getRouteApi("/shell/dashboard/billing");

export function BillingRouteComponent() {
  const search = routeApi.useSearch();
  return <BillingScreen search={search} />;
}
