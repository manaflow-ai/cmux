/** Finds the exact docs item, then falls back to the deepest ancestor item. */
export function docsPagerItemIndex(
  items: readonly { href: string }[],
  pathname: string,
): number {
  const exactIndex = items.findIndex((item) => item.href === pathname);
  if (exactIndex >= 0) return exactIndex;

  let ancestorIndex = -1;
  let ancestorLength = -1;
  items.forEach((item, index) => {
    if (
      pathname.startsWith(`${item.href}/`) &&
      item.href.length > ancestorLength
    ) {
      ancestorIndex = index;
      ancestorLength = item.href.length;
    }
  });
  return ancestorIndex;
}

/** Returns adjacent docs items only when the current path belongs to the docs nav. */
export function docsPagerAdjacentItems<T extends { href: string }>(
  items: readonly T[],
  pathname: string,
): { prev: T | null; next: T | null } {
  const index = docsPagerItemIndex(items, pathname);
  if (index < 0) return { prev: null, next: null };

  return {
    prev: index > 0 ? items[index - 1] : null,
    next: index < items.length - 1 ? items[index + 1] : null,
  };
}
