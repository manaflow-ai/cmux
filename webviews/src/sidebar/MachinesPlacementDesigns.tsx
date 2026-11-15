// l10n-allow-file: gallery design fixtures for where the Machines page lives, not shipped UI.
// The Machines page (design/machines-section.md, `cmux-page://cmux.machines/`) lost its home with the
// right sidebar (#41025). Each design here is one place for it, drawn around the real MachinesSection
// on its mock host: the native parts (the sidebar, Settings' list) are approximated from the sidebar
// spec (plans/cmux-next/spec-proposals/visuals/components/sidebar.md), the Machines list is the page.
//
// - `tile`: a Machines tile beside Home and App Store at the sidebar's top; it opens the page in the
//   window's content area, as Home and the App Store open theirs (TOP-SECTION-ITEMS-ARE-PAGES).
// - `section`: a collapsible Machines section in the sidebar, above the workspaces.
// - `settings`: a Machines list in Settings > Accounts and Devices.
import { useEffect, useState, type ReactNode } from "react";
import { Icon } from "../agent-session/acpmux/icons/Icon";
import { createStrings } from "../pages/shared/i18n";
import table from "../pages/machines/generated/strings.json";
import { MachinesSection } from "../pages/machines/MachinesSection";
import { MockMachinesProvider, joinedRows, sampleRows } from "../pages/machines/mockProvider";
import { MachinesStore } from "../pages/machines/store";
import type { MachinesSnapshot } from "../pages/machines/types";
import "./MachinesPlacementDesigns.css";

export type MachinesPlacement = "tile" | "section" | "settings";

export interface MachinesPlacementDesignsProps {
  placement: MachinesPlacement;
  /** `section`: the Machines section folded to its header. */
  collapsed?: boolean;
}

/** Every kind and state, and the joined Mac studio-mini with its controls shown (as on hover). */
const snapshot: MachinesSnapshot = {
  rows: [...sampleRows, ...joinedRows],
  style: "compact",
  busy: [],
  failed: {},
  openMenu: "m_mini",
};

const workspaces = [
  { id: "cmux", title: "cmux-next", selected: true },
  { id: "api", title: "api-server" },
  { id: "docs", title: "docs site" },
  { id: "notes", title: "release notes draft" },
];

/** The real Machines page on its mock host. */
function MachinesPage() {
  const [store] = useState(() => new MachinesStore(new MockMachinesProvider(snapshot), { recheck: [600_000] }));
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  return <MachinesSection store={store} strings={strings} />;
}

function Tile({ icon, label, selected }: { icon: string; label: string; selected?: boolean }) {
  return (
    <button
      type="button"
      className="mpd-tile"
      data-selected={selected ? "" : undefined}
      aria-label={label}
      title={label}
    >
      <Icon name={icon} size={16} />
    </button>
  );
}

function Tiles({ machines }: { machines: boolean }) {
  return (
    <div className="mpd-tiles" data-count={machines ? 3 : 2}>
      <Tile icon="home" label="Home" />
      <Tile icon="store" label="App Store" />
      {machines && <Tile icon="machine" label="Machines" selected />}
    </div>
  );
}

function Workspaces({ selected = true }: { selected?: boolean }) {
  return (
    <>
      <div className="mpd-header">This Mac</div>
      <ul className="mpd-rows">
        {workspaces.map((workspace) => (
          <li key={workspace.id} className="mpd-row" data-selected={selected && workspace.selected ? "" : undefined}>
            {workspace.title}
          </li>
        ))}
      </ul>
    </>
  );
}

function Sidebar({ children }: { children: ReactNode }) {
  return (
    <aside className="mpd-sidebar">
      {children}
      <div className="mpd-footer">
        <Icon name="account" size={16} />
      </div>
    </aside>
  );
}

/** A workspace's content stand-in: the page's place when no page is on top. */
function Workspace() {
  return (
    <main className="mpd-main" data-workspace="">
      <div className="mpd-strip">
        <span className="mpd-tab" data-selected="">
          <Icon name="terminal" size={12} /> zsh
        </span>
      </div>
      <div className="mpd-terminal">~/fun/cmux-next $</div>
    </main>
  );
}

export function MachinesPlacementDesigns({ placement, collapsed = false }: MachinesPlacementDesignsProps) {
  if (placement === "tile")
    return (
      <div className="mpd-window" data-placement="tile">
        <Sidebar>
          <Tiles machines />
          <Workspaces selected={false} />
        </Sidebar>
        <main className="mpd-main mpd-page">
          <MachinesPage />
        </main>
      </div>
    );
  if (placement === "section")
    return (
      <div className="mpd-window" data-placement="section">
        <Sidebar>
          <Tiles machines={false} />
          <div className="mpd-header mpd-disclosure">
            <Icon name={collapsed ? "disclosure.collapsed" : "disclosure.expanded"} size={10} />
            Machines
          </div>
          {!collapsed && (
            <div className="mpd-section">
              <MachinesPage />
            </div>
          )}
          <Workspaces />
        </Sidebar>
        <Workspace />
      </div>
    );
  return (
    <div className="mpd-window" data-placement="settings">
      <Sidebar>
        <Tiles machines={false} />
        <Workspaces selected={false} />
      </Sidebar>
      <main className="mpd-main mpd-settings">
        <nav className="mpd-settings-nav">
          {["General", "Appearance", "Terminal", "Browser", "Accounts", "Devices", "Keyboard"].map((name) => (
            <div key={name} className="mpd-settings-item" data-selected={name === "Devices" ? "" : undefined}>
              {name}
            </div>
          ))}
        </nav>
        <section className="mpd-settings-page">
          <h1 className="mpd-settings-title">Devices</h1>
          <div className="mpd-settings-group">Machines</div>
          <div className="mpd-settings-card">
            <MachinesPage />
          </div>
        </section>
      </main>
    </div>
  );
}
