import { StackTheme } from "@hexclave/next";
import { redirect } from "next/navigation";
import { isStackConfigured } from "@/app/lib/stack";

// Everything under /dashboard is the TanStack Router SPA in `dashboard-app/`.
// The global `[locale]` layout already provides Stack, intl messages, theme,
// and PostHog; this layout only adds the Stack component theme.
export const instant = true;

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  if (!isStackConfigured()) redirect("/");
  return <StackTheme>{children}</StackTheme>;
}
