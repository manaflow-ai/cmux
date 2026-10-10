// The changes view while a scope loads, when it fails, and when it has nothing, as
// centered states: "Couldn't load changes" with Retry, and "No changes".
import React from "react";
import { useT } from "../i18n";

export function LoadState({ state, onRetry }: { state: "loading" | "error" | "empty"; onRetry: () => void }) {
  const t = useT();
  if (state === "loading")
    return (
      <output className="acpmux-changes-state">
        <span className="acpmux-changes-state-body">{t("changes.loading")}</span>
      </output>
    );
  if (state === "empty")
    return (
      <output className="acpmux-changes-state">
        <strong>{t("changes.none")}</strong>
      </output>
    );
  return (
    <div className="acpmux-changes-state" role="alert">
      <strong>{t("changes.loadFailed")}</strong>
      <span className="acpmux-changes-state-body">{t("changes.loadFailedHint")}</span>
      <button type="button" className="acpmux-changes-retry" onClick={onRetry}>
        {t("changes.retry")}
      </button>
    </div>
  );
}
