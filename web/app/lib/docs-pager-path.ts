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
