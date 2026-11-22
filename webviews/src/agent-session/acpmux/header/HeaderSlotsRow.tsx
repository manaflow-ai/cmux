import { useCallback, useRef, type ReactNode, type Ref } from "react";
import { headerItemProps, useHeaderSlots, type HeaderItemId } from "./headerSlots";

/// One registered item of the chat header (headerSlots.ts ``HEADER_ITEMS``), for a component whose own element the
/// slot cannot carry (it renders several, or none at times). Empty, it takes no place and no gap in its row.
export function HeaderItem({ id, children }: { id: HeaderItemId; children: ReactNode }) {
  return (
    <span className="acpmux-header-item" {...headerItemProps(id)}>
      {children}
    </span>
  );
}

/// The chat header as named slots (headerSlots.ts): `leading`, `title`, then the tools: the `accessory` items and the
/// `trailing` tools at the row's end. The trailing slot never moves for an accessory; useHeaderSlots gives the
/// accessories only the room it leaves. `toolsRef` is the tools' element (the tab row reports its width).
export function HeaderSlots({
  inTabRow,
  leading,
  title,
  accessory,
  trailing,
  toolsRef,
}: {
  inTabRow: boolean;
  leading?: ReactNode;
  title: ReactNode;
  accessory: ReactNode;
  trailing: ReactNode;
  toolsRef?: Ref<HTMLDivElement>;
}) {
  const header = useRef<HTMLElement>(null);
  const tools = useRef<HTMLDivElement>(null);
  const setTools = useCallback(
    (element: HTMLDivElement | null) => {
      tools.current = element;
      if (typeof toolsRef === "function") toolsRef(element);
      else if (toolsRef) (toolsRef as { current: HTMLDivElement | null }).current = element;
    },
    [toolsRef],
  );
  useHeaderSlots(header, tools);
  return (
    // In the tab row the native tabs draw over this band, so a tooltip stays out of it (ui/titleTooltips.ts
    // `data-tooltip-covered`).
    <header
      ref={header}
      className="acpmux-header"
      data-tab-row={inTabRow ? "" : undefined}
      data-tooltip-covered={inTabRow ? "" : undefined}
    >
      {leading}
      {title}
      <div className="acpmux-handoff-header-tools" ref={setTools}>
        {accessory}
        {trailing}
      </div>
    </header>
  );
}
