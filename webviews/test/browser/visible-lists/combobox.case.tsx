// ui/Combobox inline with N suggestions and no pinned actions, as the project chooser uses it:
// the caller filters on each key.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { Combobox } from "../../../src/ui/Combobox";
import { caseItems, type VisibleListCase } from "./case";

function ComboboxCaseRow({ label }: { label: string }) {
  return <span>{label}</span>;
}

let changeOne = () => {};

function CaseCombobox({ n, pinned }: { n: number; pinned: boolean }) {
  const [items, setItems] = useState(() => caseItems(n));
  const [query, setQuery] = useState("");
  // In an effect, not at render: a component that writes outside itself at render is one the
  // compiler leaves uncompiled, and its callbacks would change every render.
  useEffect(() => {
    changeOne = () =>
      setItems((previous) =>
        previous.map((item, index) => (index === 2 ? { ...item, label: `${item.label}!` } : item)),
      );
  }, []);
  const labels = new Map(items.map((item) => [item.id, item.label]));
  const suggestions = items.filter((item) => item.label.includes(query)).map((item) => item.id);
  return (
    <Combobox
      inline
      suggestions={pinned ? [...suggestions, "new"] : suggestions}
      pinnedSuggestions={pinned ? ["new"] : undefined}
      onQuery={setQuery}
      onSubmit={(value) => {
        (window as unknown as { __submitted: string[] }).__submitted.push(value);
      }}
      onCancel={() => {}}
      cancelOnBlur={false}
      label="Items"
      renderItem={(id) => <ComboboxCaseRow label={labels.get(id) ?? id} />}
      listClassName="case-list"
    />
  );
}

export function comboboxCase(pinned: boolean): VisibleListCase {
  return {
    mount(root, n) {
      (window as unknown as { __submitted: string[] }).__submitted = [];
      const style = document.createElement("style");
      style.textContent =
        ".case-list { max-height: 320px; overflow: auto; } .ui-combobox-item { height: 28px; box-sizing: border-box; }";
      document.head.append(style);
      flushSync(() => createRoot(root).render(<CaseCombobox n={n} pinned={pinned} />));
      const scroller = () =>
        root.querySelector<HTMLElement>(".ui-combobox-viewport") ?? root.querySelector<HTMLElement>(".case-list")!;
      return {
        rowSelector: '[role="option"]',
        rowComponents: ["ComboboxOption", "ComboboxCaseRow"],
        scroller,
        list: () => root,
        filter: () => root.querySelector<HTMLElement>("input")!,
        changeOne: () => changeOne(),
      };
    },
  };
}

export default comboboxCase(false);
