// l10n-allow-file: gallery-only fixture data and controls.
import { useRef } from "react";
import { componentEntry } from "../../../gallery/format";
import { chat } from "../../../gallery/fixtures/acpmux";
import { EnvironmentSection } from "./EnvironmentSection";
import { SessionInfoPanel } from "./SessionInfo";

type Props = { failFirst: boolean };
function EnvironmentSave({ failFirst }: Props) {
  const attempts = useRef(0);
  return (
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <SessionInfoPanel width={280} placement="overlay">
        <EnvironmentSection
          summary={{ ...chat([]).summary!, cwd: "/Users/demo/Projects/atlas" }}
          machineName="Studio"
          onSave={() => {
            attempts.current++;
            if (failFirst && attempts.current === 1) return Promise.reject(new Error("Fixture host refused save"));
            return Promise.resolve();
          }}
        />
      </SessionInfoPanel>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.environment-save",
  title: "Environment save recovery",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 320, normal: 600 },
  covers: ["agent-session/acpmux/session-info/EnvironmentSection.tsx"],
  load: async () => EnvironmentSave,
  variants: {
    success: { note: "The host saves the environment.", props: { failFirst: false } },
    refused: { note: "First Save fails; the next succeeds.", props: { failFirst: true } },
  },
});
