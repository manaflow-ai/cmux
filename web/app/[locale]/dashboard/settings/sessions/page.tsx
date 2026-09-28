import { SettingsRoute } from "../settings-route";
import { SessionSettings } from "../components/session-settings";

export const instant = true;

export default function DashboardSettingsSessionsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  return (
    <SettingsRoute params={params} section="sessions" returnPath="/dashboard/settings/sessions">
      <SessionSettings />
    </SettingsRoute>
  );
}
