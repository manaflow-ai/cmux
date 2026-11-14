// l10n-allow-file: synthetic machine and project fixtures for the design comparison.
import { componentEntry } from "../../../gallery/format";
import { EnvironmentSection } from "./EnvironmentSection";

function ScreenSharingEnvironment({ look = "row" }: { look?: "row" | "inline" | "icon" }) {
  return (
    <div className="acpmux-shell">
      <EnvironmentSection
        summary={{ sessionId: "screen-share-gallery", hostKind: "local", cwd: "/Projects/atlas" }}
        machineName="Studio Mac"
        screenSharingLook={look}
      />
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.session-info-screen-sharing",
  title: "Session Info screen sharing",
  area: "Agent pane",
  pane: true,
  height: 240,
  widths: { narrow: 280, normal: 360 },
  covers: ["agent-session/acpmux/session-info/EnvironmentSection.tsx"],
  load: async () => ScreenSharingEnvironment,
  variants: {
    row: { note: "Chosen: a direct text action below the machine, legible at narrow widths.", props: { look: "row" } },
    inline: {
      note: "Alternative: action alongside the machine name; competes with long host names.",
      props: { look: "inline" },
    },
    icon: {
      note: "Alternative: compact icon beside the machine; less discoverable than text.",
      props: { look: "icon" },
    },
  },
});
