import { DashboardApp } from "@/dashboard-app/app";

// The page reads no params, headers, or cookies: the SPA reads the URL on the
// client, so every dashboard URL serves the same static document. Navigation
// inside the dashboard never reaches Next, so there is no `instant` export:
// its validation only reported the shared `[locale]` layout's params reads.

export default function DashboardPage() {
  return <DashboardApp />;
}
