// l10n-allow-file: gallery fixtures for the live status line's sample verbs.
import { componentEntry } from "../../../gallery/format";
import { Thinking } from "./Thinking";
import { DEFAULT_STATUS_VERB_CONFIG, StatusVerbContext, type StatusVerbConfig } from "../statusVerbs";

type Variant = "rotating" | "thinking-only" | "custom";

function Fixture({ variant }: { variant: Variant }) {
  const config: StatusVerbConfig =
    variant === "thinking-only"
      ? { mode: "thinking", verbs: ["Thinking"] }
      : variant === "custom"
        ? { mode: "custom", verbs: ["Planning", "Reading", "Testing"] }
        : DEFAULT_STATUS_VERB_CONFIG;
  return (
    <StatusVerbContext.Provider value={config}>
      <div style={{ padding: 24, maxWidth: 640 }}>
        <div className="text-caption" style={{ marginBottom: 16, opacity: 0.7 }}>
          {variant === "rotating"
            ? "Default rotating verbs"
            : variant === "thinking-only"
              ? "Thinking only"
              : "Custom verbs"}
        </div>
        <Thinking since={0} now={() => (variant === "rotating" ? 4_800 : 2_400)} />
      </div>
    </StatusVerbContext.Provider>
  );
}

export default componentEntry<{ variant: Variant }>({
  id: "agent-pane.status-verbs",
  title: "Live status verbs",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 360, normal: 560, wide: 760 },
  covers: ["agent-session/acpmux/conversation/Thinking.tsx#Thinking"],
  variants: {
    rotating: {
      props: { variant: "rotating" },
      note: "The default live line rotates through cmux's own short -ing verbs while a turn works.",
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

