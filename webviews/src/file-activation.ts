/**
 * Clicking a file row in the files tree acts on that file the way its header
 * bar does, through the same collapsed state:
 *
 * - collapsed: expand it and scroll its header to the top;
 * - expanded with its header in place (at the top of the viewer, or stuck
 *   there while the viewer is inside the file): collapse it, keeping the bar
 *   where it is;
 * - expanded elsewhere: scroll to it only.
 */
export type TreeFileActivation = "expand" | "collapse" | "scroll";

export function treeFileActivation(collapsed: boolean, headerInPlace: boolean): TreeFileActivation {
  if (collapsed) {
    return "expand";
  }
  return headerInPlace ? "collapse" : "scroll";
}

/**
 * The file path of a plain primary click (or a keyboard activation, which
 * the row buttons deliver as a click) on a FILE row of the Pierre tree, read
 * from the event's composed path because the rows live in the tree's shadow
 * root. Folder rows, sticky folder rows and modified clicks (range or
 * multi-select) return null and keep the tree's own behavior.
 */
export function treeFileRowPath(event: {
  button?: number;
  shiftKey?: boolean;
  metaKey?: boolean;
  ctrlKey?: boolean;
  altKey?: boolean;
  composedPath?: () => EventTarget[];
}): string | null {
  if ((event.button ?? 0) !== 0 || event.shiftKey || event.metaKey || event.ctrlKey || event.altKey) {
    return null;
  }
  for (const target of event.composedPath?.() ?? []) {
    const element = target as Element;
    if (typeof element.getAttribute !== "function" || element.getAttribute("data-type") !== "item") {
      continue;
    }
    if (element.getAttribute("data-item-type") !== "file" || element.hasAttribute("data-file-tree-sticky-row")) {
      return null;
    }
    return element.getAttribute("data-item-path");
  }
  return null;
}
