// l10n-allow-file: gallery fixture (sample commands, the old line's words), not shipped UI.
// A background command still running, in an opened run as the turn goes on (Leo, 2026-11-06: "when
// it says one background command running, why doesn't it just show it normally like the other
// ones? Why does it have to say background?"). The looks compared:
// - `inline` (chosen, shipped): the command is a row like every other step, its words shimmering
//   while it runs, as a foreground call's do; nothing under the steps, nothing names it background.
// - `edge-spinner`: the same row with a small turning ring at its trailing edge.
// - `edge-dot`: the same row with a small still dot at its trailing edge.
// - `before`: the line the run ended with before, "1 background command completed, 1 running",
//   redrawn here (its component is gone) for comparison.
// The two edge arms are gallery-only CSS over the shipped row (BackgroundCommandInline.gallery.css).
// References: cmux-design-references claude/live/transcript-tool-rows-and-task-list (a running call
// is a row like the rest, the live line under it), cmux-next/live/transcript-background-commands-summary-row
// (the count line this removes).
import { useEffect } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { Thinking } from "./Thinking";
import { ToolGroupRow } from "./ToolGroupRow";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { WorkingCountsContext, type WorkingCounts } from "./workingForModel";

type Look = "inline" | "edge-spinner" | "edge-dot" | "before";
type Props = { look: Look };

const START = Date.UTC(2026, 10, 6, 18, 0, 0);
const now = () => START + 94_000;
const counts: WorkingCounts = {
  agents: 0,
  commands: 1,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 12_400,
};

const run = [
  tool("bun run dev:api", "execute", "completed", {
    command: "bun run dev:api",
    background: { state: "running" },
  }),
  tool("git status --short", "execute", "completed", { command: "git status --short", output: " M src/api.ts\n" }),
  tool("bun run migrate", "execute", "completed", {
    command: "bun run migrate",
    background: { state: "completed", endedAt: START + 60_000 },
  }),
];

function BackgroundCommandInline({ look }: Props) {
  const session = `gallery-background-command-inline-${look}`;
  useEffect(() => resetTranscriptDisclosure(session), [session]);
  return (
    <TranscriptDisclosureProvider sessionId={session}>
      <main className="bg-command-inline acpmux-conversation" data-look={look}>
        <p className="bg-command-inline__prose">Starting the API in the background, then the migrations.</p>
        <div className="acpmux-row">
          <ToolGroupRow kind="commands" items={run} disclosureKey={`${session}:run`} />
          {look === "before" && (
            <output className="bg-command-inline__before">1 background command completed, 1 running</output>
          )}
        </div>
        <p className="bg-command-inline__prose">The API is up; checking the routes next.</p>
        <WorkingCountsContext.Provider value={counts}>
          <div className="acpmux-row acpmux-thinking">
            <Thinking since={START} now={now} below />
          </div>
        </WorkingCountsContext.Provider>
      </main>
    </TranscriptDisclosureProvider>
  );
}

const variant = (look: Look, note: string): ComponentVariant<Props> => ({ note, props: { look } });

export default componentEntry<Props>({
  id: "agent-pane.background-command-inline",
  title: "A running background command, inline like any other call",
  area: "Agent pane",
  pane: true,
  height: 340,
  widths: { narrow: 420, normal: 640, wide: 900 },
  covers: ["agent-session/acpmux/conversation/ToolGroupRow.tsx", "agent-session/acpmux/conversation/CommandRow.tsx"],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("./BackgroundCommandInline.gallery.css"),
    ]),
  load: async () => BackgroundCommandInline,
  keywords: ["background", "command", "running", "shimmer", "inline", "count", "banner"],
  variants: {
    inline: variant(
      "inline",
      "Chosen: the running command is a step like the rest, its words shimmering; nothing under the steps counts it.",
    ),
    "edge-spinner": variant("edge-spinner", "The same row with a small turning ring at its edge."),
    "edge-dot": variant("edge-dot", "The same row with a small still dot at its edge."),
    before: variant("before", "Before: the run ends with 1 background command completed, 1 running."),
  },
});
