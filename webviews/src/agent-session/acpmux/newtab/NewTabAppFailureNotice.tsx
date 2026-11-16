import { NEW_TAB_APP_DEADLINE_MS, type NewTabAppFailure } from "./NewTabAppPage";
import { useNt } from "./strings";
import "./appPage.css";

/// Why the extension the person picked (`tabs.newTabApp`) could not draw this New Tab page, shown
/// on cmux's own page in its place: never a blank page, never a reason left only in a log. A failed
/// render names the host's reason as it is (a script's error and its file and line).
export function NewTabAppFailureNotice({ app, failure }: { app: string; failure: NewTabAppFailure }) {
  const nt = useNt();
  const why =
    failure.kind === "failed"
      ? failure.reason || nt("appFailed.unknown")
      : failure.kind === "slow"
        ? nt("appFailed.slow", { seconds: String(NEW_TAB_APP_DEADLINE_MS / 1000) })
        : nt("appFailed.empty");
  return (
    <output className="nt-app-failure" data-app={app} data-kind={failure.kind}>
      <strong>{nt("appFailed.title", { app })}</strong> <span className="nt-app-failure-why">{why}</span>{" "}
      <span>{nt("appFailed.hint")}</span>
    </output>
  );
}
