// The ported agent pane: session list | title row + transcript or new chat + composer |
// Changes panel, laid out as the reference's main window (overview.png, changes.png).
// acpmux owns every session fact; this component holds only view state (sidebar and panel
// visibility, the turn whose changes are shown).
import { useState } from "react";
import { useAcpmuxPane, act } from "./useAcpmuxPane";
import { SessionSidebar } from "./SessionSidebar";
import { TitleRow } from "./TitleRow";
import { ChatView } from "./ChatView";
import { NewChatHero } from "./NewChatHero";
import { PromptComposer } from "./PromptComposer";
import { PermissionCard } from "./PermissionCard";
import { ChangesPanel } from "./ChangesPanel";
import { useMediaQuery } from "./useMediaQuery";
import { SearchPalette } from "./SearchPalette";
import { useKeyCommand } from "./useKeyCommand";
import { projectLabel, sessionTitle } from "../data/acpmux";
import { mockGitSource } from "../git/gitSource";
import { isNewChat, type PortTurn } from "../viewModel/acpmuxTurns";

/** Wide enough for the session list beside the transcript (the reference's 238px column). */
const WIDE = "(min-width: 760px)";

export function PortApp() {
  const { snapshot, draft } = useAcpmuxPane();
  const wide = useMediaQuery(WIDE);
  const [sidebar, setSidebar] = useState<"auto" | "open" | "closed">("auto");
  const [changes, setChanges] = useState<{ turn?: PortTurn } | undefined>();
  const [searching, setSearching] = useState(false);
  useKeyCommand("k", () => setSearching((open) => !open));
  const sidebarOpen = sidebar === "open" || (sidebar === "auto" && wide);
  const summary = snapshot.summary;
  const session = snapshot.sessions.find((entry) => entry.sessionId === snapshot.sessionId);
  const cwd = summary?.cwd ?? session?.cwd;
  const project = cwd ? projectLabel(cwd) : undefined;
  const fresh = isNewChat(snapshot);
  const title = fresh
    ? "New chat"
    : (session?.displayTitle ?? (summary ? sessionTitle({ ...summary, sessionId: summary.sessionId }) : "Agent"));
  const composer = (
    <>
      {snapshot.permission?.pending && <PermissionCard permission={snapshot.permission} />}
      <PromptComposer
        // A new session starts with an empty draft.
        key={snapshot.sessionId ?? "new"}
        snapshot={snapshot}
        draft={draft}
        context={
          fresh ? { project, host: summary?.host ?? "Local", branch: summary?.branch ?? session?.branch } : undefined
        }
        onSend={(text) => act("chat.send", { text })}
        onStop={() => act("chat.cancel")}
      />
    </>
  );
  return (
    <section
      className="pt-pane"
      data-sidebar={sidebarOpen ? "open" : "closed"}
      data-changes={changes ? "open" : "closed"}
    >
      {sidebarOpen && (
        <div className="pt-pane__sidebar">
          <SessionSidebar
            sessions={snapshot.sessions}
            selectedId={snapshot.sessionId}
            onSelect={(sessionId) => {
              if (!wide) setSidebar("auto");
              act("chat.select", { sessionId });
            }}
            onNewChat={() => act("chat.new")}
            onSearch={() => setSearching(true)}
          />
        </div>
      )}
      <div className="pt-pane__main">
        <TitleRow
          title={title}
          inProject={Boolean(project)}
          sidebarOpen={sidebarOpen}
          changesOpen={Boolean(changes)}
          onToggleSidebar={() => setSidebar(sidebarOpen ? "closed" : "open")}
          onToggleChanges={() => setChanges((current) => (current ? undefined : {}))}
        />
        <div className="pt-pane__body">
          {fresh ? (
            <NewChatHero project={project} composer={composer} />
          ) : (
            <ChatView snapshot={snapshot} composer={composer} onViewChanges={(turn) => setChanges({ turn })} />
          )}
        </div>
      </div>
      {changes && (
        <div className="pt-pane__panel">
          <ChangesPanel git={mockGitSource} cwd={cwd ?? "/"} turn={changes.turn} />
        </div>
      )}
      {/^(connecting|disconnected|error)/.test(snapshot.connection) && (
        <output className="pt-connection">
          {snapshot.connection.startsWith("connecting") ? "Connecting to agents…" : snapshot.connection}
        </output>
      )}
      {searching && (
        <SearchPalette
          sessions={snapshot.sessions}
          onClose={() => setSearching(false)}
          onSelect={(sessionId) => {
            setSearching(false);
            act("chat.select", { sessionId });
          }}
          onNewChat={() => {
            setSearching(false);
            act("chat.new");
          }}
        />
      )}
    </section>
  );
}
