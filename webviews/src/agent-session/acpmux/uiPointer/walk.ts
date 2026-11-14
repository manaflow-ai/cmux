// The UI inspector's keyboard walk (arrow keys while picking): Up goes to the parent, Down back to
// the child the walk came up from (else the first child), Left and Right to the previous and next
// sibling. Only elements that draw a box count, and never the picker's own overlay: a wrapper with
// no box of its own (`display: contents`) is stepped through, so Up takes the nearest ancestor that
// draws and Down the nearest descendants that draw, through such wrappers.

export type WalkDirection = "up" | "down" | "left" | "right";

const draws = (element: Element) => element.getClientRects().length > 0;

/// A wrapper that draws no box but lays out its children as its parent's (`display: contents`).
const passesThrough = (element: Element) =>
  element.ownerDocument.defaultView?.getComputedStyle(element).display === "contents";

/**
 * The element one step from `from`, or null when there is none that way. `trail` is the children
 * the walk came up from, innermost last; the caller keeps it (push on Up, clear on a hover or a
 * sideways step), and Down takes its last entry when Up from it still lands on `from`.
 */
export function walkFrom(
  from: Element,
  direction: WalkDirection,
  trail: readonly Element[],
  ours: (element: Element) => boolean,
): Element | null {
  const usable = (element: Element | null) => element !== null && !ours(element) && draws(element);
  const drawnParent = (element: Element) => {
    const root = element.ownerDocument.documentElement;
    for (let parent = element.parentElement; parent && parent !== root; parent = parent.parentElement)
      if (usable(parent)) return parent;
    return null;
  };
  switch (direction) {
    case "up":
      return drawnParent(from);
    case "down": {
      // Back down to where the walk came up from, when Up from there still lands on `from`.
      const back = trail.at(-1);
      if (back && usable(back) && drawnParent(back) === from) return back;
      return firstDrawn(from, usable);
    }
    default: {
      const step = (element: Element) =>
        direction === "left" ? element.previousElementSibling : element.nextElementSibling;
      for (let sibling = step(from); sibling; sibling = step(sibling)) if (usable(sibling)) return sibling;
      return null;
    }
  }
}

/// The first child of `parent` that is usable, looking inside the wrappers that draw no box of
/// their own (`display: contents`) in document order; a hidden child's subtree is never entered.
function firstDrawn(parent: Element, usable: (element: Element) => boolean): Element | null {
  for (const child of parent.children) {
    if (usable(child)) return child;
    if (passesThrough(child)) {
      const inner = firstDrawn(child, usable);
      if (inner) return inner;
    }
  }
  return null;
}
