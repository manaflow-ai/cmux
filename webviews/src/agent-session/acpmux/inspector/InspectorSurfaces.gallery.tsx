// l10n-allow-file: gallery fixtures (sample paths and code), not shipped UI.
// The Inspector beside what the chat pane shows: the header with its toggle, the transcript, and a
// turn's diff open in place over the pane (App.tsx DiffPanel). Leo, 2026-10-22, the Inspector over a
// diff: "WHY DOES IT STAY ON IN THESE RANDOM SITUATIONS WITHOUT BEING CLOSABLE!?" The panel is the
// real useChatInspector's, open as the viewer left it (inspectorState.ts), so each state shows where
// it draws, and whether its toggle can be reached, with the surface under it.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, chat, CWD, tool } from "../../../gallery/fixtures/acpmux";
import { DiffPanel } from "../DiffPanel";
import { diffHunks, diffLines, type TurnFile } from "../diff";
import { ChatHeaderTools } from "../header/ChatHeaderTools";
import { setHeaderState } from "../header/headerState";
import { useChatInspector } from "./ChatInspector";
import { setInspectorOpen } from "./inspectorState";

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

type Surface = "transcript" | "diff";
type Props = { surface: Surface };

function GalleryPane({ surface: initial }: Props) {
  const [surface, setSurface] = useState<Surface>(() => {
    // The viewer left the Inspector open (it holds in every chat tab), and the header offers it.
    setHeaderState({ inspector: true });
    setInspectorOpen(true);
    return initial;
  });
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const inspector = useChatInspector({ snapshot, machineName: "Studio Mac", shell });
  const diff = surface === "diff";
  return (
    <section
      className="acpmux-shell"
      data-gallery-surface={surface}
      ref={(element) => {
        if (element && element !== shell) setShell(element);
      }}
    >
      <div className="acpmux-main">
        <div className={`acpmux-stage${diff ? " acpmux-reviewing" : ""}`}>
          <header className="acpmux-header">
            <div />
            <div className="acpmux-handoff-header-tools">
              <ChatHeaderTools
                onTerminal={() => undefined}
                onBrowser={() => undefined}
                hasChanges
                onChanges={() => setSurface("diff")}
                summary={null}
                menu={() => []}
                inspector={inspector.button}
              />
            </div>
          </header>
          <div className="acpmux-scroll" style={{ padding: "16px 24px", overflow: "hidden" }}>
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
          {diff && <DiffPanel files={files} onClose={() => setSurface("transcript")} />}
        </div>
      </div>
      {inspector.panel}
    </section>
  );
}

const panelState = (ctx: Parameters<Play>[0]) =>
  ctx.document.querySelector("aside.acpmux-chat-inspector")?.getAttribute("data-presence") ?? "none";

export default componentEntry<Props>({
  id: "agent-pane.chat-inspector-surfaces",
  title: "Inspector beside the pane's views",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 900, normal: 1280 },
  covers: ["agent-session/acpmux/inspector/ChatInspector.tsx#InspectorPanel"],
  load: async () => GalleryPane,
  variants: {
    transcript: {
      note: "The Inspector open over the transcript: it starts under the header, so its toggle (pressed) and its own x both close it.",
      props: { surface: "transcript" },
    },
    "diff-in-place": {
      note: "A turn's diff open in place over the pane, with the Inspector left open: the diff's toolbar and code lines, and where the Inspector is.",
      props: { surface: "diff" },
    },
    "diff-closed": {
      note: "The diff's back button returns to the transcript: the Inspector the viewer left open is there again.",
      props: { surface: "diff" },
      play: async (ctx) => {
        await ctx.click({ selector: "button.acpmux-diff-back" });
        await ctx.waitFor(() => panelState(ctx) === "shown");
      },
    },
  },
});
