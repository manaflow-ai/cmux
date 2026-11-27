// l10n-allow-file: gallery fixtures, public-safe chrome and sample workspace labels.
import type { CSSProperties, ReactNode } from "react";
import { ChromeHeaderMenus } from "./ChromeHeaderMenus";
import { SidebarShapes } from "./SidebarShapes";

export type ChromeShapeVariant = "recommendation" | "group-line" | "aside-labels" | "rex-icons";
export type ChromeDensity = "compact" | "comfortable";
export type ChromeTheme = "light" | "dark";
const sidebarVariants = { recommendation: "A", "group-line": "B", "aside-labels": "C", "rex-icons": "D" } as const;

export type WindowChromeShapeProps = {
  variant: ChromeShapeVariant;
  density: ChromeDensity;
  theme: ChromeTheme;
  menuScene?:
    | "one-zen"
    | "one-zen-hover"
    | "one-visible"
    | "three-zen"
    | "one-always-strip"
    | "one-title-menu"
    | "three-pane-menu"
    | "three-developer-menu";
};

function AgentPane({ children }: { children: ReactNode }) {
  return (
    <section className="chrome-pane chrome-agent-pane">
      <div className="chrome-pane-content">
        {children}
        <div className="chrome-transcript-rail" aria-label="Transcript rail">
          <i />
          <i />
          <i />
          <i />
        </div>
      </div>
    </section>
  );
}

function BrowserPane() {
  return (
    <section className="chrome-pane chrome-browser-pane">
      <div className="chrome-browser-content">
        <div className="chrome-browser-kicker">Documentation</div>
        <h3>Retries with backoff</h3>
        <p>Keep the page and the agent in the same workspace while preserving one shared chrome seam.</p>
        <div className="chrome-browser-line" />
        <div className="chrome-browser-line short" />
      </div>
    </section>
  );
}

export function WindowChromeShape({ variant, density, theme, menuScene }: WindowChromeShapeProps) {
  const style = {
    "--chrome-density": density === "compact" ? 1 : 1.125,
  } as CSSProperties;
  return (
    <div
      className="window-chrome-gallery"
      data-variant={variant}
      data-density={density}
      data-theme={theme}
      style={style}
    >
      <header className="chrome-window-header">
        <div className="chrome-window-sidebar-title">
          <div className="chrome-traffic-lights">
            <i />
            <i />
            <i />
          </div>
          <button className="chrome-sidebar-toggle" aria-label="Toggle sidebar">
            ☰
          </button>
        </div>
        <div className="chrome-window-agent-title">
          <ChromeHeaderMenus
            paneKind="agent"
            openMenu={
              menuScene?.includes("title")
                ? "title"
                : menuScene?.includes("developer")
                  ? "developer"
                  : menuScene?.includes("pane")
                    ? "pane"
                    : null
            }
            visibility={menuScene?.includes("visible") ? "always" : "zen"}
            tabs={menuScene?.includes("three") ? 3 : 1}
            tabMode={menuScene?.includes("always-strip") ? "always" : "auto"}
            density={density}
            revealed={menuScene?.includes("hover")}
          />
        </div>
        <div className="chrome-window-browser-title">
          <ChromeHeaderMenus paneKind="browser" tabs={3} density={density} address="example.com / docs" />
        </div>
      </header>
      <div className="chrome-window-body">
        <aside className="chrome-sidebar">
          <SidebarShapes variant={sidebarVariants[variant]} density={density} appearance={theme} />
        </aside>
        <main className="chrome-main">
          <div className="chrome-content-surface">
            <div className="chrome-pane-grid">
              <AgentPane>
                <div className="chrome-chat-placeholder">Plan a small, reversible change.</div>
              </AgentPane>
              <BrowserPane />
            </div>
          </div>
        </main>
      </div>
    </div>
  );
}
