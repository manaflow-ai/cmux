import type { ReactNode } from "react";

import type { AuthIntl } from "./auth-intl";

/**
 * The frame every cmux auth screen shares.
 *
 * It is a server component on purpose: the sign-in page is the slowest step in
 * every cold funnel we have, so nothing here may pull the React runtime into
 * the critical path. Colours come from the same tokens as the dashboard the
 * visitor is about to land in, which is why the card follows the system theme.
 */
export function AuthCard({
  intl,
  title,
  subtitle,
  children,
  footer,
}: {
  intl: AuthIntl;
  title: string;
  subtitle?: string;
  children: ReactNode;
  footer?: ReactNode;
}) {
  return (
    <main
      className="flex min-h-screen flex-col items-center justify-center bg-background px-6 py-12 text-foreground"
      dir={intl.direction}
      lang={intl.locale}
    >
      <section className="w-full max-w-[22rem]">
        <div className="mb-8 flex items-center gap-2.5">
          {/* A plain <img> keeps the mark inside the first HTML response.
              next/image would add a loader round trip on the one page whose
              whole point is painting before anything else runs. */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src="/logo.png"
            alt=""
            width={28}
            height={28}
            className="rounded-md"
          />
          <span className="text-[15px] font-semibold tracking-tight">cmux</span>
        </div>
        <h1 className="text-xl font-semibold tracking-tight">{title}</h1>
        {subtitle ? (
          <p className="mt-1.5 text-[13px] leading-5 text-muted">{subtitle}</p>
        ) : null}
        <div className="mt-7">{children}</div>
        {footer ? (
          <div className="mt-6 text-[13px] text-muted">{footer}</div>
        ) : null}
      </section>
    </main>
  );
}

/** A single failure line. Auth errors are never stacked or dismissible. */
export function AuthError({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <p
      role="alert"
      data-auth-error
      className="mb-4 border border-border bg-code-bg px-3 py-2 text-[13px] leading-5 text-foreground"
    >
      {message}
    </p>
  );
}

export function AuthDivider({ label }: { label: string }) {
  return (
    <div className="my-5 flex items-center gap-3" aria-hidden>
      <span className="h-px flex-1 bg-border" />
      <span className="text-[11px] uppercase tracking-[0.14em] text-muted">
        {label}
      </span>
      <span className="h-px flex-1 bg-border" />
    </div>
  );
}
