import { SettingsRoute } from "../settings-route";
import { AuthSettings } from "../components/auth-settings";

export const instant = true;

export default function DashboardSettingsAuthPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  return (
    <SettingsRoute params={params} section="auth" returnPath="/dashboard/settings/auth">
      <AuthSettings />
    </SettingsRoute>
  );
}
