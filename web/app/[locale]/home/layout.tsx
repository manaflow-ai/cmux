import { StackProvider, StackTheme } from "@stackframe/stack";
import { redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { DashboardQueryProvider } from "../dashboard/components/query-provider";
import { DashboardShell } from "../dashboard/dashboard-shell";

export default function HomeLayout({ children }: { children: React.ReactNode }) {
  if (!isStackConfigured()) redirect("/");

  return (
    <StackProvider app={getStackServerApp()}>
      <StackTheme>
        <DashboardQueryProvider>
          <DashboardShell>{children}</DashboardShell>
        </DashboardQueryProvider>
      </StackTheme>
    </StackProvider>
  );
}
