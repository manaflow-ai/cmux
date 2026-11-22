// l10n-allow-file: gallery captions, not shipped copy.
//
// Auto as where a new chat runs (autoWhereModel.ts), in each look, every state drawn by the shipped
// components: the Where chip (EnvironmentPicker with Auto picked, and with This Mac picked), its menu
// (open it: Auto heads the list), and the arrival line (AutoArrival) while deciding, after it kept the
// chat here, after it put it on Cloud, and when no Cloud machine was there to take it. Leo, 2026-11-22:
// "MAKE IT FUCKING LOOK SPECIAL. BUT CONSSITENT TEXT-WISE." The words are the same in every look; the
// look is the icon, its colour and a little motion, which holds still under reduced motion.
import { useState, type ReactNode } from "react";
import { componentEntry } from "../../gallery/format";
import { AutoArrival, AutoIcon } from "./AutoWhere";
import { EnvironmentIcon, EnvironmentPicker } from "./EnvironmentPicker";
import { LocationFace } from "./ComposerContext";
import type { AutoLanding, AutoLook } from "./autoWhereModel";
import type { RunMode } from "./sandboxRun";

type Props = { look: AutoLook };

const ENVIRONMENTS = [
  { id: "local", label: "This Mac", kind: "local" as const, connected: true },
  { id: "build-box", label: "build box", kind: "ssh" as const, connected: true },
];

/// The daemon's answers (server/place.rs) as the arrival line reads them.
const WENT_HERE: AutoLanding = { went: "here", code: "within_budget", why: "this machine has room (Normal)" };
const WENT_CLOUD: AutoLanding = {
  went: "cloud",
  code: "over_budget",
  why: "this machine is over budget (Warning: cpu 92%)",
};
const NO_CLOUD: AutoLanding = {
  went: "here",
  code: "no_room",
  why: "this machine is over budget (Warning: cpu 92%) and no other machine is available",
};

/// The Where chip, live: picking rows changes it as the composer would.
function Chip({ look, autoFirst }: { look: AutoLook; autoFirst: boolean }) {
  const [auto, setAuto] = useState(autoFirst);
  const [mode, setMode] = useState<RunMode>("persistent");
  const name = auto ? "Auto" : mode === "cloud" ? "Cloud" : "This Mac";
  const icon = auto ? <AutoIcon look={look} /> : <EnvironmentIcon kind={mode === "cloud" ? "cloud" : "local"} />;
  return (
    <div className="nt-composer auto-where-chip">
      <EnvironmentPicker
        label="Environment"
        menu={`Computer-${look}-${String(autoFirst)}`}
        value={name}
        face={<LocationFace icon={icon} value={name} chevron />}
        rows="where"
        environments={ENVIRONMENTS}
        current="local"
        onPick={() => setMode("persistent")}
        digits={false}
        setupMenu={false}
        runMode={{ mode, onMode: setMode, sandbox: false, auto: { picked: auto, onPick: setAuto, look } }}
      />
    </div>
  );
}

function Cell({ caption, children }: { caption: string; children: ReactNode }) {
  return (
    <figure className="auto-where-cell">
      <figcaption>{caption}</figcaption>
      <div className="auto-where-cell-body">{children}</div>
    </figure>
  );
}

/// One look: the chip (idle: Auto picked, before Send; and This Mac picked), then each arrival.
function Board({ look }: Props) {
  const noMove = () => undefined;
  return (
    <div className="auto-where-board" data-look={look}>
      <div className="auto-where-chips">
        <Cell caption="Idle · Auto picked">
          <Chip look={look} autoFirst />
        </Cell>
        <Cell caption="This Mac picked (menu offers Auto)">
          <Chip look={look} autoFirst={false} />
        </Cell>
      </div>
      <Cell caption="Deciding">
        <AutoArrival landing="deciding" look={look} />
      </Cell>
      <Cell caption="Went here">
        <AutoArrival landing={WENT_HERE} look={look} onMove={noMove} onDismiss={noMove} />
      </Cell>
      <Cell caption="Went to Cloud">
        <AutoArrival landing={WENT_CLOUD} look={look} onMove={noMove} onDismiss={noMove} />
      </Cell>
      <Cell caption="No Cloud machine">
        <AutoArrival landing={NO_CLOUD} look={look} onDismiss={noMove} />
      </Cell>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.auto-where",
  title: "Auto: where a new chat runs",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/AutoWhere.tsx#AutoIcon",
    "agent-session/acpmux/AutoWhere.tsx#AutoArrival",
    "agent-session/acpmux/EnvironmentPicker.tsx#EnvironmentPicker",
  ],
  styles: () =>
    Promise.all([
      import("../../ui/ghost.css"),
      import("./styles.css"),
      import("./composerLocation.css"),
      import("./autoWhere.css"),
      import("./AutoWhere.gallery.css"),
    ]),
  load: async () => Board,
  widths: { normal: 560, wide: 720 },
  height: 380,
  anchors: [{ selector: ".auto-where-board" }],
  variants: {
    orbit: {
      note: "Ships. Orbit: your chat as a still centre and three machine-coloured dots going round it at every spinner's one period while Auto is picked, on hover and while deciding.",
      props: { look: "orbit" },
    },
    constellation: {
      note: "Constellation: a spark in the machines' colours; the small one breathes, the big one twinkles once on hover.",
      props: { look: "constellation" },
    },
    aurora: {
      note: "Aurora: there-and-back arrows in a cool gradient, a drifting wash under the menu row and a hairline under the chip.",
      props: { look: "aurora" },
    },
    plain: {
      note: "Baseline: Auto drawn as any other row, a plain glyph in the text colour.",
      props: { look: "plain" },
    },
  },
});
