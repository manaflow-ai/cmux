// Radix has no combobox or listbox primitive, so this build carries the menu and the toolbar only.
import { Direction, DropdownMenu, Toolbar, Tooltip } from "radix-ui";
import type { ReactNode } from "react";
import { COMMITS, SOURCES, TOOLS, report } from "./fs";
import { RTL } from "./fs";

export function Providers({ children }: { children: ReactNode }) {
  return <Direction.Provider dir={RTL ? "rtl" : "ltr"}>{children}</Direction.Provider>;
}

function SourceMenu() {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger className="trigger">Source</DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content className="popup menu">
          {SOURCES.map((s) => <DropdownMenu.Item key={s} className="item" onSelect={() => report(`source: ${s}`)}>{s}</DropdownMenu.Item>)}
          <DropdownMenu.Sub>
            <DropdownMenu.SubTrigger className="item">Committed</DropdownMenu.SubTrigger>
            <DropdownMenu.Portal>
              <DropdownMenu.SubContent className="popup menu">
                {COMMITS.map((c) => <DropdownMenu.Item key={c} className="item" onSelect={() => report(`source: ${c}`)}>{c}</DropdownMenu.Item>)}
              </DropdownMenu.SubContent>
            </DropdownMenu.Portal>
          </DropdownMenu.Sub>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

function DiffTools() {
  return (
    <Tooltip.Provider delayDuration={300}>
      <Toolbar.Root aria-label="Diff tools" className="toolbar">
        {TOOLS.map((tool) => (
          <Tooltip.Root key={tool.id}>
            <Tooltip.Trigger asChild>
              <Toolbar.Button aria-label={tool.label} className="tool" onClick={() => report(`tool: ${tool.id}`)}>
                {tool.id.slice(0, 1).toUpperCase()}
              </Toolbar.Button>
            </Tooltip.Trigger>
            <Tooltip.Portal>
              <Tooltip.Content className="tooltip">{tool.label}</Tooltip.Content>
            </Tooltip.Portal>
          </Tooltip.Root>
        ))}
      </Toolbar.Root>
    </Tooltip.Provider>
  );
}

export function App() {
  return <><SourceMenu /><DiffTools /></>;
}
