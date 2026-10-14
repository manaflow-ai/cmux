// The composer strip's measurements (ComposerStrip.tsx, composerStrip.css).
//
// Width: the attached variants (`tab`, `gooey`) hug their items. The strip's content row
// (.acpmux-composer-context) takes its natural width, capped at the room the card leaves
// (`--acpmux-strip-room`), so its size never depends on the strip's; a ResizeObserver reads it and
// sets `--acpmux-strip-width` on the form, a registered length the stylesheet transitions, so the
// strip, the card's seam under it and the fillets beside it move together. Nothing else in the
// layout changes: the strip's height is fixed, and the card and the transcript never move.
//
// Fit: when the items would leave the folder and machine less than LEADING_MIN, the
// lower-priority items collapse first: the subagents to one "N subagents" chip (level 1), then the
// pull request chip drops its title (level 2). The folder and machine keep their own truncation.
import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import type { ComposerStripVariant } from "./composerStrip.experiment";

export type StripLevel = 0 | 1 | 2;

/// The room the folder and machine keep before the items collapse.
const LEADING_MIN = 150;

const px = (value: number) => `${Math.round(value * 100) / 100}px`;

/// The collapse level for the strip holding `items`; `contentKey` names what the items show (a
/// new key measures again from level 0).
export function useStripLayout(
  items: RefObject<HTMLElement | null>,
  variant: ComposerStripVariant,
  contentKey: string,
): StripLevel {
  const [space, setSpace] = useState<number>();
  const hugs = variant === "tab" || variant === "gooey";
  useLayoutEffect(() => {
    const node = items.current;
    const context = node?.closest<HTMLElement>(".acpmux-composer-context");
    const strip = context?.closest<HTMLElement>(".acpmux-composer-strip");
    const form = strip?.parentElement;
    if (!node || !context || !strip || !form) return;
    const measure = () => {
      const style = getComputedStyle(form);
      const inner = form.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
      const stripStyle = getComputedStyle(strip);
      const room = inner - parseFloat(stripStyle.marginLeft) - parseFloat(stripStyle.marginRight);
      if (hugs) {
        form.style.setProperty("--acpmux-strip-room", px(room));
        form.style.setProperty("--acpmux-strip-width", px(context.getBoundingClientRect().width));
      }
      const contextStyle = getComputedStyle(context);
      const padding = parseFloat(contextStyle.paddingLeft) + parseFloat(contextStyle.paddingRight);
      const gap = parseFloat(contextStyle.columnGap) || 0;
      const branch = context.querySelector<HTMLElement>(":scope > .acpmux-location-picker");
      const branchWidth = branch ? branch.getBoundingClientRect().width + gap : 0;
      setSpace(Math.floor(room - padding - branchWidth - gap - LEADING_MIN));
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(form);
    observer.observe(context);
    // Transitions start after the first measured frame: a strip that appears draws at its width.
    const frame = requestAnimationFrame(() => form.setAttribute("data-strip-ready", ""));
    return () => {
      observer.disconnect();
      cancelAnimationFrame(frame);
      form.removeAttribute("data-strip-ready");
      form.style.removeProperty("--acpmux-strip-room");
      form.style.removeProperty("--acpmux-strip-width");
    };
  }, [items, hugs]);

  const [level, setLevel] = useState<StripLevel>(0);
  // The items' width at each level, for the content they show now.
  const widths = useRef<{ key: string; at: (number | undefined)[] }>({ key: "", at: [] });
  useLayoutEffect(() => {
    const node = items.current;
    if (!node) return;
    if (widths.current.key !== contentKey) widths.current = { key: contentKey, at: [] };
    widths.current.at[level] = node.getBoundingClientRect().width;
    if (space === undefined) return;
    for (const candidate of [0, 1, 2] as const) {
      const width = widths.current.at[candidate];
      // Not measured yet: draw it (before paint) to measure it.
      if (width === undefined || width <= space || candidate === 2) {
        if (candidate !== level) setLevel(candidate);
        return;
      }
    }
  }, [items, contentKey, level, space]);
  return level;
}
