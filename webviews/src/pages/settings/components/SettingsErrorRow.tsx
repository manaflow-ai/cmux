import { Button } from "../../../ui/Button";
import { Icon } from "../icons";
import { t } from "../strings";

export function SettingsErrorRow({ message, retry }: { message: string; retry?: () => void }) {
  return (
    <div className="row settings-error-row">
      <span className="row-error" role="alert">
        <Icon name="warning" />
        {message}
      </span>
      {retry && <Button onClick={retry}>{t("settingsWindow.models.tryAgain")}</Button>}
    </div>
  );
}
