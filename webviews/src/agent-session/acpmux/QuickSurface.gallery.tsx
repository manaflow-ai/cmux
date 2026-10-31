// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { QuickSurface } from "./QuickSurface";
import type { FloatingStatus, QuickFloating } from "./FloatingChat";

type Props = {
  mode: "empty" | "transcript" | "waiting" | "long" | "floating" | "compact";
  /// The floating chat's compact bar state (cx-b9qi).
  status?: FloatingStatus;
};

function floating(mode: Props["mode"], status: FloatingStatus = "streaming"): QuickFloating | undefined {
  if (mode !== "floating" && mode !== "compact") return undefined;
  return {
    state: { holding: true, onTop: true, collapsed: mode === "compact" },
    status,
    title: "Fix the flaky upload test",
    line: "Retrying the third upload with backoff now.",
    setOnTop: () => {},
    setCollapsed: () => {},
    moveToTab: () => {},
    includeContext: () => {},
  };
}

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
      <div className="ui-glass acpmux-composer-box">
        <div className="acpmux-composer-field">Ask the agent anything…</div>
      </div>
    </div>
  );
}

function GalleryQuickSurface({ mode, status }: Props) {
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
        floating={floating(mode, status)}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.quick-surface",
  title: "Quick agent surface",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-quick-surface-fixture]" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "The quick surface host and its footer must keep the panel anchor stable across transcript states.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Adding a transcript or trust ask must not reflow the fixed composer host or shortcut footer.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Quick surface state changes should remain responsive on the gallery host.",
    },
  },
  covers: [
    "agent-session/acpmux/QuickSurface.tsx#QuickSurface",
    "agent-session/acpmux/QuickKeyHints.tsx#QuickKeyHints",
    "agent-session/acpmux/FloatingChat.tsx#FloatingHeader",
    "agent-session/acpmux/FloatingChat.tsx#FloatingCompactBar",
  ],
  styles: () => Promise.all([import("./styles.css"), import("./header/header.css")]),
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
    floating: {
      props: { mode: "floating" },
      note: "The floating chat (cx-b9qi) holds a running chat: its title, keep on top, compact bar and move to tab over the transcript.",
    },
    "compact-streaming": {
      props: { mode: "compact", status: "streaming" },
      note: "Folded to its compact bar while the agent works: the state mark breathes beside the title and the reply's last line.",
    },
    "compact-needs-input": {
      props: { mode: "compact", status: "attention" },
      note: "Folded while the chat waits on the user: the mark turns to the warning color.",
    },
  },
});
