// The pane's last error boundary (main.tsx). A message that fails to draw has its own boundary
// (conversation/MessageBoundary.tsx); this one keeps any other render error from leaving a dead
// pane. Drawing again is the only answer, so it is no one's decision: the pane asks its host to
// reload the document on its own (`onRetry`), on the shared backoff (autoRetry.ts), with no button
// (Leo, 2026-11-22: "vacuous decisions like that should be just done"). A transient bundle failure
// recovers by itself; one that lasts says only "Still loading the agent pane…". The backoff is kept
// across the reloads (sessionStorage), so a pane that fails on every load reloads at most every
// 30 s, not once a second.
//
// What it caught goes to the page's console in the error's own words, with the component that threw
// (the app keeps console errors in its journal, `cmux errors`): the pane alone says only that it is
// still loading, and a boundary that logs nothing leaves no reason to fix (Leo, 2026-11-22: "it gave
// me the agent pane could not be drawn after i opedn up background tasks"; handbook
// failure-drops-its-reason).
import { Component, type ErrorInfo, type ReactNode } from "react";
import { AUTO_RETRY_FIRST_MS, AUTO_RETRY_MAX_MS, type AutoRetryOptions, useAutoRetry } from "./autoRetry";
import { useT } from "./i18n";
import { LASTING_MS } from "../../ui/lasting";
import { clearSnapshot } from "./snapshotCache";

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
    console.error(paneFailureLine(error, info.componentStack ?? undefined), error, info.componentStack ?? "");
    // The reload copy of the snapshot would paint the rows that threw again on Retry's reload and
    // fail the same way: the reloaded pane starts empty and draws from its live client. Saves stop for
    // the rest of this page (`saveSnapshot`), so neither a pending one nor `pagehide` puts it back.
    clearSnapshot();
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
