// A list whose rows are inline JSX a parent maps, with no row component: nothing names a row, so
// only the row selector counts its renders. Its caller is uncompiled and keeps the hovered row in
// state, so a hover re-runs the map and redraws every mounted row (it does not window).
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { caseItems, type VisibleListCase } from "./case";

let changeOne = () => {};

function CaseInlineRows({ n }: { n: number }) {
  "use no memo";
  const [items, setItems] = useState(() => caseItems(n));
  const [hovered, setHovered] = useState(-1);
  useEffect(() => {
    changeOne = () =>
      setItems((previous) =>
        previous.map((item, index) => (index === 2 ? { ...item, label: `${item.label}!` } : item)),
      );
  }, []);
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a listbox of plain rows.
    <div className="case-list" role="listbox" aria-label="Items">
      {items.map((item, index) => (
        <div
          key={item.id}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a row of the listbox above.
          role="option"
          tabIndex={-1}
          aria-selected={index === hovered}
          onMouseMove={() => setHovered(index)}
        >
          {item.label}
        </div>
      ))}
    </div>
  );
}

const inlineRowsCase: VisibleListCase = {
  mount(root, n) {
    const style = document.createElement("style");
    style.textContent = ".case-list { height: 320px; overflow: auto; } .case-list > div { height: 28px; }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<CaseInlineRows n={n} />));
    const list = () => root.querySelector<HTMLElement>(".case-list")!;
    return {
      rowSelector: '[role="option"]',
      rowComponents: [],
      scroller: list,
      list,
      changeOne: () => changeOne(),
    };
  },
};
export default inlineRowsCase;
