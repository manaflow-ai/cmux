// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { session } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { ChiefDock, type ChiefMascot } from "./ChiefDock";

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
  session({
    sessionId: "chief-child",
    title: "Inspect a changed file",
    status: "running",
    indicator: "working",
    spawnedBy: "chief-working",
    preview: "A child agent is checking one file.",
    updatedAt: 1100,
  }),
];

const WALLPAPER_REFERENCE = new URL("../../gallery/fixtures/assets/chief-wallpaper-reference.png", import.meta.url)
  .href;

const wallpaperGlassPlay = async (ctx: PlayContext) => {
  const background = `url("${WALLPAPER_REFERENCE}") center / cover fixed`;
  for (const node of [ctx.document.documentElement, ctx.document.body]) {
    node.style.setProperty("background", background, "important");
    node.style.setProperty("background-color", "#121212", "important");
  }
  for (const node of ctx.document.querySelectorAll<HTMLElement>("#root, .acpmux-shell, .acpmux-quick, .acpmux-main")) {
    node.style.setProperty("background", "transparent", "important");
  }
};

const toggleStack = async (ctx: PlayContext) => {
  await ctx.click({ role: "button", name: "Agent Chat" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-chief-dock[data-expanded="false"]'));
  await ctx.click({ role: "button", name: "Agent Chat" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-chief-dock[data-expanded="true"]'));
};

const mascotOption = (mascot: ChiefMascot, note: string) => ({
  note,
  props: {
    sessions: base,
    currentId: "chief-working",
    mascot,
    defaultExpanded: true,
    onSelect: () => undefined,
    onNewChat: () => undefined,
    onMoveToTab: () => undefined,
  },
});

const controlSizeOption = (size: number, note: string) => ({
  ...mascotOption("orb", note),
  play: async (ctx: PlayContext) => {
    await wallpaperGlassPlay(ctx);
    for (const icon of ctx.document.querySelectorAll<SVGElement>(".acpmux-chief-dock-tool > svg")) {
      icon.style.width = `${size}px`;
      icon.style.height = `${size}px`;
    }
    // Show the close and move-to-tab marks beside the rail for comparison.
    ctx.document.querySelector<HTMLButtonElement>(".acpmux-chief-card-main")?.focus();
  },
});

export default componentEntry({
  id: "agent-pane.chief-dock",
  title: "Chief Dock",
  area: "Agent pane",
  pane: true,
  height: 760,
  widths: { narrow: 520, normal: 720, wide: 900 },
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
    "controls-compact": controlSizeOption(
      18,
      "Compact: 18px pack icons, quieter but small beside the wide glass slots.",
    ),
    "controls-balanced": controlSizeOption(
      20,
      "Selected: 20px pack icons across the rail and card actions; clear silhouettes with room inside the glass slots.",
    ),
    "controls-large": controlSizeOption(22, "Large: 22px rail icons, more prominent than the card actions."),
    baseline: {
      note: "The default Chief orb with a stacked set of working, attention and quiet agent chats; spawned child chats stay folded.",
      props: {
        sessions: base,
        currentId: "chief-working",
        defaultExpanded: true,
        onSelect: () => undefined,
        onNewChat: () => undefined,
        onMoveToTab: () => undefined,
      },
    },
    "wallpaper-glass": {
      note: "Reference-backed glass check: the same deterministic stack over a busy wallpaper at the gallery viewport size.",
      props: {
        sessions: base,
        currentId: "chief-working",
        defaultExpanded: true,
        onSelect: () => undefined,
        onNewChat: () => undefined,
        onMoveToTab: () => undefined,
      },
      play: wallpaperGlassPlay,
    },
    "mascot-orb-spark": mascotOption("orb-spark", "Mascot option: a soft star-marked orb with a friendly pixel face."),
    "mascot-orb-hood": mascotOption("orb-hood", "Mascot option: a hooded night orb with a compact silhouette."),
    "mascot-machine": mascotOption(
      "machine",
      "Mascot option: a tiny friendly machine with a compact, readable pixel silhouette.",
    ),
    "mascot-machine-cyan": mascotOption("machine-cyan", "Mascot option: a round cyan-lit machine companion."),
    "mascot-machine-blue": mascotOption(
      "machine-blue",
      "Mascot option: a blue-eared machine with a playful product silhouette.",
    ),
    "mascot-moon": mascotOption(
      "moon",
      "Mascot option: a soft moon-moth companion, kept as an alternate Chief personality.",
    ),
    "mascot-moon-blue": mascotOption("moon-blue", "Mascot option: a blue cloud companion with a simple star antenna."),
    "mascot-fox": mascotOption("fox", "Mascot option: a warm pixel fox Chief with a clear, expressive silhouette."),
    "attention-stack": {
      note: "Two agents need input; the badge and attention dots keep the important work visible first.",
      props: {
        sessions: [base[1], { ...base[2], indicator: "failed", status: "failed" }, base[0]],
        currentId: "chief-input",
        defaultExpanded: true,
        onSelect: () => undefined,
        onNewChat: () => undefined,
        onMoveToTab: () => undefined,
      },
    },
    "toggle-stack": {
      note: "The mascot rail folds and unfolds the glass stack while preserving its anchor and focus target.",
      props: {
        sessions: base,
        currentId: "chief-input",
        onSelect: () => undefined,
        onNewChat: () => undefined,
        onMoveToTab: () => undefined,
      },
      play: toggleStack,
    },
    "steering-stack": {
      note: "A running chat owns two queued steering prompts; its card becomes the active lead in the overlapping stack.",
      props: {
        sessions: base,
        currentId: "chief-working",
        defaultExpanded: true,
        queueCounts: new Map([["chief-working", 2]]),
        steeringIds: new Set(["chief-working"]),
        onSelect: () => undefined,
        onNewChat: () => undefined,
        onMoveToTab: () => undefined,
      },
    },
  },
});
