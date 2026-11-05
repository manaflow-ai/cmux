// Gallery-only, synthetic sample data. This module changes no product default or action wiring.
// l10n-allow-file: design-review fixture labels, not shipped UI.
import { useState, type CSSProperties, type ReactNode } from "react";
import "./ChromeHeaderMenus.css";

export type ChromeMenuId = "title" | "pane" | "developer" | null;
export type ChromePaneKind = "agent" | "browser" | "terminal";
export type ChromeTabData = { id: string; label: string; glyph?: ChromePaneKind };
export type ChromeMenuRow = {
  id: string;
  label: string;
  glyph: Glyph;
  shortcut?: string;
  destructive?: boolean;
  separatorBefore?: boolean;
  children?: readonly ChromeMenuRow[];
};
type Glyph =
  | "rename"
  | "fork"
  | "open"
  | "text"
  | "output"
  | "archive"
  | "delete"
  | "copy"
  | "pin"
  | "unread"
  | "plus"
  | "changes"
  | "folder"
  | "split"
  | "tabs"
  | "move"
  | "tools"
  | "developer"
  | "awake"
  | "close"
  | "chevron"
  | "more"
  | "agent"
  | "terminal"
  | "browser"
  | "back"
  | "forward"
  | "reload";
const row = (
  id: string,
  label: string,
  glyph: Glyph,
  rest: Omit<ChromeMenuRow, "id" | "label" | "glyph"> = {},
): ChromeMenuRow => ({ id, label, glyph, ...rest });

// Seven short chat rows, as in the supplied Claude reference. Primary Fork remains a leaf action.
export const chromeTitleMenu: readonly ChromeMenuRow[] = [
  row("rename", "Rename", "rename", { shortcut: "⌘R" }),
  row("fork", "Fork", "fork"),
  row("openIn", "Open in", "open", {
    children: [row("newWindow", "Open in new window", "open"), row("floatingChat", "Open as floating chat", "open")],
  }),
  row("transcriptView", "Transcript view", "text", {
    separatorBefore: true,
    children: [
      row("normal", "Normal", "text"),
      row("thinking", "Thinking", "text"),
      row("verbose", "Verbose", "text"),
      row("wrapOutput", "Wrap lines", "text", { separatorBefore: true }),
      row("display", "Text & Width…", "text"),
    ],
  }),
  row("outputStyle", "Output style", "output", {
    children: [row("outputDefault", "Default", "output"), row("outputCompact", "Compact", "output")],
  }),
  row("archive", "Archive", "archive", { separatorBefore: true }),
  row("delete", "Delete", "delete", { destructive: true }),
];

export const chromeDeveloperMenu: readonly ChromeMenuRow[] = [
  row("inspector", "ACP inspector", "developer"),
  row("revokeAccess", "Revoke Granted Access", "developer", { children: [row("grant", "Project folder", "folder")] }),
  row("instructions", "Edit AGENTS.md", "text"),
  row("setAvatar", "Set Avatar…", "agent", { separatorBefore: true }),
  row("removeAvatar", "Remove Avatar", "agent"),
];

