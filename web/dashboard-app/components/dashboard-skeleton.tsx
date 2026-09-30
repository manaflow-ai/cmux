export type SectionSkeletonVariant =
  /** A 2-column grid of cards (dashboard home-style panels). */
  | "cards"
  /** Settings sections: title and description left, a control right. */
  | "settings"
  /** A table with a header row; pass `columns`. */
  | "table"
  /** One bordered panel with a title, two lines, and a button (billing, TestFlight). */
  | "panel"
  /** Stacked device cards with a row of facts (Cloud Mac access, mobile devices). */
  | "devices"
  /** The team members page: member table, invite box, pending list. */
  | "members"
  /** A plain bordered list of rows (teams list). */
  | "list"
  /** Legacy alias of `table` with four columns. */
  | "rows";

type DashboardSkeletonProps = {
  readonly variant?: SectionSkeletonVariant;
  readonly columns?: number;
  readonly rows?: number;
};

/**
 * A whole page placeholder: header lines plus a section. Only for the first
 * load of the signed-in frame, before any page header exists; pages render
 * their real header and use `DashboardSectionSkeleton` below it.
 */
export function DashboardSkeleton({ variant = "cards", columns, rows }: DashboardSkeletonProps) {
  return (
    <div
      aria-hidden="true"
      className="mx-auto w-full max-w-5xl px-3 py-4"
    >
      <div className="mb-4 border-b border-border pb-3">
        <SkeletonBlock className="h-3 w-16" />
        <SkeletonBlock className="mt-2 h-4 w-32" />
        <SkeletonBlock className="mt-2 h-3 w-full max-w-lg" />
      </div>
      <DashboardSectionSkeleton variant={variant} columns={columns} rows={rows} />
    </div>
  );
}

/**
 * The placeholder for one data region below a page header that is already
 * on screen. The variant matches the shape of what will appear, so nothing
 * jumps when the data lands.
 */
export function DashboardSectionSkeleton({ variant = "cards", columns = 4, rows = 5 }: DashboardSkeletonProps) {
  return (
    <div aria-hidden="true" data-testid="dashboard-section-skeleton" data-variant={variant}>
      {sectionSkeleton(variant, columns, rows)}
    </div>
  );
}

function sectionSkeleton(variant: SectionSkeletonVariant, columns: number, rows: number) {
  switch (variant) {
    case "settings":
      return <SettingsSkeleton rows={Math.min(rows, 3)} />;
    case "table":
      return <TableSkeleton columns={columns} rows={rows} />;
    case "rows":
      return <TableSkeleton columns={4} rows={rows} header={false} />;
    case "panel":
      return <PanelSkeleton />;
    case "devices":
      return <DevicesSkeleton />;
    case "members":
      return <MembersSkeleton />;
    case "list":
      return <ListSkeleton rows={Math.min(rows, 4)} />;
    case "cards":
      return <CardsSkeleton />;
  }
}

function CardsSkeleton() {
  return (
    <div className="grid gap-3 md:grid-cols-2">
      {Array.from({ length: 4 }).map((_, index) => (
        <section key={index} className="border border-border p-3">
          <SkeletonBlock className="h-4 w-24" />
          <SkeletonBlock className="mt-3 h-3 w-full" />
          <SkeletonBlock className="mt-2 h-3 w-5/6" />
          <SkeletonBlock className="mt-4 h-8 w-28" />
        </section>
      ))}
    </div>
  );
}

function SettingsSkeleton({ rows }: { readonly rows: number }) {
  return (
    <div className="grid gap-3">
      {Array.from({ length: rows }).map((_, index) => (
        <section key={index} className="flex flex-col gap-3 border border-border p-3 sm:flex-row sm:items-start sm:gap-6">
          <div className="sm:flex-1">
            <SkeletonBlock className="h-4 w-28" />
            <SkeletonBlock className="mt-2 h-3 w-56 max-w-full" />
          </div>
          <SkeletonBlock className="h-7 w-24 sm:self-end" />
        </section>
      ))}
    </div>
  );
}

function TableSkeleton({ columns, rows, header = true }: { readonly columns: number; readonly rows: number; readonly header?: boolean }) {
  const template = { gridTemplateColumns: `repeat(${Math.max(1, columns)}, minmax(0, 1fr))` };
  return (
    <div className="border border-border">
      {header ? (
        <div className="hidden gap-3 border-b border-border px-3 py-2 md:grid" style={template}>
          {Array.from({ length: columns }).map((_, index) => (
            <SkeletonBlock key={index} className="h-3 w-16" />
          ))}
        </div>
      ) : null}
      {Array.from({ length: rows }).map((_, row) => (
        <div key={row} className="grid gap-3 border-b border-border px-3 py-3 last:border-b-0" style={template}>
          {Array.from({ length: columns }).map((_, column) => (
            <SkeletonBlock key={column} className={column === 0 ? "h-4 w-32" : "h-4 w-20"} />
          ))}
        </div>
      ))}
    </div>
  );
}

function PanelSkeleton() {
  return (
    <section className="border border-border p-3">
      <SkeletonBlock className="h-4 w-32" />
      <SkeletonBlock className="mt-3 h-3 w-full max-w-md" />
      <SkeletonBlock className="mt-2 h-3 w-2/3 max-w-sm" />
      <SkeletonBlock className="mt-4 h-8 w-32" />
    </section>
  );
}

function DevicesSkeleton() {
  return (
    <div className="space-y-3">
      {Array.from({ length: 2 }).map((_, index) => (
        <section key={index} className="border border-border p-3">
          <div className="flex items-start justify-between gap-3">
            <div>
              <SkeletonBlock className="h-4 w-36" />
              <SkeletonBlock className="mt-2 h-3 w-48" />
            </div>
            <SkeletonBlock className="h-7 w-7" />
          </div>
          <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {Array.from({ length: 4 }).map((_, fact) => (
              <div key={fact}>
                <SkeletonBlock className="h-3 w-16" />
                <SkeletonBlock className="mt-2 h-3 w-24" />
              </div>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}

function MembersSkeleton() {
  return (
    <div className="grid gap-4">
      <div>
        <SkeletonBlock className="h-4 w-20" />
        <SkeletonBlock className="mt-2 h-3 w-16" />
        <div className="mt-2">
          <TableSkeleton columns={3} rows={2} />
        </div>
      </div>
      <PanelSkeleton />
      <ListSkeleton rows={2} />
    </div>
  );
}

function ListSkeleton({ rows }: { readonly rows: number }) {
  return (
    <div className="divide-y divide-border border border-border">
      {Array.from({ length: rows }).map((_, index) => (
        <div key={index} className="flex items-center gap-3 px-3 py-2.5">
          <SkeletonBlock className="h-7 w-7" />
          <SkeletonBlock className="h-4 w-40" />
          <span className="flex-1" />
          <SkeletonBlock className="h-4 w-12" />
        </div>
      ))}
    </div>
  );
}

/** A small inline pill placeholder, for a badge that loads beside static text. */
export function SkeletonPill({ className = "h-5 w-12" }: { readonly className?: string }) {
  return <span aria-hidden="true" className={`inline-block animate-pulse bg-code-bg align-middle ${className}`} />;
}

/** One line of text that has not loaded, inside running text or a dialog. */
export function SkeletonLine({ className = "w-full" }: { readonly className?: string }) {
  return <span aria-hidden="true" className={`block h-3 animate-pulse bg-code-bg ${className}`} />;
}

function SkeletonBlock({ className }: { className: string }) {
  return (
    <div
      className={`animate-pulse bg-code-bg ${className}`}
    />
  );
}
