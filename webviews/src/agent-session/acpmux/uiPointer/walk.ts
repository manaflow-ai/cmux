// The UI inspector's keyboard walk (arrow keys while picking): Up goes to the parent, Down back to
// the child the walk came up from (else the first child), Left and Right to the previous and next
// sibling. Only elements that draw a box count, and never the picker's own overlay.

export type WalkDirection = "up" | "down" | "left" | "right";

const draws = (element: Element) => element.getClientRects().length > 0;

/**
 * The element one step from `from`, or null when there is none that way. `trail` is the children
 * the walk came up from, innermost last; the caller keeps it (push on Up, clear on a hover or a
 * sideways step), and Down takes its last entry when that is still a child of `from`.
 */
export function walkFrom(
  from: Element,
  direction: WalkDirection,
  trail: readonly Element[],
  ours: (element: Element) => boolean,
): Element | null {
  const usable = (element: Element | null) => element !== null && !ours(element) && draws(element);
  switch (direction) {
    case "up": {
      const parent = from.parentElement;
      return parent && parent !== from.ownerDocument.documentElement ? parent : null;
    }
    case "down": {
      const back = trail.at(-1);
      if (back && back.parentElement === from && usable(back)) return back;
      for (const child of from.children) if (usable(child)) return child;
      return null;
    }
    default: {
      const step = (element: Element) =>
        direction === "left" ? element.previousElementSibling : element.nextElementSibling;
      for (let sibling = step(from); sibling; sibling = step(sibling)) if (usable(sibling)) return sibling;
      return null;
    }
  }
}
