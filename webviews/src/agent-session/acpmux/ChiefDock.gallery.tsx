// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { session } from "../../gallery/fixtures/acpmux";
import { ChiefDock } from "./ChiefDock";

const base = [
  session({
    sessionId: "chief-working",
    title: "Prepare the release notes",
    status: "running",
    indicator: "working",
    preview: "Checking the changelog and open pull requests…",
    updatedAt: 1000,
  }),
  session({
    sessionId: "chief-input",
    title: "Review the sidebar polish",
    status: "waiting",
    indicator: "input",
    pendingPermissions: 1,
    preview: "The agent needs your approval to continue.",
    updatedAt: 900,
  }),
  session({
    sessionId: "chief-unread",
    title: "Update the screenshots",
    status: "idle",
    indicator: "done",
    unread: true,
    preview: "The new gallery captures are ready.",
    updatedAt: 800,
  }),
  session({ sessionId: "chief-quiet", title: "Draft the onboarding copy", status: "idle", updatedAt: 700 }),
];

export default componentEntry({
  id: "agent-pane.chief-dock",
  title: "Chief Dock",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: ".acpmux-chief-dock" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The dock keeps its rail and card stack anchored while session status changes." },
    layoutShiftMax: { value: 0.05, reason: "Opening and closing the stack changes only the dock's own overlay." },
    longFrameFailMs: { value: 33, reason: "The dock is a small local list and should stay responsive." },
  },
  covers: ["agent-session/acpmux/ChiefDock.tsx#ChiefDock"],
  styles: () => import("./styles.css"),
  load: async () => ChiefDock,
  variants: {
    baseline: {
      note: "A Chief mascot rail with a stacked set of working, attention and quiet agent chats.",
      props: {
        sessions: base,
        currentId: "chief-working",
        onSelect: () => undefined,
        onNewChat: () => undefined,
        onMoveToTab: () => undefined,
      },
    },
    "attention-stack": {
      note: "Two agents need input; the badge and attention dots keep the important work visible first.",
      props: {
        sessions: [base[1], { ...base[2], indicator: "failed", status: "failed" }, base[0]],
        currentId: "chief-input",
        onSelect: () => undefined,
        onNewChat: () => undefined,
        onMoveToTab: () => undefined,
      },
    },
  },
});
