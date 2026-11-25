// One page menu at a time (the snooze, scope and category menus), under the button that opened it.
import { useState, type MouseEvent, type ReactNode } from "react";
import { PageMenu, type PageMenuItem } from "../shared/PageMenu";

export interface OpenMenu {
  session: number;
  x: number;
  y: number;
  items: PageMenuItem[];
  returnFocus: HTMLElement | null;
}

/** One page menu at a time, under the button that opened it. */
export function useButtonMenu(): [ReactNode, (event: MouseEvent<HTMLElement>, items: PageMenuItem[]) => void] {
  const [menu, setMenu] = useState<OpenMenu | null>(null);
  const [session, setSession] = useState(0);
  const open = (event: MouseEvent<HTMLElement>, items: PageMenuItem[]) => {
    const rect = event.currentTarget.getBoundingClientRect();
    setSession(session + 1);
    setMenu({ session: session + 1, x: rect.left, y: rect.bottom + 4, items, returnFocus: event.currentTarget });
  };
  const node = menu ? (
    <PageMenu
      key={menu.session}
      x={menu.x}
      y={menu.y}
      items={menu.items}
      returnFocus={menu.returnFocus}
      onClose={() => setMenu(null)}
    />
  ) : null;
  return [node, open];
}
