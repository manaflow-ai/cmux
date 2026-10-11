// A reply is untrusted text that stays in history. If drawing one still throws (the parser caps
// what it can, MAX_NESTING), only that message falls back: it draws as its source in plain,
// escaped text under a note, and the rest of the transcript draws as usual. The next source (a
// streaming delta, an edit) tries the renderer again.
import { Component, type ReactNode } from "react";
import { useT } from "../i18n";

type Props = { source: string; children?: ReactNode };
type State = { source: string; failed: boolean };

export class MessageBoundary extends Component<Props, State> {
  state: State = { source: this.props.source, failed: false };

  static getDerivedStateFromProps(props: Props, state: State): Partial<State> | null {
    return props.source === state.source ? null : { source: props.source, failed: false };
  }

  static getDerivedStateFromError(): Partial<State> {
    return { failed: true };
  }

  render() {
    return this.state.failed ? <UnrenderedMessage source={this.props.source} /> : this.props.children;
  }
}

/// The fallback: React escapes the text, so no markup in the source reaches the DOM.
function UnrenderedMessage({ source }: { source: string }) {
  const t = useT();
  return (
    <div className="cv-md selectable cv-unrendered" role="note">
      <p className="cv-unrendered__note">{t("message.renderFailed")}</p>
      <pre className="cv-unrendered__source">{source}</pre>
    </div>
  );
}
