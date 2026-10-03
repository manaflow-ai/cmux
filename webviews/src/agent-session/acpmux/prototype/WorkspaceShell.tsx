// Sidebar prototype (#16688), dev server only: prototype.html. One stack of open workspaces is the
// main sidebar; agent history (the pane's project-grouped session list) is a layer opened from the
// rail, and opening a row there jumps to the tab already showing it instead of opening a copy.
// Dots at the bottom switch spaces, and links from a terminal open in the mini window
// until Cmd-O promotes them into the workspace.
import { useCallback, useEffect, useMemo, useState } from "react";
import { AcpmuxApp } from "../App";
import { mockSessions, sessionSummary } from "../mockFixture";
import { SessionSidebar } from "../SessionSidebar";
import { sessionEntry, sessionMark, type AcpmuxSessionEntry } from "../sessionList";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import {
  AgentIcon,
  BrowserIcon,
  CloseIcon,
  HistoryIcon,
  PlusIcon,
  PromoteIcon,
  StackIcon,
  TerminalIcon,
} from "./icons";
import {
  activeSpace,
  browserProfileById,
  effectiveBrowserProfile,
  openFromHistoryInSpaces,
  openMini,
  promoteMini,
  seedSpaces,
  stepSpace,
  switchSpace,
  withStack,
  type MiniWindow,
  type Space,
  type Spaces,
} from "./spaces";
import {
  newTerminalWorkspace,
  openSessionIds,
  selectTab,
  terminalFirst,
  workspaceLead,
  type Stack,
  type TabKind,
  type Workspace,
  type WorkspaceTab,
} from "./workspaces";

const KIND_ICONS: Record<TabKind, (props: { size?: number }) => React.ReactElement> = {
  agent: AgentIcon,
  terminal: TerminalIcon,
  browser: BrowserIcon,
};
const MARK_SIZE = rowIconSize(13);
const MARKS = {
  input: <Icon name="status.needsinput" size={MARK_SIZE} row />,
  running: <Icon name="status.running" size={MARK_SIZE} row />,
  error: <Icon name="status.disconnected" size={MARK_SIZE} row />,
};

/** The fixture's sessions as the history layer lists them. */
const history: AcpmuxSessionEntry[] = (() => {
  const now = Date.now();
  return mockSessions.map((session) => sessionEntry(sessionSummary(session, now, 1) as AcpmuxSessionEntry));
})();
const historyById = new Map(history.map((session) => [session.sessionId, session]));

const selectInPane = (sessionId: string) => void window.cmuxAcpmuxActions?.["chat.select"]?.({ sessionId });

/** A link a terminal printed, for the mini window. */
const TERMINAL_LINK = {
  url: "upload-retry.cmux-preview.pages.dev/fleet",
  title: "Fleet uploads: retry preview",
};

const params = new URLSearchParams(location.search);
/** `?style=terminal`: classic cmux. The chrome takes the terminal's font and a new workspace is a
 * terminal; agents and browsers stay available but nothing pushes them. Translucency is untouched. */
const terminalStyle = params.get("style") === "terminal";
const spaceFromURL = switchSpace(seedSpaces, params.get("space") ?? seedSpaces.activeId);
const initialSpaces = terminalStyle
  ? withStack(spaceFromURL, terminalFirst(activeSpace(spaceFromURL).stack))
  : spaceFromURL;

