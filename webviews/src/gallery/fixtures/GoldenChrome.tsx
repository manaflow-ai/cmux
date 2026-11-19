// l10n-allow-file: gallery fixtures, public-safe chrome and sample workspace labels.
// The golden chrome preview: the whole window chrome drawn at once (the sidebar at its width with its
// rows and vertical tabs, each pane's tab strip, the top right buttons, Session Info, Home cards), every
// shape read from one look (goldenChromeLooks.ts), so a shape change moves all of them together.
import type { CSSProperties, ReactNode } from "react";
import { resolveGoldenLook, type GoldenLookId } from "./goldenChromeLooks";

export type GoldenChromeProps = { golden: GoldenLookId };

type IconName =
  | "home"
  | "pin"
  | "chat"
  | "globe"
  | "term"
  | "split"
  | "diff"
  | "search"
  | "more"
  | "plus"
  | "sidebar"
  | "info"
  | "folder";

const ICONS: Record<IconName, string> = {
  home: "M3 8.5 8 4l5 4.5V13H9.5v-3h-3v3H3z",
  pin: "M6 2.5h4l-.7 3.5L11.5 8H8.6L8 13.5 7.4 8H4.5l2.2-2z",
  chat: "M3 4h10v6.5H7.5L5 13v-2.5H3z",
  globe: "M8 2.5a5.5 5.5 0 1 0 0 11 5.5 5.5 0 0 0 0-11zM2.5 8h11M8 2.5c1.8 2 1.8 9 0 11M8 2.5c-1.8 2-1.8 9 0 11",
  term: "M2.5 3.5h11v9h-11zM5 6.5l2 1.5-2 1.5M8.5 10H11",
  split: "M2.5 3.5h11v9h-11zM8 3.5v9",
  diff: "M5 2.5v7M2 6h6M10.5 6.5v7M7.5 10h6",
  search: "M7 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM10 10l3.5 3.5",
  more: "M4 8h.01M8 8h.01M12 8h.01",
  plus: "M8 3.5v9M3.5 8h9",
  sidebar: "M2.5 3.5h11v9h-11zM6 3.5v9",
  info: "M8 2.5a5.5 5.5 0 1 0 0 11 5.5 5.5 0 0 0 0-11zM8 7v4M8 5h.01",
  folder: "M2.5 4.5h4l1.2 1.5h5.8v6.5h-11z",
};

function Icon({ name }: { name: IconName }) {
  return (
    <svg className="gc-icon" viewBox="0 0 16 16" aria-hidden="true" data-icon={name}>
      <path d={ICONS[name]} />
    </svg>
  );
}

function Tab({ icon, title, selected }: { icon: IconName; title: string; selected?: boolean }) {
  return (
    <div className="gc-tab" aria-selected={selected}>
      <Icon name={icon} />
      <span className="gc-tab-title">{title}</span>
      {selected ? <span className="gc-tab-close">×</span> : null}
    </div>
  );
}

function Strip({ children, buttons }: { children: ReactNode; buttons?: ReactNode }) {
  return (
    <div className="gc-strip">
      <div className="gc-tabs">
        {children}
        <button className="gc-plus" aria-label="New tab">
          <Icon name="plus" />
        </button>
      </div>
      {buttons}
    </div>
  );
}

function ToolbarButtons() {
  const names: IconName[] = ["split", "diff", "search", "more"];
  return (
    <div className="gc-toolbar" role="toolbar" aria-label="Top right buttons">
      {names.map((name, index) => (
        <button key={name} className="gc-toolbar-button" aria-label={name} data-first={index === 0 || undefined}>
          <Icon name={name} />
        </button>
      ))}
    </div>
  );
}

function SidebarRow({
  icon,
  title,
  trail,
  selected,
  nested,
}: {
  icon: IconName;
  title: string;
  trail?: string;
  selected?: boolean;
  nested?: boolean;
}) {
  return (
    <div className={nested ? "gc-row gc-vtab" : "gc-row"} aria-selected={selected}>
      <Icon name={icon} />
      <span className="gc-row-title">{title}</span>
      {trail ? <span className="gc-row-trail">{trail}</span> : null}
    </div>
  );
}

function Sidebar() {
  return (
    <aside className="gc-sidebar">
      <div className="gc-titlebar">
        <span className="gc-lights">
          <i />
          <i />
          <i />
        </span>
        <button className="gc-sidebar-button" aria-label="Toggle sidebar">
          <Icon name="sidebar" />
        </button>
      </div>
      <SidebarRow icon="home" title="Home" />
      <SidebarRow icon="pin" title="Release notes" />
      <div className="gc-section">Workspaces</div>
      <SidebarRow icon="folder" title="retry-backoff" trail="2m" selected />
      <div className="gc-vtabs">
        <SidebarRow nested icon="chat" title="Plan the retry change" selected />
        <SidebarRow nested icon="globe" title="Retries with backoff" />
        <SidebarRow nested icon="term" title="cargo test" trail="•" />
      </div>
      <SidebarRow icon="folder" title="docs-site" trail="1h" />
      <SidebarRow icon="folder" title="metrics-dashboard" />
      <div className="gc-section">Experiments</div>
      <SidebarRow icon="folder" title="layout-sandbox" />
      <div className="gc-sidebar-foot">
        <button className="gc-sidebar-new">
          <Icon name="plus" />
          <span>New workspace</span>
        </button>
      </div>
    </aside>
  );
}

