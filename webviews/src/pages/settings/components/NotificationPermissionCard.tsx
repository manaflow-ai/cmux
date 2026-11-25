// Settings > Notifications' first card (cmux#55600): whether macOS lets cmux show notifications. Denied,
// it says banners are blocked (sounds still play in cmux) with Open System Settings; not yet asked, it
// offers Allow Notifications (the macOS prompt). The host sends `notification_permission` from the
// app's last read (launch, each activation, the person's answer), and nothing in a launch that never asks.
import { Button } from "../../../ui/Button";
import { useSettingsState, useStore } from "../context";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";

type Tone = "success" | "warning" | "neutral";

function describe(
  authorization: string,
  sound: boolean | null,
): { status: string; help: string; tone: Tone; action: string | null } {
  switch (authorization) {
    case "denied":
      return {
        status: t("settingsWindow.notificationPermission.denied"),
        help: t("settingsWindow.notificationPermission.deniedHelp"),
        tone: "warning",
        action: t("settingsWindow.notificationPermission.openSettings"),
      };
    case "not_determined":
      return {
        status: t("settingsWindow.notificationPermission.notDetermined"),
        help: t("settingsWindow.notificationPermission.notDeterminedHelp"),
        tone: "warning",
        action: t("settingsWindow.notificationPermission.allow"),
      };
    case "authorized":
    case "provisional":
      return {
        status: t("settingsWindow.notificationPermission.allowed"),
        help:
          sound === false
            ? t("settingsWindow.notificationPermission.soundOffHelp")
            : t("settingsWindow.notificationPermission.allowedHelp"),
        tone: "success",
        action: t("settingsWindow.notificationPermission.openSettings"),
      };
    default:
      return {
        status: t("settingsWindow.notificationPermission.unknown"),
        help: t("settingsWindow.notificationPermission.allowedHelp"),
        tone: "neutral",
        action: null,
      };
  }
}

export function NotificationPermissionCard() {
  const store = useStore();
  const permission = useSettingsState().host?.notification_permission;
  if (!permission) return null;
  const { status, help, tone, action } = describe(permission.authorization, permission.sound);
  return (
    <section className="group" data-card="notification-permission" data-authorization={permission.authorization}>
      <div className="rows">
        <ActionRow title={t("settingsWindow.notificationPermission.title")} help={help}>
          <output className="accounts-status devices-status" data-tone={tone}>
            {status}
          </output>
          {action && (
            <Button type="button" className="button" onClick={() => void store.allowNotifications()}>
              {action}
            </Button>
          )}
        </ActionRow>
      </div>
    </section>
  );
}
