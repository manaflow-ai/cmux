import { notFound } from "next/navigation";

export default function DashboardNavigationFixturePage() {
  if (process.env.NEXT_INSTANT_TEST !== "1") {
    notFound();
  }

  return <div data-testid="dashboard-navigation-fixture" className="min-h-px" />;
}
