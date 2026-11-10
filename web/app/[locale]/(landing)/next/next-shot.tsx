/** One real cmux NEXT capture, in light and dark, swapped by the site theme. */
export function NextShot({
  name,
  alt,
  eager = false,
  className = "",
}: {
  /** File stem under `/public/next`, e.g. `hero` for `hero-light.webp`. */
  name: string;
  alt: string;
  /** Load at once (above the fold); everything else waits for the viewport. */
  eager?: boolean;
  className?: string;
}) {
  // Captures are 1100x720 window shots from the fleet capture rig. Each theme
  // gets its own <img>: a display:none lazy image is never fetched, so a
  // visitor downloads only the variant for their theme below the fold.
  const common = {
    width: 1100,
    height: 720,
    alt,
    decoding: "async" as const,
    loading: eager ? ("eager" as const) : ("lazy" as const),
    sizes: "(min-width: 1152px) 1100px, calc(100vw - 3rem)",
    className: "block h-auto w-full rounded-[10px]",
  };
  return (
    <div
      className={`overflow-hidden rounded-[10px] ring-1 ring-black/10 shadow-[0_1px_2px_rgba(0,0,0,0.06),0_12px_40px_-12px_rgba(0,0,0,0.25)] dark:ring-white/10 dark:shadow-[0_1px_2px_rgba(0,0,0,0.5),0_16px_48px_-16px_rgba(0,0,0,0.8)] ${className}`}
    >
      <img
        {...common}
        src={`/next/${name}-light.webp`}
        srcSet={`/next/${name}-light-720.webp 720w, /next/${name}-light.webp 1100w`}
        className={`${common.className} dark:hidden`}
      />
      <img
        {...common}
        src={`/next/${name}-dark.webp`}
        srcSet={`/next/${name}-dark-720.webp 720w, /next/${name}-dark.webp 1100w`}
        className={`${common.className} hidden dark:block`}
        alt=""
        aria-hidden="true"
      />
    </div>
  );
}
