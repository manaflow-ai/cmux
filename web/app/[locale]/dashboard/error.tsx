"use client";

import { RouteErrorView } from "../../components/error-boundary";

/** Renders inside the dashboard shell so the sidebar stays usable. */
export default function DashboardError({ error, reset, retry }: { error: Error; reset: () => void; retry?: () => void }) {
  return <RouteErrorView boundary="dashboard-route" error={error} retry={retry ?? reset} />;
}
