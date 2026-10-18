// The pane's last error boundary (main.tsx). A message that fails to draw has its own boundary
// (conversation/MessageBoundary.tsx); this one keeps any other render error from leaving a blank
// pane, and its button draws the pane again.
import { Component, type ErrorInfo, type ReactNode } from "react";
import { useT } from "./i18n";

type Props = { children?: ReactNode };
type State = { failed: boolean };

export class PaneBoundary extends Component<Props, State> {
  state: State = { failed: false };

  static getDerivedStateFromError(): State {
    return { failed: true };
  }

  componentDidCatch(error: unknown, info: ErrorInfo) {
    reportToDevServer(error, info.componentStack ?? undefined);
  }

  render() {
    return this.state.failed ? <PaneFailed onRetry={() => this.setState({ failed: false })} /> : this.props.children;
  }
}

function PaneFailed({ onRetry }: { onRetry: () => void }) {
  const t = useT();
  return (
    <div className="acpmux-pane-failed" role="alert">
      <p>{t("pane.renderFailed")}</p>
      <button type="button" className="acpmux-pane-failed__retry" onClick={onRetry}>
        {t("pane.renderRetry")}
      </button>
    </div>
  );
}

/// On the dev server only, the error goes to its log (vite.config.acpmux-pane.mjs, DEV_PANE_ERROR_PATH),
/// since the app's web view keeps no console a session can read (Lucas 2026-10-18).
function reportToDevServer(error: unknown, componentStack: string | undefined) {
  if (import.meta.env?.DEV !== true || !/^https?:$/.test(location.protocol)) return;
  const detail = error instanceof Error ? `${error.name}: ${error.message}\n${error.stack ?? ""}` : String(error);
  void fetch("/__cmux-pane-error", {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: `${new Date().toISOString()}\n${detail}\n${componentStack ?? ""}\n`,
  }).catch(() => undefined);
}

// A failed module load or an unhandled error outside React reaches the same log on the dev server.
if (typeof window !== "undefined" && import.meta.env?.DEV === true) {
  window.addEventListener("error", (event) => reportToDevServer(event.error ?? event.message, `at ${event.filename}:${event.lineno}`));
  window.addEventListener("unhandledrejection", (event) => reportToDevServer(event.reason, "unhandled rejection"));
}
