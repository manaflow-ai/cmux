// l10n-allow-file: gallery captions and the static stand-in for RFD 0078's rows, not shipped copy.
//
// RFD 0144 piece 9: the popover with the read-only Size row and More room, in three looks (inline,
// stacked, pill), each offered and on, plus the rows with no button (on this Mac, pinned from the
// CLI, at the plan's top step). Off by default: the shipped popover draws this row only when the
// Rust core answers a view (`cloud_size_row`, setting `cloud.moreRoom`).
import { componentEntry } from "../../../gallery/format";
import { AutoComputerRows } from "./AutoComputerRows";
import { STATES, type StateName } from "./AutoComputer.fixtures";
import type { SizeRowLook } from "./ReadOnlySizeRow";
import type { SizeRowView } from "./sizeRowView";

const NOW = { vcpu: 2, memory_gib: 4 };
const VIEWS = {
  offered: { now: NOW, more_room: "offered", raises_to: { vcpu: 8, memory_gib: 32 } },
  on: { now: { vcpu: 8, memory_gib: 32 }, more_room: "on" },
  atTop: { now: { vcpu: 32, memory_gib: 64 }, more_room: "hidden" },
  local: { more_room: "hidden" },
  pinned: { now: { vcpu: 8, memory_gib: 16 }, pinned: { vcpu: 8, memory_gib: 16 }, more_room: "hidden" },
} satisfies Record<string, SizeRowView>;

type Props = { state: StateName; view: keyof typeof VIEWS; look: SizeRowLook };

const noop = () => undefined;
const time = (ms: number) => new Date(ms).toISOString().slice(11, 16);

function Popover({ state, view, look }: Props) {
  return (
    <div className="auto-computer-board">
      <div className="auto-computer-popover">
        <div className="auto-computer-popover-title">Computer for “fix-login-redirect”</div>
        <div className="auto-computer-popover-modes">
          <span data-on={state === "local" ? undefined : "true"}>Hybrid</span>
          <span>Only in Cloud</span>
          <span data-on={state === "local" ? "true" : undefined}>Only on This Mac</span>
        </div>
        <hr />
        <AutoComputerRows
          status={STATES[state]}
          formatTime={time}
          onAutoSize={noop}
          onPinSize={noop}
          onSleep={noop}
          onOpenTerminal={noop}
          onOpenDetails={noop}
          sizeView={VIEWS[view]}
          sizeLook={look}
          onMoreRoom={noop}
        />
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.more-room",
  title: "AUTO computer: read-only Size row and More room",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/auto/ReadOnlySizeRow.tsx#ReadOnlySizeRow"],
  styles: () =>
    Promise.all([
      import("../../../ui/ghost.css"),
      import("../styles.css"),
      import("./computerAuto.css"),
      import("./AutoComputer.gallery.css"),
    ]),
  load: async () => Popover,
  widths: { narrow: 320, normal: 420 },
  height: 300,
  anchors: [{ selector: ".auto-computer-popover" }],
  variants: {
    "inline-offered": {
      note: "A: the size sentence, then More room beside it. No Auto, no Pin.",
      props: { state: "cloudAwake", view: "offered", look: "inline" },
    },
    "stacked-offered": {
      note: "B: More room on its own line under the size sentence.",
      props: { state: "cloudAwake", view: "offered", look: "stacked" },
    },
    "pill-offered": {
      note: "C: More room as a small pill after the sentence.",
      props: { state: "cloudAwake", view: "offered", look: "pill" },
    },
    "inline-on": {
      note: "A, after asking: “More room: on” for the rest of the task; no size named.",
      props: { state: "cloudAwake", view: "on", look: "inline" },
    },
    "stacked-on": { props: { state: "cloudAwake", view: "on", look: "stacked" } },
    "pill-on": { props: { state: "cloudAwake", view: "on", look: "pill" } },
    "at-top-step": {
      note: "At the plan's top step: the size reads, no button.",
      props: { state: "cloudAwake", view: "atTop", look: "inline" },
    },
    "pinned-from-cli": {
      note: "Pinned from the CLI or API: the pin reads as is, no button and no Pin choice.",
      props: { state: "sizePinned", view: "pinned", look: "inline" },
    },
    "on-this-mac": {
      note: "No cloud computer: the row has no size and no button.",
      props: { state: "local", view: "local", look: "inline" },
    },
  },
});
