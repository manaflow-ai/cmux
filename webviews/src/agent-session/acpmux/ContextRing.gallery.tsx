// l10n-allow-file: gallery fixtures exercise the stable automation label, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { useT } from "./i18n";
import { ContextRing } from "./ComposerPickers";
import { openPicker } from "./pickerOpeners";

type Props = {
  used?: number;
  size?: number;
  setup?: number;
  breakdown?: unknown;
  details?: boolean;
  wheel?: "compact" | "standard" | "minimal";
};

function GalleryContextRing(props: Props) {
  const t = useT();
  const [requested, setRequested] = useState(false);
  return (
    <div
      className={`context-ring-gallery context-ring-gallery--${props.wheel ?? "compact"}`}
      data-context-automation={requested ? "requested" : "idle"}
    >
      <ContextRing
        used={props.used}
        size={props.size}
        setup={props.setup}
        breakdown={props.breakdown}
        // The chat's Inspector reveal (App.tsx); the gallery has no Inspector to open.
        onOpenDetails={props.details ? () => {} : undefined}
      />
      <button
        type="button"
        className="context-ring-gallery-opener"
        onClick={() => {
          setRequested(true);
          openPicker(t("context.title"));
        }}
      >
        Open by automation
      </button>
    </div>
  );
}

const openByAutomation: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open by automation" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-context-automation="requested"]') !== null);
};

const openKnownByAutomation: Play = async (ctx) => {
  await openByAutomation(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-context-card") !== null);
};

// Resting the pointer on the ring shows the card with no click (Leo 2026-10-21).
const hoverCard: Play = async (ctx) => {
  await ctx.hover({ selector: "button.acpmux-context-ring" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-context-card"));
};

export default componentEntry<Props>({
  id: "agent-pane.context-ring",
  title: "Context usage ring",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: ".acpmux-context" }],
  covers: [
    "agent-session/acpmux/ComposerPickers.tsx#ContextRing",
    "agent-session/acpmux/ContextCard.tsx#ContextCardBody",
  ],
  styles: () =>
    Promise.all([import("./styles.css"), import("./composerControls.css"), import("./ContextRing.gallery.css")]),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Showing the context card must leave the ring's trigger geometry fixed.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "The context card renders in a portal and must not add flow around the ring.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "The context card is a local hover card and should open within one display frame.",
    },
  },
  load: async () => GalleryContextRing,
  variants: {
    "unknown-usage": {
      note: "Before the first usage report the ring keeps its place, and automation cannot open an empty 0% surface.",
      props: {},
      play: openByAutomation,
    },
    "known-usage": {
      note: "Once usage is known, the same automation path pins the context card open.",
      props: { used: 33551, size: 200000, setup: 12000 },
      play: openKnownByAutomation,
    },
    "card-claude": {
      note: "Hover on a Claude chat: the compact glass card reads 111K / 475K · 23%, shows a thin usage bar and short category summary, and keeps Details › available.",
      props: { used: 111_000, size: 475_000, setup: 21_000, details: true },
      play: hoverCard,
    },
    "card-codex": {
      note: "Hover on a Codex chat that reports only the window: the left-aligned card stays compact with one summary line and a thin usage bar.",
      props: { used: 111_000, size: 475_000, details: true },
      play: hoverCard,
    },
    "popover-summary": {
      note: "A one-line context summary keeps the token count and percentage together over the shared glass material.",
      props: { used: 131_400, size: 1_000_000, details: true },
      play: hoverCard,
    },
    "popover-breakdown": {
      note: "When the harness reports categories, the card adds only the short Messages, Tools and System headline rows.",
      props: {
        used: 131_400,
        size: 1_000_000,
        details: true,
        breakdown: {
          maxTokens: 1_000_000,
          categories: [
            { name: "Messages", kind: "used", tokens: 92_000 },
            { name: "MCP tools", kind: "used", tokens: 21_400 },
            { name: "System tools", kind: "used", tokens: 8_000 },
            { name: "System prompt", kind: "used", tokens: 10_000 },
            { name: "Free space", kind: "free", tokens: 868_600 },
          ],
        },
      },
      play: hoverCard,
    },
    "popover-near-limit": {
      note: "A near-full context window keeps the usage track legible without expanding the popover or changing the composer row.",
      props: { used: 810_000, size: 1_000_000, details: true },
      play: hoverCard,
    },
    "wheel-compact": {
      note: "Chosen: the ChatGPT-sized 22 px hit target and 12 px ring keep the quiet row compact while preserving keyboard focus.",
      props: { used: 111_000, size: 475_000, wheel: "compact" },
    },
    "wheel-standard": {
      note: "Alternative: the previous 28 px target and 14 px ring, which left too much empty space beside the model pill.",
      props: { used: 111_000, size: 475_000, wheel: "standard" },
    },
    "wheel-minimal": {
      note: "Alternative: an 18 px target and 10 px ring, which loses a little too much pointer and focus room.",
      props: { used: 111_000, size: 475_000, wheel: "minimal" },
    },
    "usage-empty": {
      note: "A fresh chat: usage is known but nothing is used, so only the 1px track shows.",
      props: { used: 0, size: 200000 },
    },
    "usage-30": {
      note: "About a third used: a filled wedge from twelve o'clock, read as a share rather than a spinner.",
      props: { used: 60000, size: 200000 },
    },
    "usage-75": {
      note: "Three quarters used: the wedge covers most of the disc, still in the quiet text color.",
      props: { used: 150000, size: 200000 },
    },
    "usage-full": {
      note: "The window is full: the wedge is a whole disc inside the track.",
      props: { used: 200000, size: 200000 },
    },
  },
});
