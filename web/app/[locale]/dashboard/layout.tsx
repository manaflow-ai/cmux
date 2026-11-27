import { StackTheme } from "@hexclave/next";
import { redirect } from "next/navigation";
import { isStackConfigured } from "@/app/lib/stack";
import { StackProviders } from "../stack-providers";

// Everything under /dashboard is the TanStack Router SPA in `dashboard-app/`.
// The global `[locale]` layout provides intl messages, theme and PostHog;
// this layout adds the Hexclave session and its component theme, which the
// marketing pages leave out to keep their JavaScript small.
export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  if (!isStackConfigured()) redirect("/");
  return (
    <StackProviders>
      <StackTheme>{children}</StackTheme>
    </StackProviders>
  );
}
