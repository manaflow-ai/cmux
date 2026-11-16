import { useEffect, useState } from "react";
import { t } from "../i18n";

const RECONNECT_NOTICE_DELAY_MS = 10_000;

export function ReconnectNotice({
  needsAction = false,
  onRetry,
}: {
  needsAction?: boolean;
  onRetry(): void;
}) {
  const [expired, setExpired] = useState(false);
  useEffect(() => {
    setExpired(false);
    if (!needsAction) return;
    // Bound the actionable state before showing it, even if a caller enters it
    // while a replacement session is still settling.
    const timer = setTimeout(() => setExpired(true), RECONNECT_NOTICE_DELAY_MS);
    return () => clearTimeout(timer);
  }, [needsAction]);
  if (!needsAction || !expired) return null;
  return (
    <div className="reconnect-banner" role="status">
      <span>{t("reconnectFailed")}</span>
      <button type="button" onClick={onRetry}>
        {t("retryConnection")}
      </button>
    </div>
  );
}
