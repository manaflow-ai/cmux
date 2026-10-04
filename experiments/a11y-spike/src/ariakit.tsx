import { useState, type KeyboardEvent } from "react";
import {
  Combobox, ComboboxItem, ComboboxList, ComboboxProvider, Menu, MenuButton, MenuItem, MenuProvider,
  Toolbar, ToolbarItem, Tooltip, TooltipAnchor, TooltipProvider,
} from "@ariakit/react";
import { COMMITS, SOURCES, TOOLS, list, parent, report, type Entry } from "./fs";
import { RTL } from "./fs";
import type { ReactNode } from "react";

// Ariakit has no direction provider; each composite takes `rtl`.
export function Providers({ children }: { children: ReactNode }) {
  return <>{children}</>;
}

function SourceMenu() {
  return (
    <MenuProvider>
      <MenuButton className="trigger">Source</MenuButton>
      <Menu className="popup menu" gutter={4}>
        {SOURCES.map((s) => <MenuItem key={s} className="item" onClick={() => report(`source: ${s}`)}>{s}</MenuItem>)}
        <MenuProvider placement={RTL ? "left-start" : "right-start"}>
          <MenuButton className="item" render={<MenuItem />}>Committed</MenuButton>
          <Menu className="popup menu">
            {COMMITS.map((c) => <MenuItem key={c} className="item" onClick={() => report(`source: ${c}`)}>{c}</MenuItem>)}
          </Menu>
        </MenuProvider>
      </Menu>
    </MenuProvider>
  );
}

function PathPicker() {
  const [dir, setDir] = useState("/");
  const [entries, setEntries] = useState<Entry[] | null>(null);
  const [query, setQuery] = useState("");
  const [loaded, setLoaded] = useState<string | null>(null);
  const [activeId, setActiveId] = useState<string | null | undefined>();
  if (loaded !== dir) {
    setLoaded(dir);
    setEntries(null);
    void list(dir).then((items) => setEntries(items));
  }
  const rows = (entries ?? []).filter((e) => e.name.toLowerCase().includes(query.toLowerCase()));
  const highlighted = rows.find((e) => e.path === activeId);
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
  return (
    <div className="picker">
      <ComboboxProvider open value={query} setValue={setQuery} setActiveId={setActiveId} includesBaseElement={false}>
        <label className="field">
          <span className="crumb">{dir}</span>
          <Combobox aria-label="Path" className="input" autoSelect="always" onKeyDown={onKeyDown} />
        </label>
        <ComboboxList className="list" aria-label={`Contents of ${dir}`} alwaysVisible>
          {entries === null ? <div className="empty">Loading…</div> : null}
          {rows.map((e) => (
            <ComboboxItem key={e.path} id={e.path} className="item" setValueOnClick={false}
              onClick={() => (e.dir ? go(e.path) : report(`chose: ${e.path}`))}>
              {e.dir ? `${e.name}/` : e.name}
            </ComboboxItem>
          ))}
        </ComboboxList>
      </ComboboxProvider>
    </div>
  );
}

function DiffTools() {
  return (
    <Toolbar aria-label="Diff tools" className="toolbar" rtl={RTL}>
      {TOOLS.map((tool) => (
        <TooltipProvider key={tool.id} showTimeout={300}>
          <TooltipAnchor render={<ToolbarItem aria-label={tool.label} className="tool" onClick={() => report(`tool: ${tool.id}`)} />}>
            {tool.id.slice(0, 1).toUpperCase()}
          </TooltipAnchor>
          <Tooltip className="tooltip">{tool.label}</Tooltip>
        </TooltipProvider>
      ))}
    </Toolbar>
  );
}

export function App() {
  return <><SourceMenu /><PathPicker /><DiffTools /></>;
}
