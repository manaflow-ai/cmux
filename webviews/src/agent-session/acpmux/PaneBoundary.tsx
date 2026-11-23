// The pane's last error boundary (main.tsx). A message that fails to draw has its own boundary
// (conversation/MessageBoundary.tsx); this one keeps any other render error from leaving a dead
// pane. Drawing again is the only answer, so it is no one's decision: the pane asks its host to
// reload the document on its own (`onRetry`), on the shared backoff (autoRetry.ts), with no button
// (Leo, 2026-11-22: "vacuous decisions like that should be just done"). A transient bundle failure
// recovers by itself; one that lasts says only "Still loading the agent pane…". The backoff is kept
// across the reloads (sessionStorage), so a pane that fails on every load reloads at most every
// 30 s, not once a second.
import { Component, type ReactNode, type ErrorInfo } from "react";
import { AUTO_RETRY_FIRST_MS, AUTO_RETRY_MAX_MS, type AutoRetryOptions, useAutoRetry } from "./autoRetry";
import { useT } from "./i18n";
import { LASTING_MS } from "../../ui/lasting";

type Props = {
  children?: ReactNode;
  onRetry?: () => void;
  /// The backoff's options; tests pass a short one. The first wait comes from the reloads so far.
  autoRetry?: AutoRetryOptions;
};
type State = { failed: boolean };

/// The reloads of this stretch of failures, kept across them: how many, and when the first failed.
const RELOADS_KEY = "acpmux.paneReloads";
/// A pane that drew for this long without failing ends the stretch: the next failure starts at 1 s.
const STABLE_MS = 30_000;

type Reloads = { count: number; since: number };

function readReloads(): Reloads | undefined {
  try {
    const raw = window.sessionStorage?.getItem(RELOADS_KEY);
    const parsed = raw ? (JSON.parse(raw) as Partial<Reloads>) : undefined;
    return typeof parsed?.count === "number" && typeof parsed.since === "number"
      ? { count: parsed.count, since: parsed.since }
      : undefined;
  } catch {
    return undefined;
  }
}

function writeReloads(reloads: Reloads | undefined): void {
  try {
    if (reloads) window.sessionStorage?.setItem(RELOADS_KEY, JSON.stringify(reloads));
    else window.sessionStorage?.removeItem(RELOADS_KEY);
  } catch {
    // No storage (a private page): each load starts the backoff at its first wait.
  }
}

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
  private stable: ReturnType<typeof setTimeout> | undefined;

  static getDerivedStateFromError(): State {
    return { failed: true };
  }

  componentDidMount() {
    this.stable = setTimeout(() => {
      if (!this.state.failed) writeReloads(undefined);
    }, STABLE_MS);
  }

  componentWillUnmount() {
    if (this.stable !== undefined) clearTimeout(this.stable);
  }

  componentDidCatch(error: unknown, info: ErrorInfo) {
    window.__cmuxPaneFailure = {
      message: error instanceof Error ? `${error.name}: ${error.message}` : String(error),
      ...(error instanceof Error && error.stack ? { stack: error.stack } : {}),
      ...(info.componentStack ? { componentStack: info.componentStack } : {}),
    };
    console.error("agent pane failed to draw", window.__cmuxPaneFailure);
  }

  render() {
    const retry = () => {
      const was = readReloads();
      writeReloads({ count: (was?.count ?? 0) + 1, since: was?.since ?? Date.now() });
      this.setState({ failed: false });
      this.props.onRetry?.();
    };
    return this.state.failed ? <PaneFailed onRetry={retry} options={this.props.autoRetry} /> : this.props.children;
  }
}

/// Nothing at first (the page's own background); the quiet line once the failures have lasted.
function PaneFailed({ onRetry, options }: { onRetry: () => void; options?: AutoRetryOptions }) {
  const t = useT();
  const reloads = readReloads();
  const firstMs = Math.min(
    (options?.firstMs ?? AUTO_RETRY_FIRST_MS) * 2 ** (reloads?.count ?? 0),
    options?.maxMs ?? AUTO_RETRY_MAX_MS,
  );
  const { stillTrying } = useAutoRetry(true, onRetry, { ...options, firstMs });
  const lasted = stillTrying || (reloads !== undefined && Date.now() - reloads.since >= LASTING_MS);
  return (
    <output className="acpmux-pane-failed" data-pane-failed="">
      {lasted && <p>{t("pane.stillLoading")}</p>}
    </output>
  );
}
