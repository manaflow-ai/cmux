// Why dictation did not run, with a way to fix it.
import React from "react";
import type { Dictation } from "./dictation";
import { t } from "./i18n";

export function DictationNotice({ dictation }: { dictation: Dictation }) {
  const notice = dictation.notice;
  if (!notice?.message) return null;
  return (
    <div className="acpmux-dictation-notice" role="alert">
      <span>{notice.message}</span>
      {notice.state === "denied" && notice.permission && (
        <button type="button" className="acpmux-dictation-settings" onClick={dictation.openSettings}>
          {notice.settingsLabel ?? t("dictation.openSettings")}
        </button>
      )}
      <button
        type="button"
        className="acpmux-dictation-dismiss"
        aria-label={t("dictation.dismiss")}
        title={t("dictation.dismiss")}
        onClick={dictation.dismiss}
      >
        ×
      </button>
    </div>
  );
}
