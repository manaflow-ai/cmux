import { useState, type KeyboardEvent } from "react";
import {
  I18nProvider, Autocomplete, Button, Input, Label, ListBox, ListBoxItem, Menu, MenuItem, MenuTrigger, Popover,
  SubmenuTrigger, TextField, Toolbar, Tooltip, TooltipTrigger, useFilter,
} from "react-aria-components";
import { COMMITS, RTL, SOURCES, TOOLS, list, parent, report, type Entry } from "./fs";
import type { ReactNode } from "react";

export function Providers({ children }: { children: ReactNode }) {
  return <I18nProvider locale={RTL ? "ar-AE" : "en-US"}>{children}</I18nProvider>;
}

export function SourceMenu() {
  return (
    <MenuTrigger>
      <Button className="trigger">Source</Button>
      <Popover className="popup">
        <Menu className="menu" onAction={(key) => report(`source: ${key}`)}>
          {SOURCES.map((s) => <MenuItem key={s} id={s} className="item">{s}</MenuItem>)}
          <SubmenuTrigger>
            <MenuItem className="item">Committed</MenuItem>
            <Popover className="popup">
              <Menu className="menu" onAction={(key) => report(`source: ${key}`)}>
                {COMMITS.map((c) => <MenuItem key={c} id={c} className="item">{c}</MenuItem>)}
              </Menu>
            </Popover>
          </SubmenuTrigger>
        </Menu>
      </Popover>
    </MenuTrigger>
  );
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
  const go = (path: string) => { setQuery(""); setDir(path); };
  // The highlighted row is the input's aria-activedescendant; RAC exposes no highlighted-key callback.
  const highlighted = (input: HTMLInputElement): Entry | undefined => {
    const id = input.getAttribute("aria-activedescendant");
    const key = id ? document.getElementById(id)?.dataset.key : undefined;
    return entries?.find((e) => e.path === key);
  };
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    const row = highlighted(event.currentTarget);
    if (event.key === "ArrowRight" && row?.dir) {
      event.preventDefault();
      go(row.path);
    } else if (event.key === "ArrowLeft" || (event.key === "Backspace" && query === "")) {
      if (event.key === "ArrowLeft" && event.currentTarget.selectionStart !== 0) return;
      event.preventDefault();
      go(parent(dir));
    }
  };
  return (
    <div className="picker">
      <Autocomplete inputValue={query} onInputChange={setQuery} filter={contains}>
        <TextField aria-label="Path" className="field">
          <Label className="crumb">{dir}</Label>
          <Input className="input" onKeyDown={onKeyDown} />
        </TextField>
        <ListBox
          className="list"
          aria-label={`Contents of ${dir}`}
          items={entries ?? []}
          renderEmptyState={() => (entries ? "No matches" : "Loading…")}
          onAction={(key) => {
            const row = entries?.find((e) => e.path === key);
            if (row?.dir) go(row.path); else if (row) report(`chose: ${row.path}`);
          }}
        >
          {(e) => <ListBoxItem id={e.path} textValue={e.name} className="item">{e.dir ? `${e.name}/` : e.name}</ListBoxItem>}
        </ListBox>
      </Autocomplete>
    </div>
  );
}

export function DiffTools() {
  return (
    <Toolbar aria-label="Diff tools" className="toolbar">
      {TOOLS.map((tool) => (
        <TooltipTrigger key={tool.id} delay={300}>
          <Button aria-label={tool.label} className="tool" onPress={() => report(`tool: ${tool.id}`)}>
            {tool.id.slice(0, 1).toUpperCase()}
          </Button>
          <Tooltip className="tooltip">{tool.label}</Tooltip>
        </TooltipTrigger>
      ))}
    </Toolbar>
  );
}

export function App() {
  return <><SourceMenu /><PathPicker /><DiffTools /></>;
}
