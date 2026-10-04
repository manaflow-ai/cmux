// React Aria with the path picker built on ComboBox (role=combobox) instead of Autocomplete. The
// combo box state is read and driven through RAC's exported ComboBoxStateContext, so no role or
// arrow-key code is ours; only the picker's own drill keys (ArrowRight in, ArrowLeft/Backspace up).
import { useContext, useState, type KeyboardEvent } from "react";
import { ComboBox, ComboBoxStateContext, Input, Label, ListBox, ListBoxItem, useFilter, type Key } from "react-aria-components";
import { list, parent, report, type Entry } from "./fs";
import { DiffTools, SourceMenu } from "./rac";
export { Providers } from "./rac";

// Keeps the list open and the first row focused whenever a listing (or a filter) changes it.
function FocusFirst({ first }: { first: Key | null }) {
  const state = useContext(ComboBoxStateContext);
  const [seen, setSeen] = useState<Key | null | undefined>(undefined);
  if (state && first !== seen) {
    setSeen(first);
    queueMicrotask(() => {
      if (!state.isOpen) state.open(null, "manual");
      state.selectionManager.setFocusedKey(first);
    });
  }
  return null;
}

function DrillInput({ dir, entries, go, query }: { dir: string; entries: Entry[] | null; go(path: string): void; query: string }) {
  const state = useContext(ComboBoxStateContext);
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    const key = state?.selectionManager.focusedKey;
    const row = entries?.find((e) => e.path === key);
    if (event.key === "ArrowRight" && row?.dir) {
      event.preventDefault();
      go(row.path);
    } else if ((event.key === "ArrowLeft" && event.currentTarget.selectionStart === 0) || (event.key === "Backspace" && query === "")) {
      event.preventDefault();
      go(parent(dir));
    }
  };
  return <Input className="input" onKeyDown={onKeyDown} />;
}

function PathPicker() {
  const [dir, setDir] = useState("/");
  const [entries, setEntries] = useState<Entry[] | null>(null);
  const [query, setQuery] = useState("");
  const [loaded, setLoaded] = useState<string | null>(null);
  const { contains } = useFilter({ sensitivity: "base" });
  if (loaded !== dir) {
    setLoaded(dir);
    setEntries(null);
    void list(dir).then((items) => setEntries(items));
  }
  const rows = (entries ?? []).filter((e) => contains(e.name, query));
  const go = (path: string) => { setQuery(""); setDir(path); };
  return (
    <div className="picker">
      <ComboBox
        aria-label="Path"
        items={rows}
        inputValue={query}
        onInputChange={setQuery}
        selectedKey={null}
        menuTrigger="focus"
        allowsEmptyCollection
        onSelectionChange={(key) => {
          const row = rows.find((e) => e.path === key);
          if (row?.dir) go(row.path); else if (row) report(`chose: ${row.path}`);
        }}
      >
        <div className="field">
          <Label className="crumb">{dir}</Label>
          <DrillInput dir={dir} entries={entries} go={go} query={query} />
        </div>
        <FocusFirst first={rows[0]?.path ?? null} />
        <ListBox className="list" renderEmptyState={() => (entries ? "No matches" : "Loading…")}>
          {(e: Entry) => <ListBoxItem id={e.path} textValue={e.name} className="item">{e.dir ? `${e.name}/` : e.name}</ListBoxItem>}
        </ListBox>
      </ComboBox>
    </div>
  );
}

export function App() {
  return <><SourceMenu /><PathPicker /><DiffTools /></>;
}
