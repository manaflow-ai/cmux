import { SettingsRoute } from "../settings-route";
import { AccountActions } from "../components/account-actions";

export const instant = true;

export default function DashboardSettingsAccountPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  return (
    <SettingsRoute params={params} section="account" returnPath="/dashboard/settings/account">
      <AccountActions />
    </SettingsRoute>
  );
}