// Every action in the old top-level menu remains reachable, including state-dependent actions.
// Eleven rows, versus the roughly 25-row source menu; no unrelated action is hidden under a chat label.
export const chromePaneMenu: readonly ChromeMenuRow[] = [
  row("newTab", "New tab", "plus", { shortcut: "⌘T" }),
  row("changes", "Changes", "changes", { shortcut: "⌃⇧⌘G" }),
  row("files", "Files", "folder", {
    children: [row("openFiles", "Show files", "folder"), row("projectFiles", "Add Files to Project…", "folder")],
  }),
  row("split", "Split", "split", {
    children: [row("splitRight", "Split right", "split"), row("splitDown", "Split down", "split", { shortcut: "⇧⌘D" })],
  }),
  row("sideTabs", "Hide tabs", "tabs"),
  row("move", "Move", "move", {
    separatorBefore: true,
    children: [
      row("moveRight", "Move to right pane", "move", { shortcut: "⌥⇧⌘→" }),
      row("newWorkspace", "Move to new workspace", "move"),
      row("newWindow", "Open in new window", "open"),
      row("moveMachine", "Move to machine…", "move"),
      row("bringBack", "Bring Back Local", "move"),
      row("floatingChat", "Open as floating chat", "open"),
    ],
  }),
  row("views", "Views & tools", "tools", {
    children: [
      row("terminal", "Terminal", "terminal"),
      row("newTerminal", "New terminal", "terminal"),
      row("browser", "Browser", "browser"),
      row("newBrowser", "New browser", "browser"),
      row("preview", "Preview", "browser"),
      row("sessionInfo", "Session Info", "tools", { separatorBefore: true }),
      row("backgroundTasks", "Background tasks", "tools"),
      row("plan", "Plan", "text"),
      row("checkpoint", "Create checkpoint…", "archive"),
      row("replay", "Replay session", "tools"),
      row("cloudPause", "Pause machine", "tools", { separatorBefore: true }),
      row("cloudResume", "Resume machine", "tools"),
      row("cloudStopPause", "Stop and pause machine", "tools"),
      row("customize", "Customize toolbar…", "tools", { separatorBefore: true }),
    ],
  }),
  row("chatActions", "Chat actions", "agent", {
    children: [
      ...chromeTitleMenu,
      row("pin", "Pin", "pin", { separatorBefore: true, shortcut: "⌥⌘P" }),
      row("markUnread", "Mark as Unread", "unread"),
      row("sideChat", "New side chat", "agent"),
      row("forkTo", "Fork to…", "fork"),
      row("continue", "Hand off to…", "fork", {
        children: [row("codex", "Codex", "agent"), row("claude", "Claude Code", "agent")],
      }),
      row("copy", "Copy", "copy", {
        separatorBefore: true,
        children: [
          row("copyLink", "Copy link", "copy"),
          row("copyResponse", "Copy last response", "copy"),
          row("copyMarkdown", "Copy as Markdown", "copy"),
          row("saveMarkdown", "Save as Markdown…", "copy"),
        ],
      }),
    ],
  }),
  row("developer", "Developer", "developer", { children: chromeDeveloperMenu }),
  row("keepAwake", "Keep awake", "awake", { separatorBefore: true }),
  row("close", "Close", "close", { shortcut: "⌘W" }),
];

/** Shared 16-unit drawing grid; sizing comes only from the inherited chrome scale. */
function GlyphIcon({ glyph }: { glyph: Glyph }) {
  const paths: Partial<Record<Glyph, ReactNode>> = {
    plus: <path d="M8 3v10M3 8h10" />,
    more: (
      <>
        <circle cx="3" cy="8" r=".7" fill="currentColor" stroke="none" />
        <circle cx="8" cy="8" r=".7" fill="currentColor" stroke="none" />
        <circle cx="13" cy="8" r=".7" fill="currentColor" stroke="none" />
      </>
    ),
    chevron: <path d="m5 6 3 3 3-3" />,
    back: <path d="m10 3-5 5 5 5" />,
    forward: <path d="m6 3 5 5-5 5" />,
    reload: (
      <>
        <path d="M13 5a5.5 5.5 0 1 0 .5 5M13 1v4H9" />
      </>
    ),
    close: <path d="m4 4 8 8M12 4l-8 8" />,
    folder: <path d="M2 4.5h4l1.5-2H14v11H2Z" />,
    terminal: (
      <>
        <rect x="1.5" y="2.5" width="13" height="11" rx="1" />
        <path d="m4 5 2.5 3L4 11m4 0h4" />
      </>
    ),
    browser: (
      <>
        <circle cx="8" cy="8" r="6" />
        <path d="M2 8h12M8 2c3 3 3 9 0 12-3-3-3-9 0-12Z" />
      </>
    ),
    copy: (
      <>
        <rect x="5" y="5" width="8" height="8" rx="1" />
        <path d="M10 5V2H2v8h3" />
      </>
    ),
    rename: (
      <>
        <path d="m3 10 7-7 3 3-7 7H3Z" />
        <path d="m9 4 3 3" />
      </>
    ),
    fork: (
      <>
        <path d="M4 3v5h8V3M8 8v5" />
        <circle cx="4" cy="2" r="1" />
        <circle cx="12" cy="2" r="1" />
        <circle cx="8" cy="14" r="1" />
      </>
    ),
    open: (
      <>
        <path d="M9 2h5v5m0-5L7 9M6 3H2v11h11v-4" />
      </>
    ),
    text: (
      <>
        <path d="M3 3h10M8 3v10M5 13h6" />
      </>
    ),
    output: (
      <>
        <path d="M2 4h12M2 8h9M2 12h6" />
      </>
    ),
    archive: (
      <>
        <path d="M2 5h12v9H2ZM1 2h14v3H1ZM6 8h4" />
      </>
    ),
    delete: (
      <>
        <path d="M2 4h12M6 2h4M4 4l1 10h6l1-10M6.5 7v4M9.5 7v4" />
      </>
    ),
    changes: (
      <>
        <rect x="3" y="2" width="10" height="12" rx="1" />
        <path d="M6 6h4M8 4v4M6 11h4" />
      </>
    ),
    split: (
      <>
        <rect x="1.5" y="2.5" width="13" height="11" rx="1" />
        <path d="M8 3v10" />
      </>
    ),
    tabs: (
      <>
        <rect x="1.5" y="2.5" width="13" height="11" rx="1" />
        <path d="M5 3v10" />
      </>
    ),
    move: (
      <>
        <path d="M2 8h12m-4-4 4 4-4 4" />
      </>
    ),
    tools: (
      <>
        <path d="M5 3h9M5 8h9M5 13h9" />
        <circle cx="2" cy="3" r=".7" />
        <circle cx="2" cy="8" r=".7" />
        <circle cx="2" cy="13" r=".7" />
      </>
    ),
    developer: (
      <>
        <path d="m5 4-4 4 4 4m6-8 4 4-4 4M9 2 7 14" />
      </>
    ),
    awake: (
      <>
        <path d="M2 6h10v6H2Zm10 0h2v3h-2M4 2v2m3-2v2m3-2v2M1 14h12" />
      </>
    ),
    pin: <path d="m6 2 6 6-3 1-1 4-2-2-4 3 3-4-2-2 4-1Z" />,
    unread: <circle cx="8" cy="8" r="3" fill="currentColor" stroke="none" />,
    agent: (
      <>
        <path d="M2 3h12v9H6l-4 3Z" />
        <path d="M5 6h6M5 9h4" />
      </>
    ),
  };
  return (
    <svg
      className="chrome-header-menu-glyph"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.25"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      {paths[glyph]}
    </svg>
  );
}

