// l10n-allow-file: gallery captions, not shipped copy.
//
// The Where menu opened, as a still capture shows it: the main list (This Mac, AutoCloud, Cloud, Other
// devices), Other devices with Agent machines last, the agent machines' side list, and a busy machine
// whose High load warning is a status on its own row. Leo, 2026-11-27: "just bring it back to this mac
// / autocloud / cloud / remote or whatever it was before". The board opens the shipped picker itself on
// mount (the capture takes no clicks).
import { useEffect, useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { AutoIcon } from "./AutoWhere";
import { EnvironmentPicker } from "./EnvironmentPicker";
import { LocationFace } from "./ComposerContext";
import type { RunMode } from "./sandboxRun";

type Open = "main" | "devices" | "agents";
type Props = { open: Open; busy?: boolean };

const environments = (busy: boolean) => [
  { id: "local", label: "This Mac", kind: "local" as const, connected: true },
  {
    id: "studio",
    label: "studio",
    kind: "ssh" as const,
    connected: true,
    ...(busy ? { loadWarning: "High load: 4/4 cores busy" } : {}),
  },
  { id: "gpu-box", label: "gpu-box", kind: "ssh" as const, connected: true },
  { id: "lane-1", label: "lane-1", kind: "ssh" as const, connected: true, group: "agent" as const },
  { id: "lane-2", label: "lane-2", kind: "ssh" as const, connected: true, group: "agent" as const },
];

const click = (selector: string) =>
  document.querySelector<HTMLElement>(selector)?.closest<HTMLElement>('[role="option"], button')?.click();

function Board({ open, busy = false }: Props) {
  const [mode, setMode] = useState<RunMode>("persistent");
  const [auto, setAuto] = useState(true);
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const steps = [
      () => root.current?.querySelector<HTMLButtonElement>(".acpmux-location-button")?.click(),
      ...(open === "main" ? [] : [() => click('.acpmux-env-popover [data-action="otherDevices"]')]),
      ...(open === "agents" ? [() => click('.acpmux-env-popover [data-action="agentMachines"]')] : []),
    ];
    const timers = steps.map((step, index) => window.setTimeout(step, 60 + index * 120));
    return () => timers.forEach((timer) => window.clearTimeout(timer));
  }, [open]);
  const name = auto ? "AutoCloud" : "This Mac";
  return (
    <div ref={root} className="nt-composer where-menu-board" style={{ paddingTop: "22.5rem" }}>
      <EnvironmentPicker
        label="Environment"
        menu={`WhereMenu-${open}-${String(busy)}`}
        value={name}
        face={<LocationFace icon={<AutoIcon look="split" />} value={name} chevron />}
        rows="where"
        environments={environments(busy)}
        current="local"
        onPick={() => setMode("persistent")}
        digits={false}
        setupMenu={false}
        otherDevices
        runMode={{
          mode,
          onMode: setMode,
          sandbox: false,
          auto: { picked: auto, onPick: setAuto, look: "split", cloud: true },
        }}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.where-menu",
  title: "Where menu: This Mac, AutoCloud, Cloud, Other devices",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/EnvironmentPicker.tsx#EnvironmentPicker"],
  styles: () =>
    Promise.all([
      import("../../ui/ghost.css"),
      import("./styles.css"),
      import("./composerLocation.css"),
      import("./autoWhere.css"),
    ]),
  load: async () => Board,
  widths: { normal: 560, wide: 720 },
  height: 480,
  variants: {
    main: {
      note: "The main list: This Mac, AutoCloud (its chevron opens Auto, Cloud only, Machine…), Cloud, Other devices. No Hybrid start or Sandboxed rows.",
      props: { open: "main" },
    },
    devices: {
      note: "Other devices: the person's own machines, then Agent machines and Add machine.",
      props: { open: "devices" },
    },
    agents: {
      note: "Agent machines opens its searchable list to the side; the main list stays open.",
      props: { open: "agents" },
    },
    "high-load": {
      note: "A busy machine: High load is a status on studio's row, and the name keeps its width.",
      props: { open: "devices", busy: true },
    },
  },
});
