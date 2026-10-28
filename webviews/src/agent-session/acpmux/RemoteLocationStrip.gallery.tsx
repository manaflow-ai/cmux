// l10n-allow-file: gallery fixture labels and prototype descriptions.
import { componentEntry } from "../../gallery/format";
import { EnvironmentPicker } from "./EnvironmentPicker";
import { RemoteLocationFace, RemoteLocationStrip } from "./RemoteLocationStrip";
import type { Environment } from "./environments";

const machine: Environment = {
  id: "studio-mac",
  label: "studio-mac",
  kind: "ssh",
  connected: true,
  state: "connected",
};
type Presentation = "labelled" | "compact" | "separated";
function Specimen({ presentation }: { presentation: Presentation }) {
  return (
    <div className="acpmux-composer-strip">
      <div className="acpmux-composer-context">
        <RemoteLocationStrip machine={machine}>
          <EnvironmentPicker
            label="Environment"
            menu="Computer"
            value={machine.label}
            face={<RemoteLocationFace machine={machine} presentation={presentation} />}
            environments={[{ id: "local", label: "This Mac", kind: "local" }, machine]}
            current={machine.id}
            onPick={() => undefined}
          />
        </RemoteLocationStrip>
      </div>
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.remote-location-strip",
  title: "Remote location strip alternatives",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/RemoteLocationStrip.tsx#RemoteLocationStrip"],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: async () => Specimen,
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 180,
  variants: {
    separated: {
      note: "Recommended: Codex's Remote label, then a machine icon and name, with the real-state mark after the existing control.",
      props: { presentation: "separated" as const },
    },
    labelled: {
      note: "A denser Remote label followed immediately by the machine name.",
      props: { presentation: "labelled" as const },
    },
    compact: {
      note: "The smallest candidate: globe and machine name, omitting the explicit Remote label.",
      props: { presentation: "compact" as const },
    },
  },
});
