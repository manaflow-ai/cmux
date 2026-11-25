// The pane's last error boundary (main.tsx). A message that fails to draw has its own boundary
// (conversation/MessageBoundary.tsx); this one keeps any other render error from leaving a blank
// pane, and its button asks the page host to reload the document so a transient bundle failure can
// recover without restarting the app.
import { Component, type ReactNode } from "react";
import { useT } from "./i18n";

type Props = { children?: ReactNode; onRetry?: () => void };
type State = { failed: boolean };

export class PaneBoundary extends Component<Props, State> {
  state: State = { failed: false };

  static getDerivedStateFromError(): State {
    return { failed: true };
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
