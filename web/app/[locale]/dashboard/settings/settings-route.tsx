import { redirect } from "next/navigation";
import { Suspense, type ReactNode } from "react";
import { loadDashboardSection } from "@/app/lib/dashboard-auth";
import { isStackConfigured } from "@/app/lib/stack";
import { IsolatedErrorBoundary, SectionUnavailable } from "@/app/components/error-boundary";
import { DashboardAuthRecovery } from "../components/dashboard-auth-recovery";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";
import { SettingsHeader, type SettingsHeaderSection } from "./settings-header";

/**
 * Server shell shared by every `/dashboard/settings/*` page: a static header,
 * then the private client section behind the dashboard session gate (with
 * the same recovery UI and error isolation as the other dashboard pages).
 */
export async function SettingsRoute({
  params,
  section,
  returnPath,
  children,
}: {
  readonly params: Promise<{ locale: string }>;
  readonly section: SettingsHeaderSection;
  readonly returnPath: string;
  readonly children: ReactNode;
}) {
  const { locale } = await params;
  if (!isStackConfigured()) redirect(`/${locale}`);

  return (
    <>
      <SettingsHeader section={section} />
      <Suspense fallback={<DashboardSectionSkeleton variant="rows" />}>
        <PrivateSettingsSection locale={locale} returnPath={returnPath} name={section}>
          {children}
        </PrivateSettingsSection>
      </Suspense>
    </>
  );
}

async function PrivateSettingsSection({
  locale,
  returnPath,
  name,
  children,
}: {
  readonly locale: string;
  readonly returnPath: string;
  readonly name: string;
  readonly children: ReactNode;
}) {
  const section = await loadDashboardSection(locale, returnPath);
  if (section.kind === "unavailable") {
    return <DashboardAuthRecovery locale={locale} returnPath={returnPath} />;
  }
  return (
    <IsolatedErrorBoundary name={`dashboard-settings-${name}`} fallback={<SectionUnavailable />}>
      <Suspense fallback={<DashboardSectionSkeleton variant="rows" />}>{children}</Suspense>
    </IsolatedErrorBoundary>
  );
}
