// A popover's notch (experiments.elevationLadder): the glass of a popover whose arrow is a smooth
// notch in its own outline (notchOutline.ts), drawn as one shape. The popup's own fill, frost and rim
// step aside (elevationLadder.css `[data-notch]`) and this layer, the popup's first child, draws them
// in the notched outline instead: the lift outside it, the frost and tint clipped to it, the
// hairline along it. The outline follows the popup's size and the anchor's place along the edge;
// one ResizeObserver and one MutationObserver (its side, its positioner's place) per open popover,
// and a re-render only when the outline changes.
import { useCallback, useId, useState, type ReactNode } from "react";
import { NOTCH_HEIGHT, NOTCH_WIDTH, notchEdgeForSide, notchOutlinePath, type NotchEdge } from "./notchOutline";

type Shape = { width: number; height: number; radius: number; edge: NotchEdge; offset: number };

const same = (a: Shape | undefined, b: Shape | undefined) =>
  a === b ||
  (a !== undefined &&
    b !== undefined &&
    a.width === b.width &&
    a.height === b.height &&
    a.radius === b.radius &&
    a.edge === b.edge &&
    Math.abs(a.offset - b.offset) < 0.5);

/**
 * The notch's layer for a popup: `ref` goes on the popup (Base UI's, which carries `data-side`),
 * `outline` is rendered as its first child. `readAnchor` returns the anchor's box in the viewport.
 */
export function useNotchOutline(
  on: boolean,
  readAnchor: () => DOMRect | undefined,
): {
  ref: (node: HTMLElement | null) => (() => void) | undefined;
  outline: ReactNode;
} {
  const [shape, setShape] = useState<Shape | undefined>();
  const filterId = `ui-notch-${useId().replace(/[^\w-]/g, "")}`;
  const ref = useCallback(
    (node: HTMLElement | null) => {
      if (!on || !node) return undefined;
      const measure = () => {
        const style = getComputedStyle(node);
        const edge = notchEdgeForSide(node.getAttribute("data-side"), style.direction === "rtl");
        const anchor = readAnchor();
        const box = node.getBoundingClientRect();
        const next: Shape | undefined =
          edge && anchor && node.offsetWidth > 0 && node.offsetHeight > 0
            ? {
                width: node.offsetWidth,
                height: node.offsetHeight,
                radius: Number.parseFloat(style.borderTopLeftRadius) || 0,
                edge,
                offset:
                  edge === "top" || edge === "bottom"
                    ? anchor.left + anchor.width / 2 - box.left
                    : anchor.top + anchor.height / 2 - box.top,
              }
            : undefined;
        setShape((current) => (same(current, next) ? current : next));
      };
      measure();
      const resize = new ResizeObserver(measure);
      resize.observe(node);
      const moves = new MutationObserver(measure);
      moves.observe(node, { attributes: true, attributeFilter: ["data-side"] });
      if (node.parentElement) moves.observe(node.parentElement, { attributes: true, attributeFilter: ["style"] });
      return () => {
        resize.disconnect();
        moves.disconnect();
      };
    },
    [on, readAnchor],
  );
  if (!on || !shape) return { ref, outline: null };
  const pad = NOTCH_HEIGHT;
  const width = shape.width + pad * 2;
  const height = shape.height + pad * 2;
  const d = notchOutlinePath(
    shape.width,
    shape.height,
    shape.radius,
    shape.edge,
    shape.offset,
    NOTCH_WIDTH,
    NOTCH_HEIGHT,
    pad,
  );
  const svg = { width, height, viewBox: `0 0 ${width} ${height}` };
  return {
    ref,
    outline: (
      <div className="ui-notch" aria-hidden="true" data-edge={shape.edge}>
        {/* The lift: the outline's blurred shadow, kept outside the outline so the glass stays clear. */}
        <svg className="ui-notch-lift" {...svg}>
          <filter id={filterId} x="-50%" y="-50%" width="200%" height="200%">
            {/* --elevation-2's geometry: down 2, a 6px blur (a standard deviation of half the blur). */}
            <feGaussianBlur in="SourceAlpha" stdDeviation="3" />
            <feOffset dy="2" result="blur" />
            <feFlood className="ui-notch-shade" />
            <feComposite in2="blur" operator="in" result="shadow" />
            <feComposite in="shadow" in2="SourceAlpha" operator="out" />
          </filter>
          <path d={d} filter={`url(#${filterId})`} />
        </svg>
        <div className="ui-notch-glass" style={{ clipPath: `path("${d}")` }} />
        <svg className="ui-notch-rim" {...svg}>
          <path d={d} />
        </svg>
      </div>
    ),
  };
}
