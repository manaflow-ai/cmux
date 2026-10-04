import { Icon } from "../icons";
import { t } from "../strings";

export function ReadOnlyBanner() {
  return (
    <output className="banner" data-read-only="">
      <Icon name="warning" />
      {t("settingsPage.readOnly")}
    </output>
  );
}
