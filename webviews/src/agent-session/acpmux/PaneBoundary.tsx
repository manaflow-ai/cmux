// The pane's last error boundary (main.tsx). A message that fails to draw has its own boundary
// (conversation/MessageBoundary.tsx); this one keeps any other render error from leaving a blank
// pane, and its button draws the pane again.
import { Component, type ReactNode } from "react";
import { useT } from "./i18n";

type Props = { children?: ReactNode };
type State = { failed: boolean };

export class PaneBoundary extends Component<Props, State> {
  state: State = { failed: false };

  static getDerivedStateFromError(): State {
    return { failed: true };
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
