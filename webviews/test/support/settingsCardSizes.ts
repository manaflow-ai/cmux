// Settings' page in jsdom, sized as a browser lays it out for the windowed cards (cardWindow.ts): an
// 800 px scroller (`main.content`) and each card row at its card's estimate (jsdom heights must
// equal the estimates: TanStack skips measuring at mount under jsdom).
export const SHARED_LINK_HEIGHT = 72;
export const KEY_HEIGHT = 96;

export function settingsCardSizes(element: HTMLElement): number {
  if (element.matches("main.content")) return 800;
  if (element.hasAttribute("data-shared-link")) return SHARED_LINK_HEIGHT;
  if (element.hasAttribute("data-key")) return KEY_HEIGHT;
  return 0;
}
