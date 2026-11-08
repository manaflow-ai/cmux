const shellClass = "terminal-selection-active";
const ownerClass = "terminal-selection-owner";

export function beginTerminalSelection(host: HTMLElement, selection: Selection | null = window.getSelection()): void {
  const shell = host.closest<HTMLElement>(".app-shell");
  if (!shell) return;
  for (const owner of shell.querySelectorAll(`.${ownerClass}`)) owner.classList.remove(ownerClass);
  selection?.removeAllRanges();
  host.classList.add(ownerClass);
  shell.classList.add(shellClass);
}

export function clampTerminalSelection(host: HTMLElement, selection: Selection | null = window.getSelection()): void {
  if (!selection || selection.isCollapsed || !host.classList.contains(ownerClass)) return;
  const anchor = selection.anchorNode;
  const focus = selection.focusNode;
  const grid = host.querySelector<HTMLElement>(".render-grid");
  if (!anchor || !focus || !grid || !grid.contains(anchor) || grid.contains(focus)) return;

  const walker = document.createTreeWalker(grid, NodeFilter.SHOW_TEXT);
  const first = walker.nextNode();
  let last = first;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) last = node;
  if (!first || !last) return;

  const focusPrecedesGrid = Boolean(grid.compareDocumentPosition(focus) & Node.DOCUMENT_POSITION_PRECEDING);
  const endpoint = focusPrecedesGrid ? first : last;
  const offset = focusPrecedesGrid ? 0 : (endpoint.textContent?.length ?? 0);
  selection.setBaseAndExtent(anchor, selection.anchorOffset, endpoint, offset);
}

export function releaseTerminalSelection(host: HTMLElement): void {
  if (!host.classList.contains(ownerClass)) return;
  host.classList.remove(ownerClass);
  host.closest<HTMLElement>(".app-shell")?.classList.remove(shellClass);
}
