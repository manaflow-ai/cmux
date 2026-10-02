// Sidebar prototype (#16688), dev server only: prototype.html. One stack of open workspaces is the
// main sidebar; agent history (the pane's project-grouped session list) is a layer opened from the
// rail, and opening a row there jumps to the tab already showing it instead of opening a copy.
import { useCallback, useEffect, useMemo, useState } from "react";
import { AcpmuxApp } from "../App";
import { mockSessions, sessionSummary } from "../mockFixture";
import { SessionSidebar } from "../SessionSidebar";
import { sessionEntry, sessionMark, type AcpmuxSessionEntry } from "../sessionList";
import { DisconnectedIcon, NeedsInputIcon, WorkingIcon } from "../sidebarIcons";
import { AgentIcon, BrowserIcon, CloseIcon, HistoryIcon, PlusIcon, StackIcon, TerminalIcon } from "./icons";
import {
  newWorkspace,
  openFromHistory,
  openSessionIds,
  seedStack,
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
const MARKS = { input: <NeedsInputIcon />, running: <WorkingIcon />, error: <DisconnectedIcon /> };

/** The fixture's sessions as the history layer lists them. */
const history: AcpmuxSessionEntry[] = (() => {
  const now = Date.now();
  return mockSessions.map((session) => sessionEntry(sessionSummary(session, now, 1) as AcpmuxSessionEntry));
})();
const historyById = new Map(history.map((session) => [session.sessionId, session]));

const selectInPane = (sessionId: string) => void window.cmuxAcpmuxActions?.["chat.select"]?.({ sessionId });

/** `?style=terminal`: classic cmux. The chrome takes the terminal's font and a new workspace is a
 * terminal; agents and browsers stay available but nothing pushes them. Translucency is untouched. */
const terminalStyle = new URLSearchParams(location.search).get("style") === "terminal";

export function WorkspaceShell() {
  const [stack, setStack] = useState<Stack>(() => (terminalStyle ? terminalFirst(seedStack) : seedStack));
  const [historyOpen, setHistoryOpen] = useState(() => new URLSearchParams(location.search).has("history"));
  const [flash, setFlash] = useState<string>();
  const active = stack.workspaces.find((workspace) => workspace.id === stack.activeId)!;
  const activeTab = active.tabs.find((tab) => tab.id === active.activeTabId)!;
  const openIds = useMemo(() => openSessionIds(stack), [stack]);

  const show = useCallback((next: Stack) => {
    setStack(next);
    const workspace = next.workspaces.find((candidate) => candidate.id === next.activeId)!;
    const tab = workspace.tabs.find((candidate) => candidate.id === workspace.activeTabId)!;
    if (tab.sessionId) selectInPane(tab.sessionId);
  }, []);

  const openSession = useCallback(
    (sessionId: string) => {
      const result = openFromHistory(stack, historyById.get(sessionId) ?? { sessionId });
      show(result.stack);
      setHistoryOpen(false);
      // A jump points at the workspace it landed on, so the user sees nothing was duplicated.
      setFlash(result.stack.activeId);
    },
    [stack, show],
  );

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
          onClick={() => {
            show(newWorkspace(stack, terminalStyle ? "terminal" : "agent"));
            if (!terminalStyle) void window.cmuxAcpmuxActions?.["chat.new"]?.({});
          }}
        >
          <PlusIcon />
        </button>
      </nav>

      <nav className="proto-stack" aria-label="Workspaces">
        <div className="proto-stack-label">Workspaces</div>
        <ul>
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
            const Icon = KIND_ICONS[tab.kind];
            return (
              <button
                key={tab.id}
                type="button"
                role="tab"
                aria-selected={tab.id === activeTab.id}
                className={`proto-tab proto-tab-${tab.kind}`}
                onClick={() => show(selectTab(stack, active.id, tab.id))}
              >
                <Icon size={14} />
                <span>{tab.kind === "browser" && tab.id === activeTab.id ? tab.url : tab.title}</span>
              </button>
            );
          })}
        </div>
        <div className="proto-body">
          <div className="proto-agent" hidden={activeTab.kind !== "agent"}>
            <AcpmuxApp />
          </div>
          {activeTab.kind === "terminal" && <TerminalMock tab={activeTab} />}
          {activeTab.kind === "browser" && <BrowserMock tab={activeTab} />}
        </div>
      </main>
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
  const Icon = KIND_ICONS[lead.kind];
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
        <Icon />
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

function TerminalMock({ tab }: { tab: WorkspaceTab }) {
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
      <span className="t-prompt">❯</span> <span className="t-cursor"> </span>
    </pre>
  );
}

function BrowserMock({ tab }: { tab: WorkspaceTab }) {
  return (
    <div className="proto-browser">
      <div>{tab.title}</div>
      <small>{tab.url}</small>
    </div>
  );
}
