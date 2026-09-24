"use client";

import { Component, type ReactNode } from "react";
import {
  errorBoundaryCopy,
  resolveErrorBoundaryLocale,
  type ErrorBoundaryCopy,
} from "../../i18n/error-boundary-copy";
import { posthog } from "../lib/posthog-client";

/**
 * Records a caught render error. The browser bundle has no Sentry client, so
 * PostHog's exception event is the only client-side error sink.
 */
export function reportBoundaryError(boundary: string, error: unknown) {
  console.error(`[${boundary}]`, error);
  try {
    posthog?.captureException(error, { boundary });
  } catch {
    // Reporting must never throw out of an error boundary.
  }
}

/**
 * Localized boundary copy. The root layout sets `<html lang>` from the request
 * locale; `global-error` replaces that document, so it falls back to the
 * browser language.
 */
export function useErrorBoundaryCopy(): ErrorBoundaryCopy {
  const documentLocale = typeof document === "undefined" ? null : document.documentElement.lang;
  const browserLocale = typeof navigator === "undefined" ? null : navigator.language;
  return errorBoundaryCopy[resolveErrorBoundaryLocale(documentLocale, browserLocale)];
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
export class IsolatedErrorBoundary extends Component<IsolatedBoundaryProps, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
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
