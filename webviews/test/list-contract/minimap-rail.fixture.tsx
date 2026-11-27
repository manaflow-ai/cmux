// l10n-allow-file: fixture prompts, not shipped UI.
// The thread minimap's compact rail (the chat's left edge): one tick row per prompt, windowed by
// tickWindow.ts. Mounted inside the chat's transcript, as the pane mounts it (thread-minimap.harness).
import { useEffect, useMemo } from "react";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
// desktop.css holds the layers: without it the transcript paints over the rail and takes its hover.
import "../../src/pages/shared/desktop.css";
import "../../src/ui/ui.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";
import { listFixture } from "./listFixture";

// The pane's strings, as dev.tsx installs them: without them a tick's label is its key and never
// names its prompt, so an edited prompt would change no row.
globalThis.__cmuxPaneStrings ??= strings;
// The default arm draws no minimap (layout.experiment.ts); the rail is the compact arm.
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

/// One prompt: the person's message, the reply and the turn's end, as the transcript holds them.
type Turn = readonly AcpmuxRow[];
const row = (id: string, kind: string, text?: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at: 1,
  ...extra,
});
const none = () => {};
const folded = new Set<string>();

export default listFixture<Turn>({
  source: "agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#TickList",
  rows: ".acpmux-minimap__entry",
  scroller: ".acpmux-minimap__list",
  // tickOverscan: a quarter of the rail's view (48 rows of 10 px here), at least 12; the window's
  // ends snap to steps of half that, 6 rows, which can draw 5 more past an edge.
  overscan: { rows: 17 },
  item: (index) => [
    row(`user-${index}`, "user", `Question ${index}`),
    row(`answer-${index}`, "assistant", `Answer ${index}.`),
    row(`end-${index}`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
  ],
  // The person edits a prompt's text: a new user row, the reply and end the same.
  change: ([user, ...rest]) => [{ ...user!, text: `${user!.text} (edited)`, version: user!.version + 1 }, ...rest],
  render: function Render({ items }) {
    const rows = useMemo(() => turnView(items.flat(), folded), [items]);
    // A chat opens at its end; the contract picks the row to change by its place among the mounted
    // rows, counted from the first prompt, so the chat is read from its top. Two frames: the
    // transcript pins itself to its end after it first lays out.
    useEffect(() => {
      requestAnimationFrame(() =>
        requestAnimationFrame(() => {
          document.querySelector(".acpmux-scroll")!.scrollTop = 0;
        }),
      );
    }, []);
    return <VirtualTranscript rows={rows} sessionId="list-contract" onToggleActivity={none} expanded={folded} />;
  },
  skip: {
    select: "a tick jumps the transcript to its prompt; the rail has no selection of its own",
  },
});
