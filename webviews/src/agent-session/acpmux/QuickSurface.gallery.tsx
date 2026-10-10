// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { QuickSurface } from "./QuickSurface";

type Props = {
  mode: "empty" | "transcript" | "waiting" | "long";
};

function transcript(mode: Props["mode"]) {
  if (mode === "empty") return undefined;
  const lines =
    mode === "long"
      ? ["Inspecting the workspace…", "Found three changed files.", "I will group the changes by intent."]
      : ["What should I improve?", "Start with the composer spacing."];
  return (
    <div className="acpmux-quick-fixture-transcript">
      {lines.map((line) => (
        <p key={line}>{line}</p>
      ))}
    </div>
  );
}

function composer() {
  return (
    <div className="acpmux-composer">
      <div className="acpmux-composer-box">
        <div className="acpmux-composer-field">Ask the agent anything…</div>
      </div>
    </div>
  );
}

function GalleryQuickSurface({ mode }: Props) {
  return (
    <div className="acpmux-shell" data-quick-surface-fixture>
      <QuickSurface
        transcript={transcript(mode)}
        asks={
          mode === "waiting" ? (
            <output className="acpmux-switch-notice">Waiting for folder trust before sending.</output>
          ) : undefined
        }
        composer={composer()}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.quick-surface",
  title: "Quick agent surface",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-quick-surface-fixture]" }],
  covers: [
    "agent-session/acpmux/QuickSurface.tsx#QuickSurface",
    "agent-session/acpmux/QuickKeyHints.tsx#QuickKeyHints",
  ],
  styles: () => import("./styles.css"),
  load: async () => GalleryQuickSurface,
  variants: {
    empty: {
      props: { mode: "empty" },
      note: "Before the first prompt the quick panel gives the composer the full surface and keeps its shortcut hints visible.",
    },
    transcript: { props: { mode: "transcript" } },
    waiting: {
      props: { mode: "waiting" },
      note: "Asks sit between the quick transcript and composer without displacing the footer hints.",
    },
    long: { props: { mode: "long" } },
  },
});
