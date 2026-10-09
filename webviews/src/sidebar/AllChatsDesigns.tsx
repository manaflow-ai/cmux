// l10n-allow-file: gallery design fixtures for the native All chats section, not shipped UI.
// Three minimal designs of the sidebar's bottom All chats section (Lawrence 2026-10-09: fewer
// chrome, no bordered pop-ups, the title plus subtle icons on hover only) for his vote. The
// shipped section is native (CmuxNextSidebar SidebarChatsView); the chosen design is ported there.
import "./AllChatsDesigns.css";

export type AllChatsDesign = "quiet" | "age" | "project";

export interface AllChatsDesignsProps {
  design: AllChatsDesign;
  /// The pointer is over the sidebar: the subtle icons show.
  hover?: boolean;
  /// Minimized (the default): the header row alone.
  collapsed?: boolean;
}

const chats = [
  { harness: "claude", title: "Fix the flaky terminal restore test", project: "cmux", age: "2m" },
  { harness: "codex", title: "Sidebar All chats: minimized default", project: "cmux", age: "14m" },
  { harness: "opencode", title: "Bump ghostty and rerun the bench", project: "ghostty", age: "1h" },
  { harness: "claude", title: "Draft the release notes", project: "hq", age: "3h" },
  { harness: "pi", title: "Why does the dock flicker on resize?", project: "cmux", age: "1d" },
  { harness: "codex", title: "Port the palette ranker to Rust", project: "cmux-tui", age: "2d" },
];

const glyph: Record<string, string> = { claude: "✳", codex: "◎", opencode: "◇", pi: "π" };

function Icon({ d, label }: { d: string; label: string }) {
  return (
    <span className="acd-icon">
      <svg viewBox="0 0 16 16" width="12" height="12" aria-label={label}>
        <path d={d} fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
      </svg>
    </span>
  );
}

const search = "M7 12a5 5 0 1 1 0-10 5 5 0 0 1 0 10Zm3.5-1.5L14 14";
const filter = "M2 4h12M4.5 8h7M7 12h2";
const more = "M3 8h.01M8 8h.01M13 8h.01";

export function AllChatsDesigns({ design, hover = false, collapsed = false }: AllChatsDesignsProps) {
  return (
    <div className="acd-sidebar">
      <div className="acd-workspaces">Workspaces…</div>
      <section className="acd-section" data-design={design} data-hover={hover || undefined}>
        <header className="acd-header">
          <span className="acd-title">All chats</span>
          {!collapsed && (
            <span className="acd-icons">
              {design === "project" ? (
                <Icon d={more} label="More" />
              ) : (
                <>
                  <Icon d={search} label="Search" />
                  <Icon d={filter} label="Filter" />
                </>
              )}
            </span>
          )}
        </header>
        {!collapsed && (
          <ul className="acd-list">
            {chats.map((chat) => (
              <li key={chat.title} className="acd-row">
                {design === "quiet" && <span className="acd-glyph">{glyph[chat.harness]}</span>}
                <span className="acd-row-title">{chat.title}</span>
                {design === "age" && <span className="acd-meta">{chat.age}</span>}
                {design === "project" && <span className="acd-meta">{chat.project}</span>}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
