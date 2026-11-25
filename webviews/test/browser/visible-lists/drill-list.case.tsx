// ui/DrillList with a Locations section and a level of N rows, the page owning the highlight and the
// query as the path picker does (viewer-empty/PathPicker.tsx).
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { DrillList, type DrillSection } from "../../../src/ui/DrillList";
import { caseItems, type VisibleListCase } from "./case";

type Item = { id: string; label: string };

function DrillCaseRow({ label }: { label: string }) {
  return <span>{label}</span>;
}

const PLACES: Item[] = ["Home", "Desktop", "Documents", "Downloads"].map((label) => ({ id: `place-${label}`, label }));

let changeOne = () => {};

function CaseDrillList({ n }: { n: number }) {
  const [items, setItems] = useState(() => caseItems(n));
  const [query, setQuery] = useState("");
  const [highlight, setHighlight] = useState(0);
  // In an effect, not at render: a component that writes outside itself at render is one the
  // compiler leaves uncompiled, and its callbacks would change every render.
  useEffect(() => {
    changeOne = () =>
      setItems((previous) =>
        previous.map((item, index) => (index === 2 ? { ...item, label: `${item.label}!` } : item)),
      );
  }, []);
  const level = query ? items.filter((item) => item.label.includes(query)) : items;
  const sections: DrillSection<Item>[] = [
    { id: "locations", label: "Locations", items: query ? [] : PLACES },
    { id: "level", items: level },
  ];
  const submit = (item: Item | undefined) => {
    if (item) (window as unknown as { __submitted: string[] }).__submitted.push(item.id);
  };
  return (
    <DrillList<Item>
      sections={sections}
      getKey={(item) => item.id}
      renderItem={(item) => <DrillCaseRow label={item.label} />}
      itemAttributes={(item) => ({ "data-id": item.id })}
      highlight={highlight}
      onHighlight={setHighlight}
      query={query}
      onQueryChange={(value) => {
        setQuery(value);
        setHighlight(0);
      }}
      onEnter={() => {}}
      onUp={() => {}}
      onChoose={submit}
      onCancel={() => {}}
      onActivate={submit}
      label="Find"
      listLabel="Folder"
      autoFocus={false}
      listClassName="case-list"
      after={<div className="case-after">more</div>}
    />
  );
}

const drillListCase: VisibleListCase = {
  mount(root, n) {
    (window as unknown as { __submitted: string[] }).__submitted = [];
    const style = document.createElement("style");
    style.textContent =
      ".case-list { height: 320px; overflow: auto; } .ui-drill-row { height: 28px; box-sizing: border-box; }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<CaseDrillList n={n} />));
    const list = () => root.querySelector<HTMLElement>(".case-list")!;
    return {
      rowSelector: '[role="option"]',
      rowComponents: ["DrillRow", "DrillCaseRow"],
      scroller: list,
      list,
      filter: () => root.querySelector<HTMLElement>("input")!,
      changeOne: () => changeOne(),
    };
  },
};
export default drillListCase;