export function WorkspaceShell() {
  const [spaces, setSpaces] = useState<Spaces>(initialSpaces);
  const [historyOpen, setHistoryOpen] = useState(() => params.has("history"));
  const [mini, setMini] = useState<MiniWindow | undefined>(() =>
    params.has("mini")
      ? openMini(initialSpaces, TERMINAL_LINK, { kind: "terminal", label: "upload-retry" })
      : undefined,
  );
  const [flash, setFlash] = useState<string>();
  const space = activeSpace(spaces);
  const stack = space.stack;
  const active = stack.workspaces.find((workspace) => workspace.id === stack.activeId)!;
  const activeTab = active.tabs.find((tab) => tab.id === active.activeTabId)!;
  const openIds = useMemo(() => new Set(spaces.spaces.flatMap((each) => [...openSessionIds(each.stack)])), [spaces]);

  const showSpaces = useCallback((next: Spaces) => {
    setSpaces(next);
    const stack = activeSpace(next).stack;
    const workspace = stack.workspaces.find((candidate) => candidate.id === stack.activeId)!;
    const tab = workspace.tabs.find((candidate) => candidate.id === workspace.activeTabId)!;
    if (tab.sessionId) selectInPane(tab.sessionId);
  }, []);
  const show = useCallback((next: Stack) => showSpaces(withStack(spaces, next)), [spaces, showSpaces]);

  const openSession = useCallback(
    (sessionId: string) => {
      const result = openFromHistoryInSpaces(spaces, historyById.get(sessionId) ?? { sessionId });
      showSpaces(result.spaces);
      setHistoryOpen(false);
      // A jump points at the workspace it landed on, so the user sees nothing was duplicated.
      setFlash(activeSpace(result.spaces).stack.activeId);
    },
    [spaces, showSpaces],
  );

  const promote = useCallback(() => {
    if (!mini) return;
    const result = promoteMini(spaces, mini);
    showSpaces(result.spaces);
    setMini(undefined);
    setFlash(mini.workspaceId);
  }, [mini, spaces, showSpaces]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      // Ctrl-Opt-1..9 select a space, Cmd-Opt-] and [ step through them (data-model.md 7).
      const digit = /^Digit([1-9])$/.exec(event.code);
      if (event.ctrlKey && event.altKey && digit) {
        const target = spaces.spaces[Number(digit[1]) - 1];
        if (target) showSpaces(switchSpace(spaces, target.id));
      } else if (event.metaKey && event.altKey && (event.code === "BracketRight" || event.code === "BracketLeft")) {
        showSpaces(stepSpace(spaces, event.code === "BracketRight" ? 1 : -1));
      } else if (mini && event.metaKey && event.key.toLowerCase() === "o") {
        promote();
      } else if (mini && (event.key === "Escape" || (event.metaKey && event.key.toLowerCase() === "w"))) {
        setMini(undefined);
      } else return;
      event.preventDefault();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [spaces, mini, promote, showSpaces]);

  useEffect(() => {
    if (!flash) return;
    const timer = setTimeout(() => setFlash(undefined), 900);
    return () => clearTimeout(timer);
  }, [flash]);

  useEffect(() => {
    if (!historyOpen) return;
    const onKey = (event: KeyboardEvent) => event.key === "Escape" && setHistoryOpen(false);
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [historyOpen]);

  return (
    <div
      className="proto-window"
      data-history={historyOpen ? "open" : "closed"}
      style={{ "--space-accent": `var(--proto-${space.color ?? "overlay"})` } as React.CSSProperties}
      data-style={terminalStyle ? "terminal" : undefined}
    >
      <div className="proto-lights" aria-hidden="true">
        <i />
        <i />
        <i />
      </div>
      <nav className="proto-rail" aria-label="Sidebars">
        <button type="button" className="proto-rail-button is-active" aria-label="Workspaces" title="Workspaces">
          <StackIcon />
        </button>
        <button
          type="button"
          className={`proto-rail-button${historyOpen ? " is-active" : ""}`}
          aria-label="History"
          aria-expanded={historyOpen}
          title="History"
          onClick={() => setHistoryOpen((open) => !open)}
        >
          <HistoryIcon />
        </button>
        <button
          type="button"
          className="proto-rail-button"
          aria-label="New workspace"
          title={terminalStyle ? "New workspace (terminal)" : "New workspace"}
          // Only classic cmux's terminal workspace is modelled; a new chat needs the pane to name its session.
          onClick={terminalStyle ? () => show(newTerminalWorkspace(stack)) : undefined}
        >
          <PlusIcon />
        </button>
      </nav>

      <nav className="proto-stack" aria-label="Workspaces">
        <div className="proto-stack-label">
          <span>{space.name}</span>
          <ProfileChip id={space.browserProfile} />
        </div>
        <ul key={space.id} className="proto-stack-list">
          {stack.workspaces.map((workspace) => (
            <WorkspaceRow
              key={workspace.id}
              workspace={workspace}
              active={workspace.id === stack.activeId}
              flash={workspace.id === flash}
              onSelect={(tabId) => show(selectTab(stack, workspace.id, tabId))}
            />
          ))}
        </ul>
        <SpaceDots spaces={spaces} onSelect={(id) => showSpaces(switchSpace(spaces, id))} />
      </nav>

      {historyOpen && (
        <>
          <button
            type="button"
            className="proto-scrim"
            aria-label="Close history"
            onClick={() => setHistoryOpen(false)}
          />
          <aside className="proto-history" aria-label="History">
            <header>
              <div>
                <h2>History</h2>
                <p>Past and imported agent sessions</p>
              </div>
              <button type="button" aria-label="Close history" onClick={() => setHistoryOpen(false)}>
                <CloseIcon />
              </button>
            </header>
            <SessionSidebar
              sessions={history}
              selectedId={activeTab.sessionId}
              openIds={openIds}
              onSelect={openSession}
            />
          </aside>
        </>
      )}

      <main className="proto-content">
        <div className="proto-tabs" role="tablist" aria-label={workspaceLead(active).title}>
          {active.tabs.map((tab) => {
            const KindIcon = KIND_ICONS[tab.kind];
            return (
              <button
                key={tab.id}
                type="button"
                role="tab"
                aria-selected={tab.id === activeTab.id}
                className={`proto-tab proto-tab-${tab.kind}`}
                onClick={() => show(selectTab(stack, active.id, tab.id))}
              >
                <KindIcon size={14} />
                <span>{tab.kind === "browser" && tab.id === activeTab.id ? tab.url : tab.title}</span>
              </button>
            );
          })}
        </div>
        <div className="proto-body">
          <div className="proto-agent" hidden={activeTab.kind !== "agent"}>
            <AcpmuxApp />
          </div>
          {activeTab.kind === "terminal" && (
            <TerminalMock
              tab={activeTab}
              onOpenLink={() =>
                setMini(
                  openMini(
                    spaces,
                    TERMINAL_LINK,
                    { kind: "terminal", label: activeTab.title },
                    { spaceId: space.id, workspaceId: active.id },
                  ),
                )
              }
            />
          )}
          {activeTab.kind === "browser" && (
            <BrowserMock tab={activeTab} profile={activeTab.browserProfile ?? effectiveBrowserProfile(space, active)} />
          )}
        </div>
      </main>

      {mini && <MiniBrowser mini={mini} spaces={spaces} onPromote={promote} onClose={() => setMini(undefined)} />}
    </div>
  );
}

function WorkspaceRow({
  workspace,
  active,
  flash,
  onSelect,
}: {
  workspace: Workspace;
  active: boolean;
  flash: boolean;
  onSelect: (tabId: string) => void;
}) {
  const lead = workspaceLead(workspace);
  const KindIcon = KIND_ICONS[lead.kind];
  const session = lead.sessionId ? historyById.get(lead.sessionId) : undefined;
  const mark = session && sessionMark(session, active);
  return (
    <li>
      <button
        type="button"
        className={`proto-workspace${active && workspace.activeTabId === lead.id ? " is-active" : active ? " is-current" : ""}${flash ? " is-flash" : ""}${lead.kind === "agent" ? " is-agent" : ""}`}
        aria-current={active ? "true" : undefined}
        onClick={() => onSelect(lead.id)}
      >
        <KindIcon />
        <span className="proto-workspace-title">{lead.title}</span>
        {mark && mark !== "unread" ? (
          <span className={`acpmux-session-mark acpmux-session-mark-${mark}`} aria-label={mark}>
            {MARKS[mark]}
          </span>
        ) : (
          !active && workspace.tabs.length > 1 && <span className="proto-workspace-count">{workspace.tabs.length}</span>
        )}
      </button>
      {active && workspace.tabs.length > 1 && (
        <ul className="proto-workspace-tabs">
          {/* The workspace row stands for its lead tab; the rest list under it. */}
          {workspace.tabs
            .filter((tab) => tab !== lead)
            .map((tab) => {
              const TabIcon = KIND_ICONS[tab.kind];
              return (
                <li key={tab.id}>
                  <button
                    type="button"
                    className={`proto-workspace-tab${tab.id === workspace.activeTabId ? " is-active" : ""}`}
                    onClick={() => onSelect(tab.id)}
                  >
                    <TabIcon size={14} />
                    <span>{tab.kind === "browser" ? (tab.url ?? tab.title) : tab.title}</span>
                  </button>
                </li>
              );
            })}
        </ul>
      )}
    </li>
  );
}

function TerminalMock({ tab, onOpenLink }: { tab: WorkspaceTab; onOpenLink: () => void }) {
  return (
    <pre className="proto-terminal">
      <span className="acpmux-hidden-label">{tab.title}</span>
      <span className="t-dim">~/code/cmux</span> <span className="t-accent">feat-cmux-next</span>
      {"\n"}
      <span className="t-prompt">❯</span> bun test src/agent-session{"\n"}
      {"bun test v1.3.14\n\n"}
      <span className="t-dim">src/agent-session/acpmux/sessionList.test.ts:</span>
      {"\n"}
      <span className="t-ok">✓</span> sections {">"} one folder on two machines is one project{" "}
      <span className="t-dim">[0.31ms]</span>
      {"\n"}
      <span className="t-ok">✓</span> sections {">"} a search never splits a project{" "}
      <span className="t-dim">[0.12ms]</span>
      {"\n"}
      <span className="t-ok">✓</span> direct client {">"} a background turn marks its session unread{" "}
      <span className="t-dim">[1.84ms]</span>
      {"\n\n"}
      <span className="t-ok"> 291 pass</span>
      {"\n 0 fail\n 1004 expect() calls\nRan 291 tests across 33 files. "}
      <span className="t-dim">[3.62s]</span>
      {"\n\n"}
      <span className="t-dim">~/code/cmux</span> <span className="t-accent">feat-cmux-next</span>{" "}
      <span className="t-warn">✚2</span>
      {"\n"}
      <span className="t-prompt">❯</span> git status --short{"\n"}
      <span className="t-warn"> M</span>
      {" webviews/src/agent-session/acpmux/direct.ts\n"}
      <span className="t-warn"> M</span>
      {" webviews/src/agent-session/acpmux/direct.test.ts\n\n"}
      <span className="t-prompt">❯</span> bunx wrangler pages deploy dist{"\n"}
      {"✨ Deployment complete! Take a peek over at\n"}
      <button type="button" className="proto-terminal-link" onClick={onOpenLink}>
        {`https://${TERMINAL_LINK.url}`}
      </button>
      {"\n\n"}
      <span className="t-prompt">❯</span> <span className="t-cursor"> </span>
    </pre>
  );
}

function ProfileChip({ id }: { id: string }) {
  const profile = browserProfileById.get(id)!;
  return (
    <span className="proto-profile" title={`Browser profile: ${profile.name}`}>
      <i style={{ background: `var(--proto-${profile.color})` }} />
      {profile.name}
    </span>
  );
}

/** Placeholder page: a title over a few lines of text. */
function PageMock({ title, url }: { title: string; url?: string }) {
  return (
    <div className="proto-page">
      <small>{url}</small>
      <h1>{title}</h1>
      {[92, 84, 88, 60, 0, 90, 76, 82, 44].map((width, index) => (
        <span key={index} className={width ? undefined : "is-break"} style={{ width: `${width || 100}%` }} />
      ))}
    </div>
  );
}

function BrowserMock({ tab, profile }: { tab: WorkspaceTab; profile: string }) {
  return (
    <div className="proto-browser">
      <div className="proto-omnibar">
        <span>{tab.url}</span>
        <ProfileChip id={profile} />
      </div>
      <PageMock title={tab.title} url={tab.url} />
    </div>
  );
}

/** The space dots at the bottom of the sidebar: hidden with one space, the current one stronger. */
function SpaceDots({ spaces, onSelect }: { spaces: Spaces; onSelect: (spaceId: string) => void }) {
  if (spaces.spaces.length < 2) return null;
  return (
    <div className="proto-spaces" role="tablist" aria-label="Spaces">
      {spaces.spaces.map((space: Space, index) => (
        <button
          key={space.id}
          type="button"
          role="tab"
          aria-selected={space.id === spaces.activeId}
          aria-label={space.name}
          title={`${space.name} (Ctrl-Opt-${index + 1})`}
          className="proto-space-dot"
          style={{ "--dot": `var(--proto-${space.color ?? "overlay"})` } as React.CSSProperties}
          onClick={() => onSelect(space.id)}
        >
          <i />
        </button>
      ))}
      <button type="button" className="proto-space-dot proto-space-add" aria-label="New space" title="New space">
        <PlusIcon />
      </button>
    </div>
  );
}

/** The mini window: a small window over the main one, for a link opened from outside a browser tab. */
function MiniBrowser({
  mini,
  spaces,
  onPromote,
  onClose,
}: {
  mini: MiniWindow;
  spaces: Spaces;
  onPromote: () => void;
  onClose: () => void;
}) {
  const space = spaces.spaces.find((candidate) => candidate.id === mini.spaceId)!;
  const target = space.stack.workspaces.find((candidate) => candidate.id === mini.workspaceId)!;
  return (
    <section className="proto-mini" aria-label="Mini window">
      <header>
        <div className="proto-lights proto-mini-lights">
          <button type="button" aria-label="Close" onClick={onClose} />
          <i />
          <i />
        </div>
        <span className="proto-mini-url">{mini.url}</span>
        <ProfileChip id={mini.browserProfile} />
      </header>
      <PageMock title={mini.title} url={mini.url} />
      <footer>
        <span className="proto-mini-source">
          <TerminalIcon size={14} />
          <span>
            From {mini.source.label} · <b>{workspaceLead(target).title}</b>
          </span>
        </span>
        <button
          type="button"
          className="proto-mini-promote"
          title={`Open as a tab in ${workspaceLead(target).title}`}
          onClick={onPromote}
        >
          <PromoteIcon />
          Open as tab
          <kbd>⌘O</kbd>
        </button>
      </footer>
    </section>
  );
}
