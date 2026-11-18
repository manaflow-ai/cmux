// l10n-allow-file: gallery fixtures (machine names and readings), not shipped UI.
//
// The machine card of a started chat on a Cloud machine (MachineCard.tsx): the location chip's
// popover opens on it. The chip carries the machine's dot; the card names the machine and its size,
// says Awake, Asleep, Waking or Failed, shows the last load and memory reading while awake (acpmux's
// cached one-minute health of the machine; no disk reading reaches the page, so there is no Disk
// row), offers Wake machine while asleep, and lists where the chat can go under Continue on, a
// machine that is down greyed with why.
//
// References: claude/live/usage-status-popover and claude/live/sidebar-usage-limits-card (labelled
// rows, the value at the end, a thin bar under each: this pane's PlanUsageCard rows reused),
// cursor/web/local-cloud-handoff-control (the chip's own menu is where the chat goes next),
// chatgpt/live/sidebar-machine-details-hover-card (the machine and its status dot at the top),
// claude/live/sidebar-project-groups-status-dots (a dot; words only where there is something to read).
import { useLayoutEffect } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ComposerContext } from "./ComposerContext";
import { setCloudMachinesForTest, setCloudMachinesForTestAccount } from "./cloudMachines";
import type { MachineResources } from "./machineResources";
import type { MoveTarget } from "./EnvironmentPicker";

type StageProps = {
  /// The account's record of the machine: its stage, or none (`undefined`).
  stage?: string;
  /// acpmux's link to the machine is up.
  connected: boolean;
  resources?: MachineResources;
  /// The record says its size.
  sized?: boolean;
  /// Where the chat can go; a machine with a `reason` is down.
  targets?: readonly MoveTarget[];
};

const SIZE = { cpu: 4, memoryMb: 16384, diskMb: 65536 };
const READING: MachineResources = {
  ramFreeGB: 10.3,
  load1: 1.2,
  coresBusy: 1,
  cores: 4,
  busy: false,
  lowMemory: false,
};
const TARGETS: readonly MoveTarget[] = [
  { id: "local", label: "", kind: "local" },
  { id: "vm-2", label: "gpu-box", kind: "cloud" },
];

function Stage({ stage, connected, resources, sized = true, targets = TARGETS }: StageProps) {
  // The account's list as the app would answer it, set before the strip paints.
  useLayoutEffect(() => {
    setCloudMachinesForTestAccount(true);
    setCloudMachinesForTest(stage ? [{ id: "vm-1", name: "atlas-box", stage, ...(sized ? { size: SIZE } : {}) }] : []);
  }, [stage, sized]);
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        justifyContent: "flex-end",
        height: "100%",
        boxSizing: "border-box",
        padding: "0 12px 12px",
      }}
    >
      <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
        <ComposerContext
          environments
          started
          stripLayout="combined"
          summary={
            {
              sessionId: "s",
              harness: "claude",
              host: "atlas-box",
              peer: "atlas-box",
              hostKind: "cloud",
              cwd: "/home/you/atlas-web",
            } as never
          }
          peers={["atlas-box"]}
          peerKinds={{ "atlas-box": "cloud" }}
          peerConnected={{ "atlas-box": connected }}
          peerStates={{ "atlas-box": connected ? "connected" : "offline" }}
          {...(resources ? { peerResources: { "atlas-box": resources } } : {})}
          localName="studio-mac"
          offloads={["bringBack"]}
          onOffload={() => undefined}
          moveTargets={targets}
          onMoveTo={() => undefined}
        />
        <div className="acpmux-composer-box" data-gallery-box="">
          <textarea aria-label="Prompt" placeholder="Ask anything" rows={3} />
        </div>
      </form>
    </div>
  );
}

/// Opens the chip's popover on the machine card.
const openCard: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-picker[data-machine-card] button"));
  await ctx.click({ selector: ".acpmux-location-picker[data-machine-card] button" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-env-popover .acpmux-machine-card"));
};

const awake = { stage: "ready", connected: true, resources: READING } as const;

export default componentEntry<StageProps>({
  id: "agent-pane.machine-card",
  title: "Cloud machine card",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/MachineCard.tsx#MachineCard"],
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./composerLocation.css"),
      import("./planUsageCard.css"),
      import("./machineCard.css"),
    ]),
  load: async () => Stage,
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 460,
  anchors: [{ selector: ".acpmux-composer-context" }],
  variants: {
    chip: {
      note: "Closed: the Cloud chip with its machine's green dot.",
      props: awake,
    },
    awake: {
      note: "Awake: name, size, Awake; load against cores and free memory of its size, each with a bar; Continue on.",
      props: awake,
      play: openCard,
    },
    "busy-low-memory": {
      note: "Awake under load: a load past the cores fills the bar; little memory left.",
      props: {
        ...awake,
        resources: { ...READING, load1: 6.8, coresBusy: 7, ramFreeGB: 0.9, busy: true, lowMemory: true },
      },
      play: openCard,
    },
    "no-usage": {
      note: "Awake, no reading from the machine yet: one line says so, never a zero.",
      props: { stage: "ready", connected: true },
      play: openCard,
    },
    "no-size": {
      note: "No account record (only acpmux's link): no size line, free memory alone with no bar.",
      props: { connected: true, resources: READING },
      play: openCard,
    },
    "asleep-chip": {
      note: "Closed, asleep: the chip's dot is grey.",
      props: { stage: "paused", connected: false, resources: READING },
    },
    asleep: {
      note: "Asleep: grey dot, no usage, Wake machine (the app's Resume), Continue on below.",
      props: { stage: "paused", connected: false, resources: READING },
      play: openCard,
    },
    waking: {
      note: "Waking: the spinner in the dot's place; no usage and no Wake machine until it is up.",
      props: { stage: "booting", connected: false },
      play: openCard,
    },
    failed: {
      note: "Failed to start: a red dot and Failed; Continue on still offers this Mac.",
      props: { stage: "failed", connected: false },
      play: openCard,
    },
    "device-offline": {
      note: "Continue on with a machine that is down: greyed, with why under its name.",
      props: {
        ...awake,
        targets: [
          { id: "local", label: "", kind: "local" },
          { id: "vm-3", label: "laptop-box", kind: "cloud", reason: "Device offline" },
        ],
      },
      play: openCard,
    },
  },
});
