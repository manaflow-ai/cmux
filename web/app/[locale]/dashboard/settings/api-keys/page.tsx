import { SettingsRoute } from "../settings-route";
import { ApiKeySettings } from "../components/api-key-settings";

export const instant = true;

export default function DashboardSettingsApiKeysPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  return (
    <SettingsRoute params={params} section="apiKeys" returnPath="/dashboard/settings/api-keys">
      <ApiKeySettings />
    </SettingsRoute>
  );
}
