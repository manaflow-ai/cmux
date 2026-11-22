// ui/VirtualList with N rows whose row component is memoized and takes the list's `style`, as the
// Tasks, Bookmarks and All chats rows can.
import { memo, useEffect, useState, type CSSProperties } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { VirtualList } from "../../../src/ui/VirtualList";
import { caseItems, type VisibleListCase } from "./case";

const VirtualCaseRow = memo(function VirtualCaseRow({ label, style }: { label: string; style: CSSProperties }) {
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a row of the listbox.
    <div role="option" aria-selected={false} style={style}>
      {label}
    </div>
  );
});

let changeOne = () => {};

function CaseVirtualList({ n }: { n: number }) {
  const [items, setItems] = useState(() => caseItems(n));
  // In an effect, not at render: a component that writes outside itself at render is one the
  // compiler leaves uncompiled, and its callbacks would change every render.
  useEffect(() => {
    changeOne = () =>
      setItems((previous) =>
        previous.map((item, index) => (index === 2 ? { ...item, label: `${item.label}!` } : item)),
      );
  }, []);
  return (
    <VirtualList
      count={items.length}
      estimateSize={() => 28}
      renderRow={(index, style) => <VirtualCaseRow key={items[index]!.id} label={items[index]!.label} style={style} />}
      className="case-list"
      label="Items"
    />
  );
}

const virtualListCase: VisibleListCase = {
  mount(root, n) {
    const style = document.createElement("style");
    style.textContent = ".case-list { height: 320px; }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<CaseVirtualList n={n} />));
    const list = () => root.querySelector<HTMLElement>(".case-list")!;
    return {
      rowSelector: '[role="option"]',
      rowComponents: ["VirtualCaseRow"],
      scroller: list,
      list,
      changeOne: () => changeOne(),
    };
  },
};
export default virtualListCase;
