// l10n-allow-file: gallery captions and the static stand-in for RFD 0078's rows, not shipped copy.
//
// RFD 0080: the open popover. The top block is a static stand-in for RFD 0078's rows (Hybrid / Only in
// Cloud / Only on This Mac, Keep running, the hours line); under the rule are this RFD's rows, drawn
// by the shipped AutoComputerRows.
import type { ReactNode } from "react";
import { componentEntry } from "../../../gallery/format";
import { AutoComputerRows } from "./AutoComputerRows";
import { STATES, type StateName } from "./AutoComputer.fixtures";

type Props = { state: StateName };

const noop = () => undefined;
const time = (ms: number) => new Date(ms).toISOString().slice(11, 16);

function Popover({ state, children }: { state: StateName; children?: ReactNode }) {
  return (
    <div className="auto-computer-board">
      <div className="auto-computer-popover">
        <div className="auto-computer-popover-title">Computer for “fix-login-redirect”</div>
        <div className="auto-computer-popover-modes">
          <span data-on={state === "local" ? undefined : "true"}>Hybrid</span>
          <span>Only in Cloud</span>
          <span data-on={state === "local" ? "true" : undefined}>Only on This Mac</span>
        </div>
        <div className="auto-computer-popover-line">Keep running ○</div>
        <div className="auto-computer-popover-line">41 of 100 hours used this week</div>
        <hr />
        <AutoComputerRows
          status={STATES[state]}
          formatTime={time}
          onAutoSize={noop}
          onPinSize={noop}
          onSleep={noop}
          onOpenTerminal={noop}
          onOpenDetails={noop}
        />
        {children}
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.auto-computer-popover",
  title: "AUTO computer: popover rows",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/auto/AutoComputerRows.tsx#AutoComputerRows"],
  styles: () =>
    Promise.all([
      import("../../../ui/ghost.css"),
      import("../styles.css"),
      import("./computerAuto.css"),
      import("./AutoComputer.gallery.css"),
    ]),
  load: async () => Popover,
  widths: { normal: 420 },
  height: 360,
  anchors: [{ selector: ".auto-computer-popover" }],
  variants: {
    "cloud-auto": {
      note: "In Cloud, Auto size and sleep: the size appears because there is a cloud computer; Why is one sentence.",
      props: { state: "cloudAwake" },
    },
    pinned: {
      note: "Size pinned and Keep awake 4 h: a pin mark on each pinned row; the button itself is unchanged.",
      props: { state: "sizePinned" },
    },
    "on-this-mac": {
      note: "Only on This Mac: no size yet, because there is no cloud computer.",
      props: { state: "local" },
    },
    "slots-full": {
      note: "Slots full: the Why row explains it.",
      props: { state: "slotsFull" },
    },
  },
});
