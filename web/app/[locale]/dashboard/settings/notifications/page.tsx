import { SettingsRoute } from "../settings-route";
import { NotificationSettings } from "../components/notification-settings";

export const instant = true;

export default function DashboardSettingsNotificationsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  return (
    <SettingsRoute params={params} section="notifications" returnPath="/dashboard/settings/notifications">
      <NotificationSettings />
    </SettingsRoute>
  );
}
