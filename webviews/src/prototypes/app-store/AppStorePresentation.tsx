// l10n-allow-file: gallery prototype (sample labels), not shipped UI.
// How the not-ready App Store is presented (Beyer, Nov 20: "don't show the app store until it's
// ready, it takes too much space"; shipped as 0aa5aa4a6404 and 29a6a2f3250e: hidden unless
// Settings > Labs > Show Preview Features). The sidebar is native (SwiftUI), so this prototype
// draws a copy of it styled from a NIGHTLY screenshot, beside the New Tab page it sits next to.
// Nothing here changes the real gating; it only shows the candidates side by side:
//   hidden       today's default with Labs off (what a new user sees),
//   coming-soon  one faint footer line, no row in the list,
//   labs         a full row marked Labs that offers a one-tap enable,
//   new-tab      the redirect: no sidebar row; the store is a section of the New Tab page.
import type { ReactNode } from "react";
import "./AppStorePresentation.css";

export type AppStorePresentationVariant = "hidden" | "coming-soon" | "labs" | "new-tab";

export interface AppStorePresentationProps {
  variant: AppStorePresentationVariant;
  /** `labs`: the enable card is open (the row was clicked). */
  enableOpen?: boolean;
  /** One line under the frame that says what the variant is. */
  caption?: string;
}

