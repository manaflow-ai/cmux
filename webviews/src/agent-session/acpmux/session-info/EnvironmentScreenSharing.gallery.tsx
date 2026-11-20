// l10n-allow-file: synthetic machine and project fixtures for the design comparison.
import { componentEntry } from "../../../gallery/format";
import { EnvironmentSection } from "./EnvironmentSection";
import { SessionInfoPanel } from "./SessionInfo";

type Look = "row" | "trailing" | "grouped";
type Props = { look: Look; machine: "local" | "cloud" | "ssh"; width?: number };

const SUMMARIES = {
  local: {
    sessionId: "screen-share-gallery",
    hostKind: "local",
    cwd: "/Users/demo/Projects/atlas",
    branch: "feat/live-view",
  },
  cloud: {
    sessionId: "screen-share-gallery",
    hostKind: "cloud",
    host: "maple-cloud",
    cwd: "/workspace/atlas",
    branch: "feat/live-view",
  },
  ssh: { sessionId: "screen-share-gallery", peer: "lane-vm", cwd: "/home/demo/atlas", branch: "feat/live-view" },
} as const;

function ScreenSharingEnvironment({ look, machine, width = 280 }: Props) {
  return (
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <SessionInfoPanel width={width} placement="overlay">
        <EnvironmentSection
          summary={SUMMARIES[machine]}
          machineName="Studio Mac"
          peerKinds={{ "lane-vm": "ssh" }}
          repository="demo/atlas"
          edits={{ additions: 42, deletions: 7 }}
          onOpenChanges={() => undefined}
          remoteControl={machine === "local" ? { on: false, set: () => undefined } : undefined}
          screenSharingLook={look}
        />
      </SessionInfoPanel>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.session-info-screen-sharing",
  title: "Session Info screen sharing",
  area: "Agent pane",
  pane: true,
  height: 300,
  widths: { narrow: 300, normal: 420 },
  covers: ["agent-session/acpmux/session-info/EnvironmentSection.tsx"],
  load: async () => ScreenSharingEnvironment,
  variants: {
    row: {
      note: "Chosen: Share screen… as its own row right under this Mac, on the icon and label columns of the rows around it; legible at narrow widths, and the machine row keeps only its kind word.",
      props: { look: "row", machine: "local" },
    },
    trailing: {
      note: "Alternative: a text link after the machine's kind word. Sits beside the machine as the references do, but at narrow widths it crowds a long machine name, and it reads as a second label rather than an action.",
      props: { look: "trailing", machine: "local" },
    },
    grouped: {
      note: "Alternative: its own row beside Remote Control, after the folder, branch and Changes. Groups the two 'reach this machine from elsewhere' rows, but moves the action away from the machine it acts on.",
      props: { look: "grouped", machine: "local" },
    },
    "row-cloud": {
      note: "Shipped look on a Cloud machine: View screen… opens its desktop.",
      props: { look: "row", machine: "cloud" },
    },
    "row-wide": { note: "Chosen look at a wide panel.", props: { look: "row", machine: "local", width: 380 } },
    "trailing-wide": {
      note: "Trailing alternative at a wide panel.",
      props: { look: "trailing", machine: "local", width: 380 },
    },
    "grouped-wide": {
      note: "Grouped alternative at a wide panel.",
      props: { look: "grouped", machine: "local", width: 380 },
    },
    "row-ssh": {
      note: "Shipped look on an SSH machine (a Linux box, or a Mac without an authenticated device mapping yet): no action, since native would refuse it.",
      props: { look: "row", machine: "ssh" },
    },
  },
});
