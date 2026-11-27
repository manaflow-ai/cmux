// ui/VirtualList under a filter field, as a picker uses it: typing narrows the N items and puts the
// highlight back on the first result (`activeIndex` 0); the field names it (aria-activedescendant).
import { useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { VirtualList } from "../../../src/ui/VirtualList";
import { caseItems, type VisibleListCase } from "./case";

function VirtualFilterRow({ id, label, active, style }: { id: string; label: string; active: boolean; style: object }) {
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a row of the listbox.
    <div id={id} role="option" aria-selected={active} style={style}>
      {label}
    </div>
  );
}

function CaseVirtualListFilter({ n }: { n: number }) {
  const [items] = useState(() => caseItems(n));
  const [query, setQuery] = useState("");
  const [highlight, setHighlight] = useState(0);
  const shown = query === "" ? items : items.filter((item) => item.label.includes(query));
  const active = Math.min(highlight, shown.length - 1);
  return (
    <>
      <input
        className="case-filter"
        aria-label="Filter"
        aria-controls="case-filter-list"
        aria-activedescendant={shown[active] ? `case-filter-row-${active}` : undefined}
        value={query}
        onChange={(event) => {
          setQuery(event.currentTarget.value);
          setHighlight(0);
        }}
      />
      <VirtualList
        id="case-filter-list"
        count={shown.length}
        estimateSize={() => 28}
        activeIndex={active}
        renderRow={(index, style) => (
          <VirtualFilterRow
            key={shown[index]!.id}
            id={`case-filter-row-${index}`}
            label={shown[index]!.label}
            active={index === active}
            style={style}
          />
        )}
        className="case-list"
        label="Items"
      />
    </>
  );
}

const virtualListFilterCase: VisibleListCase = {
  mount(root, n) {
    const style = document.createElement("style");
    style.textContent = ".case-list { height: 320px; }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<CaseVirtualListFilter n={n} />));
    const list = () => root.querySelector<HTMLElement>(".case-list")!;
    return {
      rowSelector: '[role="option"]',
      rowComponents: ["VirtualFilterRow"],
      scroller: list,
      list,
      filter: () => root.querySelector<HTMLElement>(".case-filter")!,
    };
  },
};
export default virtualListFilterCase;
