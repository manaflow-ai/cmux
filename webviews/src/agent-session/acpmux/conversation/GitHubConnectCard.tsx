import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { postNative } from "../native";

/** First slice: open the shared connection flow on a click. An opened browser is not a verified connection. */
export function GitHubConnectCard({ request = postNative }: { request?: typeof postNative }) {
  const t = useT();
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const inFlight = useRef(false);
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const connect = () => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setFailed(false);
    // The pane's adapter for accounts.githubConnect. Never execute an arbitrary action from tool output.
    void request("github.connect", {})
      .catch(() => {
        if (mounted.current) setFailed(true);
      })
      .finally(() => {
        inFlight.current = false;
        if (mounted.current) setBusy(false);
      });
  };
  return (
    <div className="cv-repo-recovery" data-github-connect-inline>
      {failed && <span role="alert">{t("composer.githubConnectFailed")}</span>}
      <button type="button" disabled={busy} aria-busy={busy || undefined} onClick={connect}>
        {t("cloudRepository.connect")}
      </button>
    </div>
  );
}
