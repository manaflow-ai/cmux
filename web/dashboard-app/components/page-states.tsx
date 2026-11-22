"use client";

import { QueryErrorResetBoundary } from "@tanstack/react-query";
import { useTranslations } from "next-intl";
import { Component, type ReactNode, Suspense, useState } from "react";
import { reportBoundaryError } from "@/app/components/error-boundary";
import { refusalMessageKind } from "../lib/refusal-message";
import { settingsButtonClass } from "./settings-ui/styles";

/**
 * A data region that failed to load: what failed, one sentence on why, and
 * Try again. The page header and navigation stay on screen around it.
 */
export function SectionError({
  error,
  section,
  reason,
  onRetry,
}: {
  readonly error: unknown;
  /** Names what did not load, e.g. the page title. Generic when absent. */
  readonly section?: string;
  /** Replaces the sentence derived from `error`, for sources that are not RPC calls. */
  readonly reason?: string;
  readonly onRetry?: () => unknown;
}) {
  const t = useTranslations("dashboard.states");
  const [retrying, setRetrying] = useState(false);
  const retry = onRetry
    ? async () => {
      setRetrying(true);
      try {
        await onRetry();
      } finally {
        setRetrying(false);
      }
    }
    : null;
  return (
    <section
      role="alert"
      data-testid="section-error"
      className="flex flex-wrap items-start justify-between gap-3 border border-border p-3"
    >
      <div className="min-w-0 flex-1">
        <h2 className="text-sm font-medium">{section ? t("errorTitle", { section }) : t("errorTitleGeneric")}</h2>
        <p className="mt-1 max-w-2xl text-xs text-muted">{reason ?? t(`reason.${refusalMessageKind(error)}`)}</p>
      </div>
      {retry ? (
        <button
          type="button"
          disabled={retrying}
          onClick={() => void retry()}
          className={settingsButtonClass("secondary", "sm")}
        >
          {retrying ? t("retrying") : t("retry")}
        </button>
      ) : null}
    </section>
  );
}

/** A data region with nothing in it yet: what would be here, and how to add it. */
export function EmptyState({
  title,
  body,
  action,
}: {
  readonly title: string;
  readonly body?: ReactNode;
  readonly action?: ReactNode;
}) {
  return (
    <section data-testid="empty-state" className="flex flex-wrap items-start justify-between gap-3 border border-border p-4">
      <div className="min-w-0 flex-1">
        <h2 className="text-sm font-medium">{title}</h2>
        {body ? <p className="mt-1 max-w-2xl text-xs text-muted">{body}</p> : null}
      </div>
      {action ? <div className="shrink-0">{action}</div> : null}
    </section>
  );
}

/**
 * A data region that reads suspense queries: `skeleton` while they load,
 * `SectionError` with Try again if one fails. Try again clears the failed
 * queries so they refetch when the region mounts again.
 */
export function QuerySection({
  skeleton,
  section,
  name,
  children,
}: {
  readonly skeleton: ReactNode;
  readonly section?: string;
  /** Reported with a caught error so failures group by region. */
  readonly name: string;
  readonly children: ReactNode;
}) {
  return (
    <QueryErrorResetBoundary>
      {({ reset }) => (
        <SectionBoundary name={name} section={section} onReset={reset}>
          <Suspense fallback={skeleton}>{children}</Suspense>
        </SectionBoundary>
      )}
    </QueryErrorResetBoundary>
  );
}

type SectionBoundaryProps = {
  readonly name: string;
  readonly section?: string;
  readonly onReset: () => void;
  readonly children: ReactNode;
};

class SectionBoundary extends Component<SectionBoundaryProps, { error: unknown; failed: boolean }> {
  state = { error: null as unknown, failed: false };

  static getDerivedStateFromError(error: unknown) {
    return { error, failed: true };
  }

  componentDidCatch(error: unknown) {
    reportBoundaryError(this.props.name, error);
  }

  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <SectionError
        error={this.state.error}
        section={this.props.section}
        onRetry={() => {
          this.props.onReset();
          this.setState({ error: null, failed: false });
        }}
      />
    );
  }
}
