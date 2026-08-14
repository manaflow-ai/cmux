type DashboardSkeletonProps = {
  variant?: "cards" | "rows";
};

export function DashboardSkeleton({ variant = "cards" }: DashboardSkeletonProps) {
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

      {variant === "rows" ? (
        <div className="border border-border">
          {Array.from({ length: 5 }).map((_, index) => (
            <div
              key={index}
              className="grid gap-3 border-b border-border p-3 last:border-b-0 md:grid-cols-[1.2fr_1fr_1fr_auto]"
            >
              <SkeletonBlock className="h-4 w-28" />
              <SkeletonBlock className="h-4 w-36" />
              <SkeletonBlock className="h-4 w-24" />
              <SkeletonBlock className="h-7 w-16" />
            </div>
          ))}
        </div>
      ) : (
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
      )}
    </div>
  );
}

function SkeletonBlock({ className }: { className: string }) {
  return (
    <div
      className={`animate-pulse bg-code-bg ${className}`}
    />
  );
}
