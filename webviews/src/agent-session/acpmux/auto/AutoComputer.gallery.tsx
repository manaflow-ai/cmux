// l10n-allow-file: gallery captions, not shipped copy.
//
// RFD 0080 (AUTO-first agentic computers), build item 1: the status line beside RFD 0078's place
// button, in every state the RFD draws, and three places to put it (the open question [taste]):
// beside the button (the RFD's pick), a row above the composer, a compact chip. Every state is drawn
// by the shipped AutoStatusLine. The button here is a static stand-in for RFD 0078's.
import type { ReactNode } from "react";
import { componentEntry } from "../../../gallery/format";
import { AutoStatusLine, type StatusLineLook } from "./AutoStatusLine";
import { NOW, STATES, type StateName } from "./AutoComputer.fixtures";

type Props = { layout: StatusLineLook | "states" };

const noop = () => undefined;

function Cell({ caption, children }: { caption: string; children: ReactNode }) {
  return (
    <figure className="auto-computer-cell">
      <figcaption>{caption}</figcaption>
      {children}
    </figure>
  );
}

function PlaceButton({ label }: { label: string }) {
  return (
    <button type="button" className="auto-computer-place">
      {label} <span aria-hidden="true">▾</span>
    </button>
  );
}

const BUTTON: Record<StateName, string> = {
  local: "Only on This Mac",
  cloudAwake: "Hybrid",
  sleeping: "Hybrid",
  preparing: "Hybrid",
  moving: "Hybrid",
  moveFailed: "Hybrid",
  pausedAtLimit: "Hybrid",
  sizePinned: "Hybrid",
  slotsFull: "Hybrid",
  reconnecting: "Hybrid",
};

function Line({ name, look }: { name: StateName; look: StatusLineLook }) {
  return <AutoStatusLine status={STATES[name]} nowMs={NOW} look={look} onAction={noop} />;
}

/// The composer foot with the button and the line beside it (the RFD's pick).
function Beside({ name }: { name: StateName }) {
  return (
    <div className="auto-computer-composer">
      <span className="auto-computer-composer-text">Message the agent</span>
      <Line name={name} look="beside" />
      <PlaceButton label={BUTTON[name]} />
    </div>
  );
}

function Row({ name }: { name: StateName }) {
  return (
    <>
      <Line name={name} look="row" />
      <div className="auto-computer-composer">
        <span className="auto-computer-composer-text">Message the agent</span>
        <PlaceButton label={BUTTON[name]} />
      </div>
    </>
  );
}

function Chip({ name }: { name: StateName }) {
  return (
    <div className="auto-computer-composer">
      <span className="auto-computer-composer-text">Message the agent</span>
      <Line name={name} look="chip" />
      <PlaceButton label={BUTTON[name]} />
    </div>
  );
}

const CAPTIONS: Record<StateName, string> = {
  local: "Running on This Mac (empty line)",
  cloudAwake: "Running in Cloud, awake (empty line)",
  sleeping: "Cloud, sleeping",
  preparing: "Preparing a cloud computer",
  moving: "Moving to Cloud, cancellable",
  moveFailed: "Move failed, stayed on This Mac",
  pausedAtLimit: "Paused at the overage limit",
  sizePinned: "Size pinned (the line is empty; the pin lives in the popover)",
  slotsFull: "Staying on This Mac, every slot busy",
  reconnecting: "Reconnecting to Cloud",
};

const LAYOUT: Record<StatusLineLook, (props: { name: StateName }) => ReactNode> = {
  beside: Beside,
  row: Row,
  chip: Chip,
};

function Board({ layout }: Props) {
  const names = Object.keys(STATES) as StateName[];
  const look: StatusLineLook = layout === "states" ? "beside" : layout;
  const Draw = LAYOUT[look];
  const shown =
    layout === "states" ? names : (["preparing", "moving", "moveFailed", "pausedAtLimit", "slotsFull"] as StateName[]);
  return (
    <div className="auto-computer-board" data-layout={layout}>
      {shown.map((name) => (
        <Cell key={name} caption={CAPTIONS[name]}>
          <Draw name={name} />
        </Cell>
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.auto-computer-status",
  title: "AUTO computer: status line",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/auto/AutoStatusLine.tsx#AutoStatusLine",
    "agent-session/acpmux/auto/computerStatus.ts#statusLine",
  ],
  styles: () =>
    Promise.all([
      import("../../../ui/ghost.css"),
      import("../styles.css"),
      import("./computerAuto.css"),
      import("./AutoComputer.gallery.css"),
    ]),
  load: async () => Board,
  widths: { normal: 560, wide: 720 },
  height: 620,
  anchors: [{ selector: ".auto-computer-board" }],
  variants: {
    states: {
      note: "Every state of the status line beside RFD 0078's button: empty while the chat runs (local, Cloud awake, pinned), then preparing, moving with Cancel, move failed with Retry, sleeping, paused at the limit, slots full, reconnecting.",
      props: { layout: "states" },
    },
    beside: {
      note: "Layout 1, the RFD's pick: the line beside the button, in the composer foot. It takes no room while empty, and the button never shows a size.",
      props: { layout: "beside" },
    },
    row: {
      note: "Layout 2: a quiet row above the composer, as the Cloud hint is. Moves the composer down by one row while something is happening.",
      props: { layout: "row" },
    },
    chip: {
      note: "Layout 3: a compact chip with the headline only (the rest on hover). Smallest, but it hides the reason and the seconds.",
      props: { layout: "chip" },
    },
  },
});
