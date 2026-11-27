// ui/Listbox with N rows, uncontrolled, as a recent-items list uses it.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { Listbox } from "../../../src/ui/Listbox";
import { caseItems, type VisibleListCase } from "./case";

function ListboxCaseRow({ label }: { label: string }) {
  return <span>{label}</span>;
}

let changeOne = () => {};

function CaseListbox({ n }: { n: number }) {
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
    <Listbox
      items={items}
      getKey={(item) => item.id}
      textValue={(item) => item.label}
      renderItem={(item) => <ListboxCaseRow label={item.label} />}
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
    const style = document.createElement("style");
    style.textContent = ".case-list { height: 320px; overflow: auto; } .ui-listbox-row { height: 28px; }";
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
