// The pane's last error boundary (main.tsx). A message that fails to draw has its own boundary
// (conversation/MessageBoundary.tsx); this one keeps any other render error from leaving a blank
// pane, and its button asks the page host to reload the document so a transient bundle failure can
// recover without restarting the app.
//
// What it caught goes to the page's console in the error's own words, with the component that threw
// (the app keeps console errors in its journal, `cmux errors`): the pane alone says only that it could
// not draw, and a boundary that logs nothing leaves no reason to fix (Leo, 2026-11-22: "it gave me the
// agent pane could not be drawn after i opedn up background tasks"; handbook failure-drops-its-reason).
import { Component, type ErrorInfo, type ReactNode } from "react";
import { useT } from "./i18n";

/// The line a caught render error is logged under: what failed, then the error's own words.
export function paneFailureLine(error: unknown): string {
  const words = error instanceof Error ? error.message : String(error);
  return `agent pane render failed: ${words || "no message"}`;
}

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
    console.error(paneFailureLine(error), error, info.componentStack ?? "");
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
