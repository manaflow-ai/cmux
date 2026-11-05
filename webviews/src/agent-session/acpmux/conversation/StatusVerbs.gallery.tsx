// l10n-allow-file: gallery fixtures for the live status line's sample verbs.
import { useMemo, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { Thinking } from "./Thinking";
import { resolveStatusVerbConfig, StatusVerbContext } from "../statusVerbs";

type Variant = "rotating" | "thinking-only" | "custom";

function Fixture({ variant }: { variant: Variant }) {
  const [mode, setMode] = useState(
    variant === "thinking-only" ? "thinking" : variant === "custom" ? "custom" : "rotate",
  );
  const [custom, setCustom] = useState("Planning, Reading, Testing");
  const [since] = useState(Date.now);
  const config = useMemo(
    () =>
      resolveStatusVerbConfig({
        "agentPane.display.statusVerbs.mode": mode,
        "agentPane.display.statusVerbs.custom": custom,
      }),
    [mode, custom],
  );
  return (
    <StatusVerbContext.Provider value={config}>
      <div style={{ padding: 24, maxWidth: 640 }}>
        <label style={{ display: "block", marginBottom: 12 }}>
          Working status{" "}
          <select aria-label="Working status" value={mode} onChange={(event) => setMode(event.target.value)}>
            <option value="rotate">Rotating verbs</option>
            <option value="thinking">Thinking only</option>
            <option value="custom">Custom verbs</option>
          </select>
        </label>
        {mode === "custom" && (
          <label style={{ display: "block", marginBottom: 12 }}>
            Custom verbs{" "}
            <input aria-label="Custom verbs" value={custom} onChange={(event) => setCustom(event.target.value)} />
          </label>
        )}
        <Thinking since={since} />
      </div>
    </StatusVerbContext.Provider>
  );
}

export default componentEntry<{ variant: Variant }>({
  id: "agent-pane.status-verbs",
  title: "Live status verbs",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 360, normal: 560, wide: 760 },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  covers: ["agent-session/acpmux/conversation/Thinking.tsx#Thinking"],
  variants: {
    rotating: {
      props: { variant: "rotating" },
      note: "An opt-in setting rotates the live line through cmux's own short -ing verbs while a turn works.",
    },
    "thinking-only": {
      props: { variant: "thinking-only" },
      note: "The setting can keep the traditional Thinking label for users who prefer one stable word.",
    },
    custom: {
      props: { variant: "custom" },
      note: "A custom list rotates at the same cadence and uses the user's chosen words.",
    },
  },
  load: () => Promise.resolve(Fixture),
});
