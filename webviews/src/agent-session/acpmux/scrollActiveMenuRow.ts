/** Keep the keyboard's active option visible inside the menu's own scroll container. */
export function scrollActiveMenuRow(menu: HTMLElement | null, id: string): void {
  const row = menu?.ownerDocument.getElementById(id);
  if (row && menu?.contains(row)) row.scrollIntoView?.({ block: "nearest" });
}
