// One of Session Info's three blocks (ChatInspector.tsx), with its sections in the person's order
// (sectionOrder.ts). Each section's six-dot handle (InspectorSection's `ReorderHandle`) sits in the
// panel's left padding and shows only on hover or keyboard focus, so before any drag the panel is
// the one it was, pixel for pixel. Dragging the handle moves the section as the pointer passes the
// middle of its neighbours; Up and Down Arrow on the focused handle move it one place. Nothing else
// moves: no drag image, no placeholder, no animation.
import { createContext, Fragment, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { setGroupOrder, useGroupOrder, type InspectorGroupId } from "./sectionOrder";
import type { InspectorSectionId } from "./inspectorState";

type Reorder = {
  dragging: InspectorSectionId | undefined;
  start: (id: InspectorSectionId, event: React.PointerEvent<HTMLElement>) => void;
  step: (id: InspectorSectionId, by: -1 | 1) => void;
};

const ReorderContext = createContext<Reorder | undefined>(undefined);

/// The block's reorder actions, for a section inside it; none outside a block (the gallery's lone sections).
export function useReorder(): Reorder | undefined {
  return useContext(ReorderContext);
}

export function InspectorGroup({
  group,
  sections,
}: {
  group: InspectorGroupId;
  /// The block's sections by id; a falsy node is a section not shown.
  sections: Partial<Record<InspectorSectionId, ReactNode>>;
}) {
  const order = useGroupOrder(group);
  const shown = order.filter((id) => sections[id]);
  const block = useRef<HTMLDivElement>(null);
  const [dragging, setDragging] = useState<InspectorSectionId>();
  // The drag follows the pointer on the window, not the handle: moving the section moves the handle's
  // node, which would drop a pointer capture on it after the first swap. The listeners go with the drag.
  useEffect(() => {
    if (!dragging) return;
    const move = (event: PointerEvent) => {
      if (!block.current) return;
      const others = [...block.current.querySelectorAll<HTMLElement>(":scope > [data-section]")].filter(
        (section) => section.dataset.section !== dragging,
      );
      const at = others.filter((section) => {
        const box = section.getBoundingClientRect();
        return event.clientY > box.top + box.height / 2;
      }).length;
      const next = others.map((section) => section.dataset.section as InspectorSectionId);
      next.splice(at, 0, dragging);
      setGroupOrder(group, next);
    };
    const end = () => setDragging(undefined);
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", end);
    window.addEventListener("pointercancel", end);
    window.addEventListener("blur", end);
    return () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", end);
      window.removeEventListener("pointercancel", end);
      window.removeEventListener("blur", end);
    };
  }, [dragging, group]);
  const reorder: Reorder = {
    dragging,
    start: (id, event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      setDragging(id);
    },
    step: (id, by) => {
      const at = shown.indexOf(id);
      const to = at + by;
      if (at < 0 || to < 0 || to >= shown.length) return;
      const next = [...shown];
      next.splice(at, 1);
      next.splice(to, 0, id);
      setGroupOrder(group, next);
    },
  };
  return (
    <div ref={block} className="acpmux-chat-inspector-group" data-group={group}>
      <ReorderContext.Provider value={shown.length > 1 ? reorder : undefined}>
        {shown.map((id) => (
          <Fragment key={id}>{sections[id]}</Fragment>
        ))}
      </ReorderContext.Provider>
    </div>
  );
}
