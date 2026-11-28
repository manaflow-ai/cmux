// l10n-allow-file: gallery captions, not shipped copy.
//
// AutoCloud's place picker (autoCloud.ts), drawn by the shipped EnvironmentPicker. Leo, 2026-11-24:
// "let's just use our existing dropdown and have it be able to have a chevron that opens into more
// options". With the hidden cloud.autoCloud key on and an active plan, the Where menu's Auto row is a
// chevron that opens Auto ⌥⌘1, Cloud only ⌥⌘2 and Machine… ⌥⌘3; with it off, the menu is unchanged.
import { useEffect, useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { declareMove } from "../../layout/motionContract";
import { AutoIcon } from "./AutoWhere";
import { EnvironmentIcon, EnvironmentPicker } from "./EnvironmentPicker";
import { LocationFace } from "./ComposerContext";
import type { RunMode } from "./sandboxRun";

/// closed: the chip; menu: the main list open; places: the Auto list open.
type Props = { open: "closed" | "menu" | "places"; picked: boolean; gate: boolean };

const ENVIRONMENTS = [
  { id: "local", label: "This Mac", kind: "local" as const, connected: true },
  { id: "build-box", label: "build box", kind: "ssh" as const, connected: true },
];

function Picker({ open, picked, gate }: Props) {
  const [auto, setAuto] = useState(picked);
  const [mode, setMode] = useState<RunMode>("persistent");
  const box = useRef<HTMLDivElement>(null);
  // Opens the list (and the Auto list) as a click would, so the still shows what the person sees.
  // gallery-capture: the timers open the list as a click would, within a few hundred ms of mount, before the stage's quiet-DOM ready mark; the still is of the open list.
  useEffect(() => {
    if (open === "closed") return;
    const timers: number[] = [];
    timers.push(
      window.setTimeout(() => {
        declareMove({ event: "menu", scope: "all", by: "gallery press" }, { ms: 500 });
        box.current?.querySelector<HTMLButtonElement>(".acpmux-location-button")?.click();
        if (open !== "places") return;
        timers.push(
          window.setTimeout(() => {
            const row = document.querySelector<HTMLElement>('.acpmux-env-popover [data-action="autoPlaces"]');
            // A person's press declares the menu's change (layout/motionAudit.ts onPress); this click
            // stands in for that press, so it declares the same: the open list re-lays out in place.
            declareMove({ event: "menu", scope: "all", by: "gallery press" }, { ms: 500 });
            (row?.closest<HTMLElement>('[role="option"]') ?? row)?.click();
          }, 60),
        );
      }, 60),
    );
    return () => timers.forEach((timer) => window.clearTimeout(timer));
  }, [open]);
  const name = auto ? "Auto" : mode === "cloud" ? "Cloud" : "This Mac";
  const icon = auto ? <AutoIcon look="orbit" /> : <EnvironmentIcon kind={mode === "cloud" ? "cloud" : "local"} />;
  return (
    <div ref={box} className="nt-composer auto-where-chip">
      <EnvironmentPicker
        label="Environment"
        menu={`Computer-autocloud-${open}-${String(picked)}-${String(gate)}`}
        value={name}
        face={<LocationFace icon={icon} value={name} chevron />}
        rows="where"
        environments={ENVIRONMENTS}
        current="local"
        onPick={() => setMode("persistent")}
        digits={false}
        setupMenu={false}
        runMode={{
          mode,
          onMode: setMode,
          sandbox: false,
          auto: { picked: auto, onPick: setAuto, look: "orbit", ...(gate ? { cloud: true } : {}) },
        }}
      />
    </div>
  );
}

function Board(props: Props) {
  return (
    <div className="auto-where-board">
      <Picker {...props} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.auto-cloud-picker",
  title: "AutoCloud: Auto, Cloud only, Machine…",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/EnvironmentPicker.tsx#EnvironmentPicker", "agent-session/acpmux/autoCloud.ts"],
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
  height: 320,
  anchors: [{ selector: ".auto-where-board" }],
  variants: {
    closed: {
      note: "The Where chip closed, This Mac picked.",
      props: { open: "closed", picked: false, gate: true },
    },
    chevron: {
      note: "Ships behind cloud.autoCloud and an active plan: the menu open, Auto's row carries a chevron.",
      props: { open: "menu", picked: false, gate: true },
    },
    places: {
      note: "The chevron opened in place: Auto ⌥⌘1 (this Mac when it has room, else a Cloud VM), Cloud only ⌥⌘2, Machine… ⌥⌘3.",
      props: { open: "places", picked: false, gate: true },
    },
    picked: {
      note: "Auto picked: the chip reads Auto, and the Auto list checks it.",
      props: { open: "places", picked: true, gate: true },
    },
    "gated-off": {
      note: "Key off or no active plan: the menu as it shipped, Auto one plain row with no chevron.",
      props: { open: "menu", picked: false, gate: false },
    },
  },
});
