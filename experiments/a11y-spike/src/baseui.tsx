import { useState, type KeyboardEvent } from "react";
import { Autocomplete } from "@base-ui/react/autocomplete";
import { Menu } from "@base-ui/react/menu";
import { Toolbar } from "@base-ui/react/toolbar";
import { Tooltip } from "@base-ui/react/tooltip";
import { DirectionProvider } from "@base-ui/react/direction-provider";
import type { ReactNode } from "react";
import { COMMITS, SOURCES, TOOLS, list, parent, report, type Entry } from "./fs";
import { NONMODAL, RTL } from "./fs";

export function Providers({ children }: { children: ReactNode }) {
  return <DirectionProvider direction={RTL ? "rtl" : "ltr"}>{children}</DirectionProvider>;
}

function SourceMenu() {
  return (
    <Menu.Root modal={!NONMODAL}>
      <Menu.Trigger className="trigger">Source</Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner>
          <Menu.Popup className="popup menu">
            {SOURCES.map((s) => <Menu.Item key={s} className="item" onClick={() => report(`source: ${s}`)}>{s}</Menu.Item>)}
            <Menu.SubmenuRoot>
              <Menu.SubmenuTrigger className="item">Committed</Menu.SubmenuTrigger>
              <Menu.Portal>
                <Menu.Positioner>
                  <Menu.Popup className="popup menu">
                    {COMMITS.map((c) => <Menu.Item key={c} className="item" onClick={() => report(`source: ${c}`)}>{c}</Menu.Item>)}
                  </Menu.Popup>
                </Menu.Positioner>
              </Menu.Portal>
            </Menu.SubmenuRoot>
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}

function PathPicker() {
  const [dir, setDir] = useState("/");
  const [entries, setEntries] = useState<Entry[] | null>(null);
  const [query, setQuery] = useState("");
  const [loaded, setLoaded] = useState<string | null>(null);
  const [highlighted, setHighlighted] = useState<Entry | undefined>();
  if (loaded !== dir) {
    setLoaded(dir);
    setEntries(null);
    void list(dir).then((items) => setEntries(items));
  }
  const go = (path: string) => { setQuery(""); setDir(path); };
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "ArrowRight" && highlighted?.dir) {
      event.preventDefault();
      go(highlighted.path);
    } else if (event.key === "ArrowLeft" || (event.key === "Backspace" && query === "")) {
      if (event.key === "ArrowLeft" && event.currentTarget.selectionStart !== 0) return;
      event.preventDefault();
      go(parent(dir));
    }
  };
  const choose = (row: Entry) => (row.dir ? go(row.path) : report(`chose: ${row.path}`));
  return (
    <div className="picker">
      <Autocomplete.Root
        inline
        open
        items={entries ?? []}
        value={query}
        onValueChange={setQuery}
        itemToStringValue={(e: Entry) => e.name}
        autoHighlight="always"
        keepHighlight
        onItemHighlighted={(e) => setHighlighted(e)}
      >
        <label className="field">
          <span className="crumb">{dir}</span>
          <Autocomplete.Input aria-label="Path" className="input" onKeyDown={onKeyDown} />
        </label>
        <Autocomplete.Empty className="empty">{entries ? "No matches" : "Loading…"}</Autocomplete.Empty>
        <Autocomplete.List className="list" aria-label={`Contents of ${dir}`}>
          {(e: Entry) => (
            <Autocomplete.Item key={e.path} value={e} className="item" onClick={() => choose(e)}>
              {e.dir ? `${e.name}/` : e.name}
            </Autocomplete.Item>
          )}
        </Autocomplete.List>
      </Autocomplete.Root>
    </div>
  );
}

function DiffTools() {
  return (
    <Tooltip.Provider delay={300}>
      <Toolbar.Root aria-label="Diff tools" className="toolbar">
        {TOOLS.map((tool) => (
          <Tooltip.Root key={tool.id}>
            <Tooltip.Trigger
              render={<Toolbar.Button aria-label={tool.label} className="tool" onClick={() => report(`tool: ${tool.id}`)} />}
            >
              {tool.id.slice(0, 1).toUpperCase()}
            </Tooltip.Trigger>
            <Tooltip.Portal>
              <Tooltip.Positioner>
                <Tooltip.Popup className="tooltip">{tool.label}</Tooltip.Popup>
              </Tooltip.Positioner>
            </Tooltip.Portal>
          </Tooltip.Root>
        ))}
      </Toolbar.Root>
    </Tooltip.Provider>
  );
}

export function App() {
  return <><SourceMenu /><PathPicker /><DiffTools /></>;
}