function Svg({ d, size = 16 }: { d: string; size?: number }) {
  return (
    <svg viewBox="0 0 16 16" width={size} height={size} aria-hidden="true">
      <path d={d} fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

const ICON = {
  crown: "M2.5 5.5 5 8l3-4.5L11 8l2.5-2.5-1 6.5h-9ZM3.5 13.5h9",
  bag: "M3 5.5h10l-.8 8H3.8ZM5.8 5.5V4.4a2.2 2.2 0 0 1 4.4 0v1.1",
  folder: "M2 4.5c0-.6.4-1 1-1h3l1.3 1.5H13c.6 0 1 .4 1 1V12c0 .6-.4 1-1 1H3c-.6 0-1-.4-1-1Z",
  chevron: "M4.5 6.5 8 10l3.5-3.5",
  cloud: "M4.5 12.5a2.7 2.7 0 0 1-.3-5.4A3.6 3.6 0 0 1 11.3 6a3.2 3.2 0 0 1 .7 6.5Z",
  plus: "M8 3v10M3 8h10",
  mic: "M8 2.5a1.8 1.8 0 0 1 1.8 1.8v3.4a1.8 1.8 0 0 1-3.6 0V4.3A1.8 1.8 0 0 1 8 2.5ZM4.5 7.5a3.5 3.5 0 0 0 7 0M8 11v2.5",
  arrow: "M8 13V3M4 7l4-4 4 4",
  shield: "M8 2 3 4v4c0 3 2.2 5 5 6 2.8-1 5-3 5-6V4Z",
  flask: "M6.3 2.5h3.4M6.8 2.5v4L3.4 12.3c-.4.7.1 1.2.8 1.2h7.6c.7 0 1.2-.5.8-1.2L9.2 6.5v-4",
  sidebar: "M2.5 3.5h11v9h-11ZM6 3.5v9",
  back: "M10 3.5 5.5 8l4.5 4.5",
  forward: "M6 3.5l4.5 4.5L6 12.5",
  spark: "M8 2v12M2 8h12M3.8 3.8l8.4 8.4M12.2 3.8l-8.4 8.4",
};

function Row({
  icon,
  label,
  child,
  dot,
  selected,
  trailing,
  dim,
}: {
  icon?: string;
  label: string;
  child?: boolean;
  dot?: boolean;
  selected?: boolean;
  trailing?: ReactNode;
  dim?: boolean;
}) {
  return (
    <div
      className="asp-row"
      data-child={child || undefined}
      data-selected={selected || undefined}
      data-dim={dim || undefined}
    >
      {icon && (
        <span className="asp-row-icon">
          <Svg d={icon} />
        </span>
      )}
      <span className="asp-row-label">{label}</span>
      {trailing}
      {dot && <span className="asp-dot" />}
    </div>
  );
}

function Sidebar({ variant, enableOpen }: { variant: AppStorePresentationVariant; enableOpen: boolean }) {
  return (
    <aside className="asp-sidebar">
      <div className="asp-titlebar">
        <span className="asp-lights">
          <i data-c="r" />
          <i data-c="y" />
          <i data-c="g" />
        </span>
        <span className="asp-tb-icons">
          <Svg d={ICON.sidebar} size={14} />
          <Svg d={ICON.back} size={14} />
          <Svg d={ICON.forward} size={14} />
        </span>
      </div>
      <div className="asp-list">
        <Row icon={ICON.crown} label="Chief" />
        {variant === "labs" && (
          <Row
            icon={ICON.bag}
            label="App Store"
            selected={enableOpen}
            trailing={<span className="asp-labs-pill">Labs</span>}
          />
        )}
        <Row
          icon={ICON.folder}
          label="CI"
          trailing={
            <span className="asp-chevron">
              <Svg d={ICON.chevron} size={12} />
            </span>
          }
        />
        <Row child label="Fix CI queue and offline runners" />
        <Row icon={ICON.folder} label="Leads" dot />
        <Row child label="workspace-419" />
        <Row child label="claude-sr2-coord" selected={!enableOpen} dot />
        <Row child label="Thinking timer lingers" />
        <Row child label="Greeting and Quick Check-In" />
        <Row child label="composer-flicker-check" />
        <Row label="ios-app" />
        <Row label="api-server" />
        <Row icon={ICON.cloud} label="docs-site" />
      </div>
      {variant === "coming-soon" && (
        <div
          className="asp-soon"
          title="The App Store opens when it is ready. Labs > Show Preview Features shows it now."
        >
          <Svg d={ICON.bag} size={12} />
          <span>App Store</span>
          <span className="asp-soon-tag">coming soon</span>
        </div>
      )}
    </aside>
  );
}

function EnableCard() {
  return (
    <div className="asp-enable" role="dialog" aria-label="App Store is a Labs preview">
      <div className="asp-enable-head">
        <Svg d={ICON.flask} size={14} />
        <span>App Store is a Labs preview</span>
      </div>
      <p>Not finished yet. Turn On also turns on Show Preview Features (Settings &gt; Labs).</p>
      <div className="asp-enable-actions">
        <button type="button" className="asp-btn">
          Not Now
        </button>
        <button type="button" className="asp-btn" data-primary>
          Turn On
        </button>
      </div>
    </div>
  );
}

const APPS = [
  { name: "Recents", blurb: "All agent chats" },
  { name: "Agent Stats", blurb: "Tokens per harness" },
  { name: "PR Board", blurb: "Open pull requests" },
];

function NewTab({ variant }: { variant: AppStorePresentationVariant }) {
  return (
    <main className="asp-newtab">
      <div className="asp-composer">
        <Svg d={ICON.plus} />
        <span className="asp-placeholder">Ask anything or run a command</span>
        <Svg d={ICON.mic} />
        <span className="asp-send">
          <Svg d={ICON.arrow} size={14} />
        </span>
      </div>
      <div className="asp-composer-foot">
        <span>
          <Svg d={ICON.shield} size={14} /> Bypass permissions
        </span>
        <span>
          <span className="asp-claude">✳</span> Opus 5.5
        </span>
      </div>
      {variant === "new-tab" && (
        <section className="asp-apps">
          <header className="asp-apps-head">
            <span className="asp-apps-title">Apps</span>
            <span className="asp-labs-pill">Preview</span>
            <span className="asp-apps-more">Browse App Store</span>
          </header>
          <div className="asp-apps-grid">
            {APPS.map((app) => (
              <div key={app.name} className="asp-app">
                <span className="asp-app-icon">{app.name[0]}</span>
                <span className="asp-app-text">
                  <span className="asp-app-name">{app.name}</span>
                  <span className="asp-app-blurb">{app.blurb}</span>
                </span>
              </div>
            ))}
          </div>
        </section>
      )}
    </main>
  );
}

export function AppStorePresentation({ variant, enableOpen = false, caption }: AppStorePresentationProps) {
  return (
    <div className="asp-root">
      <div className="asp-window">
        <Sidebar variant={variant} enableOpen={variant === "labs" && enableOpen} />
        <NewTab variant={variant} />
        {variant === "labs" && enableOpen && <EnableCard />}
      </div>
      {caption && <div className="asp-caption">{caption}</div>}
    </div>
  );
}
