"use client";

import Image, { type ImageProps } from "next/image";
import { useCallback, useState } from "react";

type RevealImageProps = ImageProps & {
  /** Upward travel distance while hidden, in pixels. Set 0 for fade-only. */
  rise?: number;
  /** Stagger offset in ms, e.g. index * 60 for a grid cascade. */
  delay?: number;
  /** Fade/rise duration in ms. */
  duration?: number;
};

// Image that fades and gently rises in when it scrolls into view, the reveal
// the marketing home page uses for its screenshots. An IntersectionObserver
// drives it rather than the image load event: next/image routes its onLoad
// through an effect-populated ref, so lazily-loaded gallery images regularly
// finished loading without ever firing onLoad and stayed stuck invisible. The
// observer is reliable for any count of below-the-fold images, and because its
// callback runs after the first paint, the opacity/transform transition always
// plays (above-the-fold images included) instead of snapping to visible.
export function RevealImage({
  rise = 12,
  delay = 0,
  duration = 700,
  className,
  style,
  alt,
  ...imageProps
}: RevealImageProps) {
  const [revealed, setRevealed] = useState(false);

  // Callback ref (no useEffect). Runs on the client only; refs are not invoked
  // during SSR. Disconnects after the first intersection so it fires once.
  const observeRef = useCallback((node: HTMLImageElement | null) => {
    if (!node || typeof IntersectionObserver === "undefined") {
      // No observer support: reveal immediately so the image is never stuck.
      if (node) setRevealed(true);
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          setRevealed(true);
          observer.disconnect();
        }
      },
      // Trigger once the image is a little way into the viewport, not at the
      // very first pixel, so the rise reads as a deliberate entrance.
      { rootMargin: "0px 0px -10% 0px" },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  return (
    <Image
      {...imageProps}
      alt={alt}
      ref={observeRef}
      style={{
        transitionProperty: "opacity, transform",
        transitionTimingFunction: "ease-out",
        transitionDuration: `${duration}ms`,
        transitionDelay: `${delay}ms`,
        opacity: revealed ? 1 : 0,
        transform: revealed ? "none" : `translateY(${rise}px)`,
        ...style,
      }}
      // Users who prefer reduced motion see the image immediately, no movement.
      className={`motion-reduce:opacity-100! motion-reduce:translate-y-0! motion-reduce:transition-none! ${className ?? ""}`}
    />
  );
}
