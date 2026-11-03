// l10n-allow-file: gallery fixtures (sample paths and code), not shipped UI.
// Session Info beside what the chat pane shows: the header with its toggle, the transcript, and a
// document in the side panel. A turn's diff never opens in the pane (it is a tab on the chat's right,
// turnChanges/viewChanges.ts). The panel is the real useSessionInfo's, open as the viewer left it
// (sessionInfoState.ts), wired as App.tsx wires it (`beside` with a document in the side panel), so
// each state shows where it draws, and whether its toggle can be reached, with the surface under it.
import { useEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { activity, chat, CWD, tool } from "../../../gallery/fixtures/acpmux";
import { ArtifactPanel, useArtifactCoversPane } from "../conversation/ArtifactPanel";
import { ChatFindBar } from "../conversation/ChatFindBar";
import { useChatFind } from "../conversation/chatFind";
import { diffHunks, diffLines, type TurnFile } from "../diff";
import { ChatHeaderTools } from "../header/ChatHeaderTools";
import { setHeaderState } from "../header/headerState";
import { useSessionInfo } from "./SessionInfo";
import { setSessionInfoOpen } from "./sessionInfoState";

const BEFORE = "#!/bin/bash\nexport PATH=/usr/local/bin:$PATH\n";
const AFTER = [
  "#!/bin/bash",
  "export PATH=/usr/local/bin:$PATH",
  'send() { timeout 1200 acpmux send --no-wait "$@"; echo "$2 rc=$?"; }',
  "send app-efficiency - <<'M' &",
  "Harness first. One perf harness covering split, open and close of the side pane, and the sidebar.",
  "One layout pass per frame. Coalesce invalidations to a single display-link-driven pass.",
  "Animate transforms and opacity on layers, not frames and widths.",
  "M",
  "send sidebar-rows - <<'M' &",
  "New workspaces at the top of the list.",
  "M",
  "wait",
  "",
].join("\n");

const changed = (path: string, before: string | undefined, after: string): TurnFile => {
  const hunks = diffHunks(diffLines(before, after));
  const count = (type: string) =>
    hunks.reduce((sum, hunk) => sum + hunk.lines.filter((l) => l.type === type).length, 0);
  return {
    path,
    displayPath: path,
    edits: [{ toolId: `gallery-${path}`, hunks, numbered: true }],
    additions: count("add"),
    deletions: count("del"),
    created: before === undefined,
    deleted: false,
  };
};
const files = [changed("scripts/batch103.sh", undefined, AFTER), changed("scripts/batch104.sh", BEFORE, AFTER)];

const snapshot = chat([
  activity(
    files.map((file) =>
      tool(`Edit ${file.path}`, "edit", "completed", {
        diffs: [{ path: `${CWD}/${file.path}`, newText: AFTER }],
      }),
    ),
    3,
  ),
]);

const TRANSCRIPT = [
  "Write the two batch scripts that send each lane its brief.",
  "Both scripts are in scripts/: batch103.sh sends app-efficiency and sidebar-rows their briefs, batch104.sh the next two. Each waits for its sends.",
  "Show me the diff.",
];

/// A document the chat produced, open in the side panel beside the chat.
const DOCUMENT = {
  kind: "markdown" as const,
  lang: "markdown",
  code: "# Lane briefs\n\n- app-efficiency: one perf harness first\n- sidebar-rows: new workspaces at the top\n",
};

type Surface = "transcript" | "document";
type Props = { surface: Surface; find?: boolean };

/// Find in Chat over the pane's sample rows, opened by Cmd-F as the App's page action opens it.
function GalleryFind() {
  const find = useChatFind(snapshot.rows);
  const { show } = find;
  useEffect(() => {
    const open = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
        event.preventDefault();
        show();
      }
    };
    document.addEventListener("keydown", open);
    return () => document.removeEventListener("keydown", open);
  }, [show]);
  return find.open ? <ChatFindBar find={find} /> : null;
}

export function GalleryPane({ surface: initial, find }: Props) {
  const [surface, setSurface] = useState<Surface>(initial);
  const narrowPane = useArtifactCoversPane();
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const sessionInfo = useSessionInfo({
    snapshot,
    machineName: "Studio Mac",
    shell,
    covered: narrowPane && surface === "document",
    onUncover: () => setSurface("transcript"),
    beside: surface === "document" ? 1 : undefined,
  });
  return (
    <section
      className="acpmux-shell"
      data-gallery-surface={surface}
      ref={(element) => {
        if (element && element !== shell) setShell(element);
      }}
    >
      <div className="acpmux-main">
        <div className="acpmux-stage">
          <header className="acpmux-header">
            <div />
            <div className="acpmux-handoff-header-tools">
              <ChatHeaderTools
                onTerminal={() => undefined}
                onBrowser={() => undefined}
                hasChanges
                onChanges={() => undefined}
                summary={null}
                menu={() => []}
                sessionInfo={sessionInfo.button}
              />
            </div>
          </header>
          <div className="acpmux-scroll" style={{ padding: "16px 24px", overflow: "hidden" }}>
            {find && <GalleryFind />}
            {TRANSCRIPT.map((line, index) =>
              index % 2 === 0 ? (
                <div key={line} className="acpmux-user" style={{ margin: "12px 0" }}>
                  <div className="acpmux-user-bubble">{line}</div>
                </div>
              ) : (
                <div key={line} className="acpmux-markdown" style={{ margin: "12px 0" }}>
                  <p>{line}</p>
                </div>
              ),
            )}
          </div>
        </div>
      </div>
      {sessionInfo.panel}
      {surface === "document" && <ArtifactPanel artifact={DOCUMENT} onClose={() => setSurface("transcript")} />}
    </section>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.chat-inspector-surfaces",
  title: "Session Info beside the pane's views",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 900, normal: 1280 },
  covers: ["agent-session/acpmux/session-info/SessionInfo.tsx#SessionInfoPanel"],
  load: async () => {
    // The viewer left Session Info open (each pane keeps its own), and the header offers it.
    setHeaderState({ inspector: true });
    setSessionInfoOpen(true);
    return GalleryPane;
  },
  variants: {
    transcript: {
      note: "Session Info open over the transcript: it starts under the header, so its toggle (pressed) and its own x both close it.",
      props: { surface: "transcript" },
    },
    "document-beside": {
      note: "A document open in the side panel beside the chat: Session Info measures the chat's room without it and pushes the chat, never lying over the document.",
      props: { surface: "document" },
    },
  },
});