export type ChromeHeaderMenusProps = {
  paneKind?: ChromePaneKind;
  openMenu?: ChromeMenuId;
  visibility?: "zen" | "always";
  tabs?: 1 | 3;
  tabMode?: "auto" | "always";
  density?: "compact" | "comfortable";
  revealed?: boolean;
  title?: string;
  /** Synthetic tab labels/icons. All kinds use the same tab markup and styling. */
  tabData?: readonly ChromeTabData[];
  activeTab?: number;
  address?: string;
  /** Owner may map the fixture to the shared density token source. No px override is needed. */
  style?: CSSProperties;
};

export function ChromeHeaderMenus({
  paneKind = "agent",
  openMenu = null,
  visibility = "zen",
  tabs = 1,
  tabMode = "auto",
  density = "compact",
  revealed = false,
  title,
  tabData,
  activeTab = 0,
  address = "example.com/workspace",
  style,
}: ChromeHeaderMenusProps) {
  const [open, setOpen] = useState<ChromeMenuId>(openMenu);
  const [submenuPath, setSubmenuPath] = useState<string[]>(openMenu === "developer" ? ["developer"] : []);
  const defaults: Record<ChromePaneKind, readonly string[]> = {
    agent: ["Review workspace changes", "Build preview", "Review results"],
    browser: ["Workspace preview", "Documentation", "Build report"],
    terminal: ["Shell", "Development server", "Build output"],
  };
  const tabItems = tabData?.length
    ? tabData
    : Array.from({ length: tabs }, (_, index) => ({
        id: `${paneKind}-${index}`,
        label: index === 0 && title ? title : defaults[paneKind][index]!,
        glyph: paneKind,
      }));
  const strip = tabItems.length > 1 || tabMode === "always";
  const visibleMenu = open === "title" && paneKind !== "agent" ? null : open === "developer" ? "pane" : open;
  const toggle = (next: "title" | "pane") => {
    setOpen(open === next ? null : next);
    setSubmenuPath([]);
  };
  const sharedPaneActions = new Set(["newTab", "split", "sideTabs", "move", "close"]);
  const rows =
    visibleMenu === "title"
      ? chromeTitleMenu
      : paneKind === "agent"
        ? chromePaneMenu
        : chromePaneMenu.filter((item) => sharedPaneActions.has(item.id));
  const panel = (items: readonly ChromeMenuRow[], depth = 0): ReactNode => {
    const selected = items.find((item) => item.id === submenuPath[depth]);
    const reveal = (item: ChromeMenuRow) =>
      setSubmenuPath([...submenuPath.slice(0, depth), ...(item.children ? [item.id] : [])]);
    return (
      <div
        className={`chrome-header-menu${depth ? " chrome-header-menu-submenu" : ""}`}
        role="menu"
        data-chrome-menu={depth ? submenuPath[depth - 1] : visibleMenu}
      >
        <div className="chrome-header-menu-rows">
          {items.map((item) => (
            <button
              key={item.id}
              type="button"
              role="menuitem"
              className="chrome-header-menu-item"
              data-action-id={item.id}
              data-destructive={item.destructive || undefined}
              data-separator-before={item.separatorBefore || undefined}
              aria-haspopup={item.children ? "menu" : undefined}
              aria-expanded={item.children ? selected?.id === item.id : undefined}
              onPointerEnter={() => reveal(item)}
              onFocus={() => reveal(item)}
              onClick={() => (item.children ? reveal(item) : setOpen(null))}
            >
              <GlyphIcon glyph={item.glyph} />
              <span>{item.label}</span>
              {item.shortcut && <kbd>{item.shortcut}</kbd>}
              {item.children && (
                <span className="chrome-header-menu-arrow" aria-hidden>
                  ›
                </span>
              )}
            </button>
          ))}
        </div>
        {selected?.children && panel(selected.children, depth + 1)}
      </div>
    );
  };
  return (
    <div
      className="chrome-header-menu-fixture"
      data-pane-kind={paneKind}
      data-tabs={tabItems.length}
      data-visibility={visibility}
      data-density={density}
      data-revealed={revealed || undefined}
      data-menu-open={visibleMenu || undefined}
      style={style}
    >
      <header className="chrome-header-menu-row" data-tab-treatment={strip ? "strip" : "flat-title"}>
        <div className="chrome-header-menu-titles">
          {tabItems.map((item, index) => (
            <div key={item.id} className="chrome-header-menu-title" data-selected={index === activeTab || undefined}>
              {strip && <GlyphIcon glyph={item.glyph ?? paneKind} />}
              <span>{item.label}</span>
              {paneKind === "agent" && index === activeTab && (
                <button
                  type="button"
                  className="chrome-header-menu-trigger chrome-header-menu-title-chevron"
                  aria-label="Chat actions"
                  aria-haspopup="menu"
                  aria-expanded={visibleMenu === "title"}
                  data-chrome-trigger="title"
                  onClick={() => toggle("title")}
                >
                  <GlyphIcon glyph="chevron" />
                </button>
              )}
            </div>
          ))}
        </div>
        <button
          type="button"
          className="chrome-header-menu-trigger chrome-header-menu-add"
          aria-label="New tab"
          title="New tab (⌘T)"
          data-chrome-trigger="add"
        >
          <GlyphIcon glyph="plus" />
        </button>
        <div className="chrome-header-menu-tools">
          <button
            type="button"
            className="chrome-header-menu-trigger"
            aria-label={
              paneKind === "agent" ? "Session Info" : paneKind === "browser" ? "Bookmark page" : "Terminal controls"
            }
            title={
              paneKind === "agent" ? "Session Info" : paneKind === "browser" ? "Bookmark page" : "Terminal controls"
            }
            data-chrome-trigger="info"
          >
            <GlyphIcon glyph={paneKind === "browser" ? "pin" : "tools"} />
          </button>
          <button
            type="button"
            className="chrome-header-menu-trigger"
            aria-label="Pane actions"
            title="Pane actions"
            aria-haspopup="menu"
            aria-expanded={visibleMenu === "pane"}
            data-chrome-trigger="pane"
            onClick={() => toggle("pane")}
          >
            <GlyphIcon glyph="more" />
          </button>
        </div>
      </header>
      {paneKind === "browser" && (
        <div className="chrome-header-browser-toolbar" data-chrome-address-row>
          <button type="button" className="chrome-header-menu-trigger" aria-label="Back">
            <GlyphIcon glyph="back" />
          </button>
          <button type="button" className="chrome-header-menu-trigger" aria-label="Forward">
            <GlyphIcon glyph="forward" />
          </button>
          <button type="button" className="chrome-header-menu-trigger" aria-label="Reload">
            <GlyphIcon glyph="reload" />
          </button>
          <input className="chrome-header-browser-address" aria-label="Address" value={address} readOnly />
        </div>
      )}
      {visibleMenu && (
        <div className="chrome-header-menu-position" data-menu-side={visibleMenu}>
          {panel(rows)}
        </div>
      )}
    </div>
  );
}

// Owner registers these alongside A-D, in both density/theme modes and beside the browser pane.
export const chromeHeaderMenuScenes = [
  { id: "one-zen", props: { tabs: 1, visibility: "zen" } },
  { id: "one-zen-hover", props: { tabs: 1, visibility: "zen", revealed: true } },
  { id: "one-visible", props: { tabs: 1, visibility: "always" } },
  { id: "three-zen", props: { tabs: 3, visibility: "zen" } },
  { id: "one-always-strip", props: { tabs: 1, visibility: "zen", tabMode: "always" } },
  { id: "one-title-menu", props: { tabs: 1, visibility: "zen", openMenu: "title" } },
  { id: "three-pane-menu", props: { tabs: 3, visibility: "zen", openMenu: "pane" } },
  { id: "three-developer-menu", props: { tabs: 3, visibility: "zen", openMenu: "developer" } },
] as const;
