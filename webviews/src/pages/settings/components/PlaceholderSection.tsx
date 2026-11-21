import { useState } from "react";
import { Button } from "../../../ui/Button";
import { useSettingsState, useStore } from "../context";
import { settingsFileName } from "../format";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";

/** Advanced's file actions: open the settings file, and Reset All Settings after a confirm. */
export function PlaceholderSection({ section }: { section: string }) {
  const store = useStore();
  const { connected, host } = useSettingsState();
  const fileName = settingsFileName(host);
  const [confirming, setConfirming] = useState(false);
  return (
    <section className="group">
      <div className="rows">
        {section === "advanced" && (
          <>
            <ActionRow title={t("settingsPage.openConfig", fileName)} help={t("settingsPage.openConfigHelp")}>
              <Button type="button" className="button" onClick={() => store.openNative("cmuxJSON")}>
                {t("settingsPage.openConfig", fileName)}
              </Button>
            </ActionRow>
            <ActionRow
              title={confirming ? t("settingsPage.resetAllTitle") : t("settingsPage.resetAll")}
              help={t("settingsPage.resetAllBody", fileName)}
            >
              {confirming ? (
                <>
                  <Button type="button" className="button" onClick={() => setConfirming(false)}>
                    {t("settingsPage.cancel")}
                  </Button>
                  <Button
                    danger
                    type="button"
                    className="button danger"
                    data-confirm-reset-all=""
                    disabled={!connected}
                    onClick={() => {
                      setConfirming(false);
                      void store.resetAll();
                    }}
                  >
                    {t("settingsPage.resetAllConfirm")}
                  </Button>
                </>
              ) : (
                <Button
                  danger
                  type="button"
                  className="button danger"
                  data-reset-all=""
                  disabled={!connected}
                  onClick={() => setConfirming(true)}
                >
                  {t("settingsPage.resetAll")}
                </Button>
              )}
            </ActionRow>
          </>
        )}
      </div>
    </section>
  );
}
