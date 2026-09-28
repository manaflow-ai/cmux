import { DashboardApp } from "@/dashboard-app/app";

// The page reads no params, headers, or cookies: the SPA reads the URL on the
// client, so the shell prerenders and every dashboard URL serves it instantly.
export const instant = true;

export default function DashboardPage() {
  return <DashboardApp />;
}
