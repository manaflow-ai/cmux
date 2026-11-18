import { useCallback } from "react";
import { Button } from "../../../ui/Button";

export type JumpItem = { id: string; label: string };

/**
 * The bar of a page's parts, pinned to the top of the content on glass: one button per part, the
 * current one filled. Only Personalization shows it (category pages are short enough without one,
 * standup 2026-11-11). When the parts do not fit, the bar scrolls sideways, fades the edge that
 * hides more, and keeps the current one in view.
 */
/** Scrolls the bar sideways (never the page) until the current button shows in full. */
function showInBar(button: HTMLButtonElement | null) {
  const bar = button?.parentElement;
  if (!button || !bar) return;
  const start = button.offsetLeft - bar.clientWidth / 2 + button.offsetWidth / 2;
  if (button.offsetLeft < bar.scrollLeft || button.offsetLeft + button.offsetWidth > bar.scrollLeft + bar.clientWidth)
    bar.scrollLeft = Math.max(0, start);
}

export function JumpBar({
  items,
  current,
  label,
  onJump,
}: {
  items: readonly JumpItem[];
  current: string | null;
  label: string;
  onJump: (id: string) => void;
}) {
  // Which edges hide buttons: `data-more-start` and `data-more-end` fade them (layout.css).
  const bar = useCallback((node: HTMLElement | null) => {
    if (!node) return;
    const mark = () => {
      node.toggleAttribute("data-more-start", node.scrollLeft > 1);
      node.toggleAttribute("data-more-end", node.scrollLeft + node.clientWidth < node.scrollWidth - 1);
    };
    mark();
    const resize = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(mark);
    resize?.observe(node);
    node.addEventListener("scroll", mark, { passive: true });
    return () => {
      resize?.disconnect();
      node.removeEventListener("scroll", mark);
    };
  }, []);
  return (
    <nav className="jump-bar" aria-label={label} data-jump-bar="" ref={bar}>
      {items.map((item) => (
        <Button
          key={item.id}
          ref={current === item.id ? showInBar : undefined}
          type="button"
          variant="ghost"
          className="button jump-link"
          data-jump={item.id}
          aria-current={current === item.id ? "true" : undefined}
          onClick={() => onJump(item.id)}
        >
          {item.label}
        </Button>
      ))}
    </nav>
  );
}
