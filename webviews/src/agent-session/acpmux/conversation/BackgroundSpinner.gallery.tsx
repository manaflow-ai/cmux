// l10n-allow-file: gallery fixture (sample task words), not shipped UI.
// The working mark on a background turn's line, beside the rows it sits with. Leo, 2026-11-21: "this
// spinner is incredibly ugly" (an open arc that read as the letter C, heavier than the clock and
// terminal marks beside it). `before` is that arc; `track` (the pick, only on the background line; `Spinner`'s default stays the arc) a
// three-quarter ring with rounded caps on a faint track at the rows' stroke weight; `dots` three
// pulsing dots. `finished` is the real line for a finished task whose turn is still running: the
// clock, never a spinner.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { Clock, Spinner, TerminalSquare, type SpinnerLook } from "./icons";
import { TranscriptActivityRow } from "./TranscriptActivityRow";

type Props = { look: SpinnerLook | "finished" | "app-wide"; zoom?: number };

const WORDS = "Background task finished: start notice-flood-fix lane; cancel 49 superseded runs";

const finishedRow = {
  id: backgroundTurnRowId("spin"),
  kind: BACKGROUND_TURN,
  at: 8,
  background: {
    id: "spin",
    trigger: "task_notification",
    running: true,
    cause: { kind: "shell", status: "completed", weight: "result" },
  },
} as unknown as AcpmuxRow;

function GallerySpinner({ look, zoom = 1 }: Props) {
  if (look === "app-wide")
    return (
      <div style={{ padding: 16, display: "grid", gap: 12, zoom }}>
        {(["arc", "track"] as const).map((each) => (
          <div key={each} style={{ display: "flex", gap: 16, alignItems: "center" }}>
            <span style={{ width: 90 }}>{each === "arc" ? "arc (today)" : "ring on track"}</span>
            {[12, 14, 16, 20].map((size) => (
              <Spinner key={size} look={each} size={size} loading />
            ))}
          </div>
        ))}
      </div>
    );
  return (
    <div style={{ padding: 16, zoom }}>
      <TranscriptActivityRow icon={<Clock />} before="Waiting 14m · hold" chevron={false} />
      {look === "finished" ? (
        <BackgroundTurnLine row={finishedRow} expanded={false} onToggle={() => {}} />
      ) : (
        <TranscriptActivityRow icon={<Spinner look={look} />} before={WORDS} chevron={false} />
      )}
      <TranscriptActivityRow icon={<TerminalSquare />} before="Ran 4 commands" />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.background-spinner",
  title: "Background turn spinner",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/icons.tsx#Spinner",
    "agent-session/acpmux/conversation/BackgroundTurnLine.tsx",
  ],
  load: async () => GallerySpinner,
  height: 200,
  variants: {
    before: {
      note: "Before: the open arc, 300 degrees, 1.5 stroke; still, it reads as the letter C.",
      props: { look: "arc" },
    },
    track: {
      note: "The pick: three-quarter ring, rounded caps, on a faint full track; the background line opts in.",
      props: { look: "track" },
    },
    dots: { note: "Three pulsing dots (held at one tone under Reduce Motion).", props: { look: "dots" } },
    finished: {
      note: "A finished task whose turn is still answering: the clock, words shimmering, no spinner.",
      props: { look: "finished" },
    },
    "app-wide": {
      note: "Option for later: the ring as every spinner's look (loading marks at 12, 14, 16 and 20 px), today's arc above it. Not shipped: only the background line opts in.",
      props: { look: "app-wide" },
    },
    "track-4x": { note: "The pick at 4x.", props: { look: "track", zoom: 4 } },
    "before-4x": { note: "Before at 4x.", props: { look: "arc", zoom: 4 } },
  },
});
