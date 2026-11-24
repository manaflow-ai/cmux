// An attachment chip whose preview throws while it draws (a video's poster or length from a host
// answer the page did not expect, an image's thumbnail, a PDF's page count) falls back to that
// file's plain chip, its name and its ×: only that chip changes, never the prompt or the pane
// (Leo, 2026-11-11: "i tried uploading this video to my nightly app and it just made the screen
// blank"). The error goes to the console, so the error journal (`cmux errors`) keeps it. A new
// attachment object (its poster arrived, a Retry) tries the preview again.
//
// Any one piece that must fail alone uses it the same way: `attachment` is the object whose change
// tries again, and `failure` the console line (a New Tab widget tile, NewTabWidgets.tsx).
import { Component, type ErrorInfo, type ReactNode } from "react";

type Props = { attachment: object; fallback: ReactNode; failure?: string; children?: ReactNode };
type State = { attachment: object; failed: boolean };

export class AttachmentPreviewBoundary extends Component<Props, State> {
  state: State = { attachment: this.props.attachment, failed: false };

  static getDerivedStateFromProps(props: Props, state: State): Partial<State> | null {
    return props.attachment === state.attachment ? null : { attachment: props.attachment, failed: false };
  }

  static getDerivedStateFromError(): Partial<State> {
    return { failed: true };
  }

  componentDidCatch(error: unknown, info: ErrorInfo) {
    console.error(this.props.failure ?? "attachment preview failed; showing its file chip", error, info.componentStack);
  }

  render() {
    return this.state.failed ? this.props.fallback : this.props.children;
  }
}
