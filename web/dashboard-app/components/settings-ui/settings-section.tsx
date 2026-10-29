import type { ReactNode } from "react";

/** Title block at the top of a settings page. */
export function SettingsPageHeader({
  title,
  description,
  actions,
}: {
  readonly title: string;
  readonly description?: string;
  readonly actions?: ReactNode;
}) {
  return (
    <div className="mb-4 flex flex-col gap-2 border-b border-border pb-3 sm:flex-row sm:items-end sm:justify-between">
      <div className="min-w-0">
        <h1 className="text-sm font-medium">{title}</h1>
        {description ? <p className="mt-1 max-w-2xl text-muted">{description}</p> : null}
      </div>
      {actions ? <div className="flex shrink-0 gap-2">{actions}</div> : null}
    </div>
  );
}

/**
 * One settings row: title and description on the left, controls on the
 * right; stacked on narrow screens. Mirrors Hexclave's account settings
 * `Section`, with an optional danger tone.
 */
export function SettingsSection({
  title,
  description,
  children,
  tone = "default",
  id,
}: {
  readonly title: string;
  readonly description?: ReactNode;
  readonly children: ReactNode;
  readonly tone?: "default" | "danger";
  readonly id?: string;
}) {
  return (
    <section
      id={id}
      aria-label={title}
      className={`flex flex-col gap-3 border p-3 sm:flex-row sm:items-start sm:gap-6 ${
        tone === "danger" ? "border-red-600/40 dark:border-red-400/40" : "border-border"
      }`}
    >
      <div className="min-w-0 sm:flex-1">
        <h2
          className={`text-sm font-medium ${tone === "danger" ? "text-red-600 dark:text-red-400" : ""}`}
        >
          {title}
        </h2>
        {description ? <div className="mt-1 text-xs text-muted">{description}</div> : null}
      </div>
      <div className="flex min-w-0 flex-col gap-2 sm:flex-1 sm:items-end">{children}</div>
    </section>
  );
}

/** Vertical stack of sections with consistent spacing. */
export function SettingsStack({ children }: { readonly children: ReactNode }) {
  return <div className="flex flex-col gap-3">{children}</div>;
}

/** A full-width block (tables, lists) with a header row. */
export function SettingsPanel({
  title,
  description,
  actions,
  children,
}: {
  readonly title: string;
  readonly description?: ReactNode;
  readonly actions?: ReactNode;
  readonly children: ReactNode;
}) {
  return (
    <section aria-label={title} className="flex flex-col gap-2">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h2 className="text-sm font-medium">{title}</h2>
          {description ? <div className="mt-1 text-xs text-muted">{description}</div> : null}
        </div>
        {actions ? <div className="flex shrink-0 flex-wrap gap-2">{actions}</div> : null}
      </div>
      {children}
    </section>
  );
}
