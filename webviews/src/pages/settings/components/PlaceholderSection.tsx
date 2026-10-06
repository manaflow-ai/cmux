import { useState } from "react";
import { useSettingsState, useStore } from "../context";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";

/** Advanced's file actions: open cmux.json, and Reset All Settings after a confirm. */
export function PlaceholderSection({ section }: { section: string }) {
  const store = useStore();
  const { connected } = useSettingsState();
  const [confirming, setConfirming] = useState(false);
  return (
    <section className="group">
      <div className="rows">
        {section === "advanced" && (
          <>
            <ActionRow title={t("settingsPage.openConfig")} help={t("settingsPage.openConfigHelp")}>
              <button type="button" className="button" onClick={() => store.openNative("cmuxJSON")}>
                {t("settingsPage.openConfig")}
              </button>
            </ActionRow>
            <ActionRow
              title={confirming ? t("settingsPage.resetAllTitle") : t("settingsPage.resetAll")}
              help={t("settingsPage.resetAllBody")}
            >
              {confirming ? (
                <>
                  <button type="button" className="button" onClick={() => setConfirming(false)}>
                    {t("settingsPage.cancel")}
                  </button>
                  <button
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
                  </button>
                </>
              ) : (
                <button
                  type="button"
                  className="button danger"
                  data-reset-all=""
                  disabled={!connected}
                  onClick={() => setConfirming(true)}
                >
                  {t("settingsPage.resetAll")}
                </button>
              )}
            </ActionRow>
          </>
        )}
      </div>
    </section>
  );
}
