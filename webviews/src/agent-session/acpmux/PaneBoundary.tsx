// The pane's last error boundary (main.tsx). A message that fails to draw has its own boundary
// (conversation/MessageBoundary.tsx); this one keeps any other render error from leaving a blank
// pane, and its button asks the page host to reload the document so a transient bundle failure can
// recover without restarting the app.
import { Component, type ErrorInfo, type ReactNode } from "react";
import { useT } from "./i18n";

type Props = { children?: ReactNode; onRetry?: () => void };
type State = { failed: boolean };

/// The throw that took the pane down, for `debug.agent_pane readiness` (`pane_failure`): a bench or
/// capture that finds the pane failed names the error instead of timing out on a debug hook that the
/// failed pane never installed (hq#15602).
export type PaneFailure = { message: string; stack?: string; componentStack?: string };
declare global {
  interface Window {
    __cmuxPaneFailure?: PaneFailure;
  }
}

/// snapshotCache.ts's sessionStorage key for the reload copy of the pane's snapshot.
export const SNAPSHOT_KEY = "cmux.acpmux.snapshot";

function dropSavedSnapshot(): void {
  try {
    sessionStorage.removeItem(SNAPSHOT_KEY);
  } catch {
    // Storage that is unavailable holds no copy to repaint.
  }
}

export class PaneBoundary extends Component<Props, State> {
  state: State = { failed: false };

  static getDerivedStateFromError(): State {
    return { failed: true };
  }

  componentDidCatch(error: unknown, info: ErrorInfo) {
    window.__cmuxPaneFailure = {
      message: error instanceof Error ? `${error.name}: ${error.message}` : String(error),
      ...(error instanceof Error && error.stack ? { stack: error.stack } : {}),
      ...(info.componentStack ? { componentStack: info.componentStack } : {}),
    };
    console.error("agent pane failed to draw", window.__cmuxPaneFailure);
    // The reload copy of the snapshot (snapshotCache.ts `cachedSnapshot`) would paint the rows that
    // threw again on Retry's reload, and fail the same way: the reloaded pane starts empty instead
    // and draws from its live client. A write still pending (its timer, or the save on `pagehide`,
    // whose listener was added before this one) would put the copy back, so it goes again as the
    // page unloads.
    dropSavedSnapshot();
    window.addEventListener("pagehide", dropSavedSnapshot);
  }

  render() {
    const retry = () => {
      this.setState({ failed: false });
      this.props.onRetry?.();
    };
    return this.state.failed ? <PaneFailed onRetry={retry} /> : this.props.children;
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
