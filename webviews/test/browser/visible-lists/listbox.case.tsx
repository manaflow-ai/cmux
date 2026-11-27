// ui/Listbox with N rows, uncontrolled, as a recent-items list uses it. `?spacerKeys=1` keys the
// rows "space-0", "space-1", … as a caller's getKey may. `?numbered=1` draws each row's place, with a
// callback whose identity stays put, and `window.__reorder()` moves the fifth row to the top.
// `?scale=` lays the rows out at the interface scale (scale.ts).
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { Listbox } from "../../../src/ui/Listbox";
import { caseItems, type VisibleListCase } from "./case";
import { applyCaseScale } from "./scale";

function ListboxCaseRow({ label }: { label: string }) {
  return <span>{label}</span>;
}

let changeOne = () => {};
const params = new URLSearchParams(location.search);
const spacerKeys = params.get("spacerKeys") === "1";
const numbered = params.get("numbered") === "1";

type CaseItem = ReturnType<typeof caseItems>[number];
const drawPlace = (item: CaseItem, index: number) => <ListboxCaseRow label={`${index + 1}. ${item.label}`} />;

function CaseListbox({ n }: { n: number }) {
  const [items, setItems] = useState(() => caseItems(n));
  // In an effect, not at render: a component that writes outside itself at render is one the
  // compiler leaves uncompiled, and its callbacks would change every render.
  useEffect(() => {
    changeOne = () =>
      setItems((previous) =>
        previous.map((item, index) => (index === 2 ? { ...item, label: `${item.label}!` } : item)),
      );
    (window as unknown as { __reorder(): void }).__reorder = () =>
      setItems((previous) => [previous[4]!, ...previous.slice(0, 4), ...previous.slice(5)]);
  }, []);
  return (
    <Listbox
      items={items}
      // `?spacerKeys=1`: the caller's keys are the ones the list once gave its spacers.
      getKey={spacerKeys ? (item) => `space-${item.id.slice(3)}` : (item) => item.id}
      textValue={(item) => item.label}
      renderItem={numbered ? drawPlace : (item) => <ListboxCaseRow label={item.label} />}
      label="Items"
      onOpen={(item) => {
        (window as unknown as { __submitted: string[] }).__submitted.push(item.id);
      }}
      autoFocus={false}
      className="case-list"
    />
  );
}

const listboxCase: VisibleListCase = {
  mount(root, n) {
    (window as unknown as { __submitted: string[] }).__submitted = [];
    applyCaseScale();
    const style = document.createElement("style");
    style.textContent =
      ".case-list { height: 320px; overflow: auto; } .ui-listbox-row { height: calc(28px * var(--cmux-interface-scale, 1)); }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<CaseListbox n={n} />));
    const list = () => root.querySelector<HTMLElement>(".case-list")!;
    return {
      rowSelector: '[role="option"]',
      rowComponents: ["ListboxRow", "ListboxCaseRow"],
      scroller: list,
      list,
      changeOne: () => changeOne(),
    };
  },
};
export default listboxCase;
