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
  /** Above the fold: fetch the default (dark) variant at high priority. */
  eager?: boolean;
  className?: string;
}) {
  // Captures are 1100x720 window shots from the fleet capture rig, with a
  // 720px variant. Phones (<= 640px wide) always get the 720px file: at any
  // device pixel ratio it is sharp enough for a ~340px-wide image and half
  // the bytes. Each theme has its own <picture>; a lazy image inside a
  // display:none element is never fetched, so a visitor downloads only their
  // theme's variant. The dark variant (the site default) is the only one
  // fetched eagerly above the fold.
  const variant = (theme: "light" | "dark", visible: string) => {
    const isEager = eager && theme === "dark";
    return (
      <picture className={visible}>
        <source media="(max-width: 640px)" srcSet={`/next/${name}-${theme}-720.webp`} />
        <img
          src={`/next/${name}-${theme}.webp`}
          srcSet={`/next/${name}-${theme}-720.webp 720w, /next/${name}-${theme}.webp 1100w`}
          sizes="(min-width: 1152px) 1100px, calc(100vw - 3rem)"
          width={1100}
          height={720}
          // Both carry the alt: the display:none variant is out of the
          // accessibility tree, so screen readers hear it once.
          alt={alt}
          decoding="async"
          loading={isEager ? "eager" : "lazy"}
          fetchPriority={isEager ? "high" : undefined}
          className="block h-auto w-full rounded-[10px]"
        />
      </picture>
    );
  };
  return (
    <div
      className={`overflow-hidden rounded-[10px] ring-1 ring-black/10 shadow-[0_1px_2px_rgba(0,0,0,0.06),0_12px_40px_-12px_rgba(0,0,0,0.25)] dark:ring-white/10 dark:shadow-[0_1px_2px_rgba(0,0,0,0.5),0_16px_48px_-16px_rgba(0,0,0,0.8)] ${className}`}
    >
      {variant("light", "block dark:hidden")}
      {variant("dark", "hidden dark:block")}
    </div>
  );
}
