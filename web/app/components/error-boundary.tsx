"use client";

import { Component, useSyncExternalStore, type ReactNode } from "react";
import {
  errorBoundaryCopy,
  resolveErrorBoundaryLocale,
  type ErrorBoundaryCopy,
} from "../../i18n/error-boundary-copy";
import type { Locale } from "../../i18n/routing";
import { posthog, whenAnalyticsCaptureBuffered } from "../lib/posthog-client";

const reportedErrors = new WeakSet<object>();

/**
 * Records a caught render error. The browser bundle has no Sentry client, so
 * PostHog's exception event is the only client-side error sink.
 */
export function reportBoundaryError(boundary: string, error: unknown) {
  // A boundary can see the same failure again when its view reattaches.
  if (typeof error === "object" && error !== null) {
    if (reportedErrors.has(error)) return;
    reportedErrors.add(error);
  }
  console.error(`[${boundary}]`, error);
  // PostHog drops captures until the route tracker installs its buffer.
  void whenAnalyticsCaptureBuffered().then(() => {
    try {
      posthog?.captureException(error, { boundary });
    } catch {
      // Reporting must never throw out of an error boundary.
    }
  });
}

const subscribeToNothing = () => () => {};

/**
 * Locale for boundary copy. The server and the hydration pass both use the
 * default locale so their markup matches; the client then switches to
 * `<html lang>` (set by the root layout from the request locale) or, under
 * `global-error`, which replaces that document, the browser language.
 */
export function useErrorBoundaryLocale(): Locale {
  const clientLocale = useSyncExternalStore(
    subscribeToNothing,
    () => resolveErrorBoundaryLocale(document.documentElement.lang, navigator.language),
    () => null,
  );
  return clientLocale ?? resolveErrorBoundaryLocale();
}

export function useErrorBoundaryCopy(): ErrorBoundaryCopy {
  return errorBoundaryCopy[useErrorBoundaryLocale()];
}

type IsolatedBoundaryProps = {
  /** Reported with the error so PostHog can group failures by widget. */
  name: string;
  children: ReactNode;
  /** What renders in place of the failed widget. `null` hides it. */
  fallback: ReactNode;
};

/**
 * Contains a failure to one widget. Third-party auth UI throws during render
 * when its backend is unreachable; without this boundary React unmounts up to
 * the nearest route `error.tsx`, which replaces the whole page.
 */
type IsolatedBoundaryState = { failed: boolean; children: ReactNode };

export class IsolatedErrorBoundary extends Component<IsolatedBoundaryProps, IsolatedBoundaryState> {
  state: IsolatedBoundaryState = { failed: false, children: this.props.children };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  /**
   * A new element from the parent (a navigation, `router.refresh()`, or a
   * session change) retries the widget. The failure itself never re-renders
   * the parent, so a widget that keeps throwing cannot loop.
   */
  static getDerivedStateFromProps(
    props: IsolatedBoundaryProps,
    state: IsolatedBoundaryState,
  ): Partial<IsolatedBoundaryState> {
    if (props.children === state.children) return {};
    return { failed: false, children: props.children };
  }

  componentDidCatch(error: unknown) {
    reportBoundaryError(this.props.name, error);
  }

  render() {
    return this.state.failed ? this.props.fallback : this.props.children;
  }
}

/** Inline notice for a failed section inside an otherwise working page. */
export function SectionUnavailable() {
  const copy = useErrorBoundaryCopy();
  return (
    <p role="status" className="border border-border px-3 py-2 text-sm text-muted">
      {copy.section}{" "}
      <button
        type="button"
        onClick={() => window.location.reload()}
        className="underline underline-offset-2 hover:text-foreground"
      >
        {copy.retry}
      </button>
    </p>
  );
}

/**
 * Body for a route `error.tsx`. It renders inside the parent layout, so the
 * page chrome (navigation, dashboard shell) stays usable around it.
 */
export function RouteErrorView({
  boundary,
  error,
  retry,
  homeHref = "/",
}: {
  boundary: string;
  error: unknown;
  retry: () => void;
  homeHref?: string;
}) {
  const copy = useErrorBoundaryCopy();
  return (
    <section
      role="alert"
      data-error-boundary={boundary}
      ref={(node) => {
        // Report once per mounted error view. A callback ref runs on attach,
        // and a retry that fails again mounts a fresh view.
        if (node) reportBoundaryError(boundary, error);
      }}
      className="mx-auto flex w-full max-w-xl flex-col gap-3 px-4 py-16"
    >
      <h1 className="text-lg font-semibold">{copy.title}</h1>
      <p className="text-sm text-muted">{copy.body}</p>
      <div className="flex gap-3 text-sm">
        <button
          type="button"
          onClick={retry}
          className="border border-border px-3 py-1.5 hover:bg-code-bg"
        >
          {copy.retry}
        </button>
        <a href={homeHref} className="px-3 py-1.5 text-muted hover:text-foreground">
          {copy.home}
        </a>
      </div>
    </section>
  );
}
