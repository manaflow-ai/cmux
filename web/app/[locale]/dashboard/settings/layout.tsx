import { Suspense } from "react";
import { IsolatedErrorBoundary } from "@/app/components/error-boundary";
import { SettingsSubnavLayout } from "../components/settings-ui";
import { SettingsNav, SettingsNavWithAccount } from "./settings-nav";

// The frame and static navigation paint immediately; the API keys entry and
// the team list stream in once the Stack project and session resolve.
export const instant = true;

export default function SettingsLayout({ children }: { children: React.ReactNode }) {
  return (
    <SettingsSubnavLayout
      nav={
        <IsolatedErrorBoundary name="dashboard-settings-nav" fallback={<SettingsNav />}>
          <Suspense fallback={<SettingsNav />}>
            <SettingsNavWithAccount />
          </Suspense>
        </IsolatedErrorBoundary>
      }
    >
      {children}
    </SettingsSubnavLayout>
  );
}
