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

/// Stack lines (V8 `at f (url:1:2)`, JSC `f@url:1:2`) as `f@file:1:2`, at most `limit`, on one line.
function frames(stack: string | undefined, limit: number): string[] {
  const out: string[] = [];
  for (const raw of (stack ?? "").split("\n")) {
    const line = raw.trim();
    const v8 = /^at (?:(.+?) \()?(.+?)\)?$/.exec(line);
    const jsc = v8 ? undefined : /^([^\s@]*)@(.+:\d+:\d+)$/.exec(line);
    const match = v8 ?? jsc;
    if (!match) continue;
    const where = match[2]!.replace(/^.*\//, "");
    out.push(match[1] ? `${match[1]}@${where}` : where);
    if (out.length === limit) break;
  }
  return out;
}

/// The line a caught render error is logged under: what failed, the error's own words, then where,
/// all on its first line. The app's journal keeps a console error's first line and one stack frame
/// (ConsoleErrorCapture.swift), so a component stack logged as its own multi-line argument never
/// reached it: React #185 in Leo's NIGHTLY (2026-11-24) came back with nothing that named the loop.
/// `in` is the component stack (innermost first), `stack` the error's own frames: for an update loop
/// they name the set that looped. Minified names map back through the build's pane.js at those columns.
export function paneFailureLine(error: unknown, componentStack?: string): string {
  const words = error instanceof Error ? error.message : String(error);
  const components = frames(componentStack, 16);
  const stack = error instanceof Error ? frames(error.stack, 12) : [];
  return [
    `agent pane render failed: ${words || "no message"}`,
    ...(components.length ? [`in: ${components.join(" < ")}`] : []),
    ...(stack.length ? [`stack: ${stack.join(", ")}`] : []),
  ].join(" | ");
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
    console.error(paneFailureLine(error, info.componentStack ?? undefined), error, info.componentStack ?? "");
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
