// l10n-allow-file: gallery-only design specimens, not shipped UI.
//
// This gallery is deliberately separate from ChatHeaderTools. The current header is the settled
// plain-title design; this specimen lets the team compare Leo's proposed title chevron and scoped
// menus beside a browser pane before changing that default.
import { componentEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { Icon } from "../icons/Icon";

type Density = "compact" | "comfortable";
type Theme = "dark" | "light";
type Visibility = "hidden" | "visible";
type AgentTabs = "flat" | "strip";

const TITLE_MENU = [
  ["action.edit", "Rename"],
  ["agent.fork", "Fork"],
  ["app.open.external", "Open in", true],
  ["view.list", "Transcript view", true],
  ["code", "Output style", true],
  ["inbox", "Archive"],
  ["action.delete", "Delete"],
] as const;

const PANE_MENU = [
  ["diff.file", "Changes"],
  ["folder", "Files"],
  ["pane.split.right", "Split", true],
  ["tunable.sidebar", "Hide tabs"],
  ["pane.split.right", "Move to pane", true],
  ["workspace.new", "Move to workspace", true],
  ["app.open.external", "Move to window", true],
  ["machine.remote", "Move to machine", true],
  ["status.info", "Background tasks"],
  ["action.review", "Plan"],
  ["status.info", "Keep awake"],
  ["code", "Developer", true],
] as const;

const DEVELOPER_MENU = [
  ["code", "ACP inspector"],
  ["status.warning", "Revoke Granted Access"],
  ["action.edit", "Edit AGENTS.md"],
  ["agent.session", "Set Avatar"],
] as const;

function MenuSurface({ kind }: { kind: "title" | "pane" | "developer" }) {
  const rows = kind === "title" ? TITLE_MENU : kind === "pane" ? PANE_MENU : DEVELOPER_MENU;
  return (
    <div className={`agent-pane-design-menu agent-pane-design-menu--${kind}`} role="menu" aria-label={`${kind} menu`}>
      {rows.map(([icon, label, submenu], index) => (
        <div className="agent-pane-design-menu-row" role="menuitem" key={label}>
          <Icon name={icon} size={14} />
          <span>{label}</span>
          {submenu && <span className="agent-pane-design-menu-chevron" aria-hidden="true">›</span>}
          {kind === "pane" && label === "Developer" && <MenuSurface kind="developer" />}
          {index === 1 && kind === "title" && <span className="agent-pane-design-shortcut">⌘R</span>}
        </div>
      ))}
    </div>
  );
}

function BrowserPane() {
  return (
    <section className="agent-pane-design-browser" aria-label="Browser pane">
      <div className="agent-pane-design-browser-tabs">
        <div className="agent-pane-design-browser-tab agent-pane-design-browser-tab--active">
          <Icon name="browser" size={14} />
          <span>todo-app</span>
          <span className="agent-pane-design-tab-close">×</span>
        </div>
        <button className="agent-pane-design-browser-add" aria-label="New browser tab">+</button>
      </div>
      <div className="agent-pane-design-browser-address">localhost:3000</div>
      <div className="agent-pane-design-browser-page">
        <div className="agent-pane-design-browser-page-line agent-pane-design-browser-page-line--wide" />
        <div className="agent-pane-design-browser-page-line" />
        <div className="agent-pane-design-browser-card" />
      </div>
    </section>
  );
}

function AgentHeader({
  tabs,
  visibility,
  agentTabs,
  menus,
}: {
  tabs: 1 | 3;
  visibility: Visibility;
  agentTabs: AgentTabs;
  menus: boolean;
}) {
  const tabNames = ["Fix retry handling", "Review sidebar", "Release notes"];
  return (
    <header className="agent-pane-design-header" data-agent-tabs={agentTabs} data-menu-open={menus ? "" : undefined}>
      <div className="agent-pane-design-title-row">
        {agentTabs === "flat" ? (
          <button className="agent-pane-design-title" aria-label="Chat actions">
            <span>{tabNames[0]}</span>
            <span className="agent-pane-design-title-chevron" aria-hidden="true" />
          </button>
        ) : (
          <div className="agent-pane-design-tab-strip" role="tablist" aria-label="Agent tabs">
            {tabNames.slice(0, tabs).map((name, index) => (
              <button
                className={`agent-pane-design-agent-tab${index === 0 ? " agent-pane-design-agent-tab--active" : ""}`}
                role="tab"
                aria-selected={index === 0}
                key={name}
              >
                <span>{name}</span>
                {index === 0 && <span className="agent-pane-design-tab-close">×</span>}
              </button>
            ))}
            <button className="agent-pane-design-add" aria-label="New agent tab">
              <Icon name="action.add" size={14} />
            </button>
          </div>
        )}
        {agentTabs === "flat" && (
          <button className="agent-pane-design-add" aria-label="New agent tab">
            <Icon name="action.add" size={14} />
          </button>
        )}
        <div className={`agent-pane-design-toolbar agent-pane-design-toolbar--${visibility}`}>
          <button className="agent-pane-design-toolbar-button" aria-label="Session Info">
            <Icon name="view.list" size={16} />
          </button>
          <button className="agent-pane-design-toolbar-button" aria-label="Split pane">
            <Icon name="pane.split.right" size={16} />
          </button>
          <button className="agent-pane-design-toolbar-button" aria-label="Pane actions">
            <Icon name="overflow.more" size={16} />
          </button>
        </div>
      </div>
      {menus && (
        <div className="agent-pane-design-menu-layer">
          <MenuSurface kind="title" />
          <MenuSurface kind="pane" />
        </div>
      )}
    </header>
  );
}

function AgentPaneHeaderDesign({
  density,
  theme,
  tabs,
  visibility,
  agentTabs,
  menus,
}: {
  density: Density;
  theme: Theme;
  tabs: 1 | 3;
  visibility: Visibility;
  agentTabs: AgentTabs;
  menus: boolean;
}) {
  return (
    <div
      className={`agent-pane-design agent-pane-design--${density} agent-pane-design--${theme} agent-pane-design--${visibility}`}
      data-density={density}
      data-theme={theme}
      data-tabs={tabs}
    >
      <aside className="agent-pane-design-sidebar" aria-label="Workspaces">
        <div className="agent-pane-design-workspace-mark">cm</div>
        <div className="agent-pane-design-workspace agent-pane-design-workspace--active">A</div>
        <div className="agent-pane-design-workspace">B</div>
        <div className="agent-pane-design-workspace">+</div>
      </aside>
      <main className="agent-pane-design-window">
        <section className="agent-pane-design-agent" aria-label="Agent pane">
          <AgentHeader tabs={tabs} visibility={visibility} agentTabs={agentTabs} menus={menus} />
          <div className="agent-pane-design-transcript">
            <div className="agent-pane-design-transcript-title">Fix retry handling</div>
            <div className="agent-pane-design-transcript-line agent-pane-design-transcript-line--wide" />
            <div className="agent-pane-design-transcript-line" />
            <div className="agent-pane-design-composer">Message the agent…</div>
          </div>
        </section>
        <BrowserPane />
      </main>
    </div>
  );
}

const verify: Play = async (ctx: PlayContext) => {
  const root = ctx.document.querySelector<HTMLElement>(".agent-pane-design")!;
  const tabs = Number(root.dataset.tabs);
  const agentTabs = root.querySelectorAll('[role="tab"]');
  if (tabs === 1 && agentTabs.length !== 0) throw new Error("flat one-tab treatment must not render a tab strip");
  if (tabs === 3 && agentTabs.length !== 3) throw new Error("three-tab treatment must render all agent tabs");
  const add = root.querySelector<HTMLElement>(".agent-pane-design-add")!;
  if (!add || add.getBoundingClientRect().height === 0) throw new Error("the reserved add-tab control must occupy space");
  const browser = root.querySelector(".agent-pane-design-browser-tabs");
  if (!browser) throw new Error("the agent header must be shown beside browser tabs");
};

export default componentEntry<{
  density: Density;
  theme: Theme;
  tabs: 1 | 3;
  visibility: Visibility;
  agentTabs: AgentTabs;
  menus?: boolean;
}>({
  id: "agent-pane.header-design",
  title: "Agent pane header and scoped menus",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { narrow: 720, normal: 920, wide: 1180 },
  anchors: [{ selector: ".agent-pane-design" }],
  covers: [
    "agent-session/acpmux/header/ChatHeaderTools.tsx#ChatHeaderTools",
    "agent-session/acpmux/header/tabRow.ts#tabRow",
  ],
  styles: () => Promise.all([import("../styles.css"), import("./header.css"), import("./AgentPaneHeaderDesign.gallery.css")]),
  checks: {
    anchorMovePx: { value: 0, reason: "Revealing quiet controls overlays their reserved slots without moving the title or browser tabs." },
    layoutShiftMax: { value: 0.01, reason: "Switching from one to three agent tabs keeps the add control on the same title-row pitch." },
  },
  load: async () => AgentPaneHeaderDesign,
  variants: {
    "one-flat-hidden-compact-dark": {
      props: { density: "compact", theme: "dark", tabs: 1, visibility: "hidden", agentTabs: "flat" },
      play: verify,
      note: "Recommended default: one flat title, quiet chevron and hover-revealed +/toolbar controls; browser tabs remain visible beside it.",
    },
    "one-flat-hidden-comfortable-light": {
      props: { density: "comfortable", theme: "light", tabs: 1, visibility: "hidden", agentTabs: "flat" },
      play: verify,
      note: "Comfortable/light comparison with the same reserved title-row geometry.",
    },
    "three-strip-hidden-compact-dark": {
      props: { density: "compact", theme: "dark", tabs: 3, visibility: "hidden", agentTabs: "strip" },
      play: verify,
      note: "Three tabs use the browser strip treatment; the + remains at the one-tab position.",
    },
    "three-strip-hidden-comfortable-light": {
      props: { density: "comfortable", theme: "light", tabs: 3, visibility: "hidden", agentTabs: "strip" },
      play: verify,
      note: "Comfortable/light three-tab comparison beside the Helium-like browser pane.",
    },
    "one-flat-visible-compact-light": {
      props: { density: "compact", theme: "light", tabs: 1, visibility: "visible", agentTabs: "flat" },
      play: verify,
      note: "Always-visible controls alternative; geometry is identical to the quiet default.",
    },
    "three-strip-visible-comfortable-dark": {
      props: { density: "comfortable", theme: "dark", tabs: 3, visibility: "visible", agentTabs: "strip" },
      play: verify,
      note: "Always-visible browser-style agent strip alternative.",
    },
    "three-strip-menus-light": {
      props: { density: "comfortable", theme: "light", tabs: 3, visibility: "hidden", agentTabs: "strip", menus: true },
      play: verify,
      note: "Both menus open: title chevron owns chat actions; ellipsis owns pane/view actions and Developer.",
    },
    "one-flat-menus-dark": {
      props: { density: "compact", theme: "dark", tabs: 1, visibility: "hidden", agentTabs: "flat", menus: true },
      play: verify,
      note: "One-tab menu state keeps the title and ellipsis anchors stable while both scoped menus are visible.",
    },
    "three-agent-strip-always-dark": {
      props: { density: "compact", theme: "dark", tabs: 3, visibility: "visible", agentTabs: "strip", menus: false },
      play: verify,
      note: "Alternative: agent tabs always use a strip even when the pane has one tab; shown here with three tabs.",
    },
  },
});
