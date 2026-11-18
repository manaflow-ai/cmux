// ui/Combobox inline with N suggestions and no pinned actions, as the project chooser uses it:
// the caller filters on each key. `?vary=1` gives every third row a second line (rows of two
// heights), `window.__removeItem(id)` takes an item out of the open list, and `?start=K` opens it
// with the first K items until `window.__grow()` hands it all N (suggestions arriving late).
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { Combobox } from "../../../src/ui/Combobox";
import { caseItems, type VisibleListCase } from "./case";

function ComboboxCaseRow({ label, lines }: { label: string; lines: number }) {
  return lines === 1 ? (
    <span>{label}</span>
  ) : (
    <span style={{ display: "flex", flexDirection: "column" }}>
      <span>{label}</span>
      <span>{label} line 2</span>
    </span>
  );
}

let changeOne = () => {};
const params = new URLSearchParams(location.search);
const vary = params.get("vary") === "1";
const start = params.has("start") ? Number(params.get("start")) : undefined;

function CaseCombobox({ n, pinned }: { n: number; pinned: boolean }) {
  const [items, setItems] = useState(() => caseItems(Math.min(n, start ?? n)));
  const [query, setQuery] = useState("");
  // In an effect, not at render: a component that writes outside itself at render is one the
  // compiler leaves uncompiled, and its callbacks would change every render.
  useEffect(() => {
    changeOne = () =>
      setItems((previous) =>
        previous.map((item, index) => (index === 2 ? { ...item, label: `${item.label}!` } : item)),
      );
    (window as unknown as { __removeItem(id: string): void }).__removeItem = (id) =>
      setItems((previous) => previous.filter((item) => item.id !== id));
    (window as unknown as { __grow(): void }).__grow = () => setItems(caseItems(n));
  }, [n]);
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
      renderItem={(id) => (
        <ComboboxCaseRow label={labels.get(id) ?? id} lines={vary && Number(id.slice(3)) % 3 === 0 ? 2 : 1} />
      )}
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
        ".case-list { max-height: 320px; overflow: auto; } .ui-combobox-item { box-sizing: border-box; }" +
        (vary ? " .ui-combobox-item { line-height: 18px; padding: 5px 8px; }" : " .ui-combobox-item { height: 28px; }");
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
