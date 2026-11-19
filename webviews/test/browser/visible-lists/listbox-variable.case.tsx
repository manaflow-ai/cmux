// ui/Listbox with N rows of different heights, as the steer queue's are: every third row has a
// second line. `?zoom=1.1` lays the page out at 110 percent (fractional row heights), and
// `window.__growRow(index)` gives a row a third line after it mounted.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { Listbox } from "../../../src/ui/Listbox";
import { caseItems, type VisibleListCase } from "./case";

function VariableCaseRow({ label, lines }: { label: string; lines: number }) {
  return (
    <span style={{ display: "flex", flexDirection: "column", lineHeight: "17px" }}>
      {Array.from({ length: lines }, (_, line) => (
        <span key={line}>{line === 0 ? label : `${label} line ${line + 1}`}</span>
      ))}
    </span>
  );
}

function CaseListbox({ n }: { n: number }) {
  const [items] = useState(() => caseItems(n));
  const [grown, setGrown] = useState<ReadonlySet<string>>(new Set());
  useEffect(() => {
    (window as unknown as { __growRow(index: number): void }).__growRow = (index) =>
      setGrown((previous) => new Set(previous).add(`id-${index}`));
  }, []);
  return (
    <Listbox
      items={items}
      getKey={(item) => item.id}
      textValue={(item) => item.label}
      renderItem={(item, index) => (
        <VariableCaseRow label={item.label} lines={(index % 3 === 0 ? 2 : 1) + (grown.has(item.id) ? 1 : 0)} />
      )}
      label="Items"
      onOpen={(item) => {
        (window as unknown as { __submitted: string[] }).__submitted.push(item.id);
      }}
      autoFocus={false}
      className="case-list"
    />
  );
}

const listboxVariableCase: VisibleListCase = {
  mount(root, n) {
    (window as unknown as { __submitted: string[] }).__submitted = [];
    const zoom = new URLSearchParams(location.search).get("zoom");
    if (zoom) document.documentElement.style.zoom = zoom;
    const style = document.createElement("style");
    style.textContent = ".case-list { height: 320px; overflow: auto; } .ui-listbox-row { padding: 3px 8px; }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<CaseListbox n={n} />));
    const list = () => root.querySelector<HTMLElement>(".case-list")!;
    return {
      rowSelector: '[role="option"]',
      rowComponents: ["ListboxRow", "VariableCaseRow"],
      scroller: list,
      list,
    };
  },
};
export default listboxVariableCase;
