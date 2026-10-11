import { Icon } from "../icons";
import { t } from "../strings";

/** Why the page is read only: the daemon is away, or its first read failed. */
export function ReadOnlyBanner({ reason = "disconnected" }: { reason?: "disconnected" | "loadFailed" }) {
  return (
    <output className="banner" data-read-only={reason}>
      <Icon name="warning" />
      {t(reason === "loadFailed" ? "settingsPage.loadFailed" : "settingsPage.readOnly")}
    </output>
  );
}
