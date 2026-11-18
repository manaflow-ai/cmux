// ui/Listbox with N rows, controlled (the highlight in the caller's state, as an editor-owned
// suggestion list keeps it), its renderItem and itemAttributes inline arrows that change identity
// on every render, and its renderItem reading a per-id suffix map from the caller's state (not the
// item): a highlight move re-renders the caller, and so passes new callbacks to every row.
// `?stable=1`: the callbacks are module functions instead (stable, as a compiled caller's are),
// and each call draws a new style object and handler, which no comparison by value matches.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { Listbox } from "../../../src/ui/Listbox";
import { caseItems, type VisibleListCase } from "./case";

function ListboxInlineRow({ label, tone }: { label: string; tone?: { opacity: number }; onPick?(): void }) {
  return <span style={tone}>{label}</span>;
}

const stable = new URLSearchParams(location.search).get("stable") === "1";
type CaseItem = ReturnType<typeof caseItems>[number];
const drawStable = (item: CaseItem) => (
  <ListboxInlineRow label={item.label} tone={{ opacity: 1 }} onPick={() => item.id} />
);
const attributesStable = (item: CaseItem) => ({ "data-item": item.id });

let changeOne = () => {};
let setSuffix = (_id: string, _suffix: string) => {};

function CaseListbox({ n }: { n: number }) {
  // A caller the compiler leaves uncompiled (as many are): its arrows are new on every render.
  "use no memo";
  const [items, setItems] = useState(() => caseItems(n));
  const [active, setActive] = useState(0);
  const [suffixes, setSuffixes] = useState<Record<string, string>>({});
  // In an effect, not at render (see listbox.case.tsx).
  useEffect(() => {
    changeOne = () =>
      setItems((previous) =>
        previous.map((item, index) => (index === 2 ? { ...item, label: `${item.label}!` } : item)),
      );
    setSuffix = (id, suffix) => setSuffixes((previous) => ({ ...previous, [id]: suffix }));
  }, []);
  return (
    <Listbox
      items={items}
      getKey={(item) => item.id}
      textValue={(item) => item.label}
      renderItem={
        stable ? drawStable : (item) => <ListboxInlineRow label={`${item.label}${suffixes[item.id] ?? ""}`} />
      }
      itemAttributes={stable ? attributesStable : (item) => ({ "data-item": item.id })}
      label="Items"
      activeIndex={active}
      onActiveIndexChange={setActive}
      onOpen={(item) => {
        (window as unknown as { __submitted: string[] }).__submitted.push(item.id);
      }}
      autoFocus={false}
      className="case-list"
    />
  );
}

const listboxInlineCase: VisibleListCase = {
  mount(root, n) {
    const scope = window as unknown as { __submitted: string[]; __setSuffix(id: string, suffix: string): void };
    scope.__submitted = [];
    scope.__setSuffix = (id, suffix) => flushSync(() => setSuffix(id, suffix));
    const style = document.createElement("style");
    style.textContent = ".case-list { height: 320px; overflow: auto; } .ui-listbox-row { height: 28px; }";
    document.head.append(style);
    flushSync(() => createRoot(root).render(<CaseListbox n={n} />));
    const list = () => root.querySelector<HTMLElement>(".case-list")!;
    return {
      rowSelector: '[role="option"]',
      rowComponents: ["ListboxRow", "ListboxInlineRow"],
      scroller: list,
      list,
      changeOne: () => changeOne(),
    };
  },
};
export default listboxInlineCase;