function SessionInfo({ placement }: { placement: string }) {
  const facts: Array<[string, string]> = [
    ["Model", "Claude"],
    ["Time", "12m 40s"],
    ["Turns", "8"],
    ["Context", "38%"],
  ];
  if (placement === "inline")
    return (
      <div className="gc-session gc-session-inline" data-placement="inline">
        <Icon name="info" />
        {facts.map(([key, value]) => (
          <span key={key} className="gc-session-chip">
            <b>{key}</b> {value}
          </span>
        ))}
      </div>
    );
  const context: Array<[string, string, number]> = [
    ["Messages", "61.2k", 6],
    ["Tools", "14.8k", 2],
    ["Memory", "8.3k", 1],
  ];
  return (
    <aside className="gc-session" data-placement={placement}>
      <section className="gc-session-section">
        <div className="gc-session-head">
          <span>Context</span>
          <span className="gc-session-value">38% used</span>
        </div>
        <div className="gc-session-bar" aria-label="Context breakdown">
          {context.map(([key, , flex]) => (
            <i key={key} style={{ flex }} />
          ))}
          <i className="gc-session-free" style={{ flex: 16 }} />
        </div>
        {context.map(([key, value]) => (
          <div key={key} className="gc-session-row">
            <span>
              <i className="gc-session-swatch" />
              {key}
            </span>
            <b>{value}</b>
          </div>
        ))}
      </section>
      <section className="gc-session-section">
        {facts.slice(0, 3).map(([key, value]) => (
          <div key={key} className="gc-session-row">
            <span>{key}</span>
            <b>{value}</b>
          </div>
        ))}
      </section>
    </aside>
  );
}

function ChatPane({ placement }: { placement: string }) {
  return (
    <section className="gc-pane gc-chat" data-session={placement}>
      <Strip>
        <Tab icon="chat" title="Plan the retry change" selected />
        <Tab icon="globe" title="Retries with backoff" />
        <Tab icon="term" title="cargo test" />
      </Strip>
      <div className="gc-chat-body">
        <div className="gc-transcript">
          {placement === "inline" ? <SessionInfo placement="inline" /> : null}
          <div className="gc-msg gc-msg-you">Add retries with backoff to the sync client.</div>
          <div className="gc-msg">
            I will wrap the request in a bounded retry with jittered backoff, then add a test for the third attempt.
          </div>
          <div className="gc-line" />
          <div className="gc-line short" />
          <div className="gc-composer">Ask for a follow-up</div>
        </div>
        {placement === "inline" ? null : <SessionInfo placement={placement} />}
      </div>
    </section>
  );
}

function HomePane() {
  const cards: Array<[IconName, string, string]> = [
    ["chat", "Resume chat", "Plan the retry change"],
    ["folder", "Open workspace", "docs-site"],
    ["globe", "Recent page", "Retries with backoff"],
  ];
  return (
    <section className="gc-pane gc-home">
      <Strip buttons={<ToolbarButtons />}>
        <Tab icon="home" title="Home" selected />
      </Strip>
      <div className="gc-home-body">
        <h3>Good morning</h3>
        <div className="gc-cards">
          {cards.map(([icon, title, detail]) => (
            <div key={title} className="gc-card">
              <Icon name={icon} />
              <b>{title}</b>
              <span>{detail}</span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

export function GoldenChrome({ golden }: GoldenChromeProps) {
  const resolved = resolveGoldenLook(golden);
  const { tokens } = resolved;
  const style = {
    "--gc-sidebar-width": `${tokens.sidebarWidth}px`,
    "--gc-row-height": `${tokens.sidebarRowHeight}px`,
    "--gc-row-radius": `${tokens.sidebarCornerRadius}px`,
    "--gc-vtab-radius": `${tokens.verticalTabCornerRadius}px`,
    "--gc-tab-height": `${tokens.browserRowHeight}px`,
    "--gc-tab-gap": `${tokens.tabGap}px`,
    "--gc-tab-radius": `${tokens.tabCornerRadius}px`,
    "--gc-control-height": `${tokens.controlHeight}px`,
    "--gc-item-radius": `${tokens.itemCornerRadius}px`,
    "--gc-panel-radius": `${tokens.panelCornerRadius}px`,
    "--gc-pane-radius": `${resolved.paneRadius}px`,
  } as CSSProperties;
  const keys = [
    ...Object.entries(resolved.look.theme).map(([key, value]) => `${key}: ${JSON.stringify(value)}`),
    ...Object.entries(resolved.look.proposed ?? {}).map(([key, value]) => `${key}: "${value}" (proposed)`),
  ];
  return (
    <div
      className="golden-chrome"
      data-look={golden}
      data-area={resolved.look.area}
      data-buttons={resolved.buttons}
      data-cards={resolved.cards}
      data-chrome={resolved.chrome}
      style={style}
    >
      <div className="gc-window">
        <Sidebar />
        <main className="gc-main">
          <ChatPane placement={resolved.sessionInfo} />
          <HomePane />
        </main>
      </div>
      <footer className="gc-keys">
        <b>{resolved.look.label}</b>
        <span>{resolved.look.note}</span>
        <code>{keys.length ? keys.join("  ·  ") : "no keys: today's defaults"}</code>
      </footer>
    </div>
  );
}
