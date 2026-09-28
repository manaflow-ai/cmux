import { SettingsRoute } from "./settings-route";
import { ProfileSettings } from "./components/profile-settings";

export const instant = true;

export default function DashboardSettingsProfilePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  return (
    <SettingsRoute params={params} section="profile" returnPath="/dashboard/settings">
      <ProfileSettings />
    </SettingsRoute>
  );
}
