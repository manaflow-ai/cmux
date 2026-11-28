// l10n-allow-file: fixture rows, not shipped UI.
// The contract's reference: a list drawn as the contract asks, so the harness itself is checked to
// report nothing for one. Fixed 28 px rows; the rows in view and one view each side are mounted,
// the window moves with the scroll, and each row is memoized on its own item, its selection and
// stable callbacks, so an event renders only the rows it changed.
import { memo, useCallback, useState, type ReactNode } from "react";
import { listFixture } from "./listFixture";

const PITCH = 28;
type Item = { id: string; text: string };

const Row = memo(function Row({
  item,
  index,
  selected,
  onSelect,
}: {
  item: Item;
  index: number;
  selected: boolean;
  onSelect(index: number): void;
}) {
  return (
    <li
      className="reference-row"
      data-selected={selected || undefined}
      style={{ position: "absolute", top: index * PITCH, height: PITCH, insetInline: 0 }}
    >
      <button type="button" aria-pressed={selected} onClick={() => onSelect(index)}>
        {item.text}
      </button>
    </li>
  );
});

function ReferenceList({
  items,
  selected,
  onSelect,
}: {
  items: readonly Item[];
  selected: number | undefined;
  onSelect(index: number): void;
}) {
  const [view, setView] = useState({ top: 0, height: 600 });
  const measured = useCallback((node: HTMLDivElement | null) => {
    if (node) setView({ top: node.scrollTop, height: node.clientHeight });
  }, []);
  const first = Math.max(0, Math.floor((view.top - view.height) / PITCH));
  const last = Math.min(items.length, Math.ceil((view.top + 2 * view.height) / PITCH));
  const rows: ReactNode[] = [];
  for (let index = first; index < last; index++)
    rows.push(
      <Row
        key={items[index]!.id}
        item={items[index]!}
        index={index}
        selected={index === selected}
        onSelect={onSelect}
      />,
    );
  return (
    <div
      ref={measured}
      className="reference-list"
      style={{ flex: 1, overflow: "auto" }}
      onScroll={(event) => setView({ top: event.currentTarget.scrollTop, height: event.currentTarget.clientHeight })}
    >
      <ul style={{ position: "relative", height: items.length * PITCH, margin: 0, padding: 0, listStyle: "none" }}>
        {rows}
      </ul>
    </div>
  );
}

export default listFixture<Item>({
  source: "test/list-contract/reference.fixture.tsx#ReferenceList",
  rows: ".reference-row",
  scroller: ".reference-list",
  item: (index) => ({ id: `r${index}`, text: `Row ${index}` }),
  change: (item) => ({ ...item, text: `${item.text} (changed)` }),
  render: function Render({ items, selected, onSelect }) {
    return <ReferenceList items={items} selected={selected} onSelect={onSelect} />;
  },
});
