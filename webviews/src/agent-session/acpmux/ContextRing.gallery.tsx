// l10n-allow-file: gallery fixtures exercise the stable automation label, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { useT } from "./i18n";
import { ContextRing } from "./ComposerPickers";
import type { ContextBreakdown } from "./contextBreakdown";
import { openPicker } from "./pickerOpeners";

type Props = {
  used?: number;
  size?: number;
  setup?: number;
  details?: boolean;
  breakdown?: ContextBreakdown;
  model?: string;
  /// Minutes since the chat last compacted.
  compactedMinutesAgo?: number;
  compact?: boolean;
  working?: boolean;
};

// The gallery's clock, so a compaction's age reads the same in every capture.
const NOW = Date.UTC(2026, 9, 21, 12, 0, 0);

/// Claude Code 2.1.305's /context rows for a chat 111K into a 475K window.
const CLAUDE_BREAKDOWN: ContextBreakdown = {
  categories: [
    { id: "system_prompt", name: "System prompt", tokens: 6_200 },
    { id: "system_tools", name: "System tools", tokens: 14_300 },
    { id: "mcp_tools", name: "MCP tools", tokens: 3_100 },
    { id: "custom_agents", name: "Custom agents", tokens: 900 },
    { id: "memory_files", name: "Memory files", tokens: 4_800 },
    { id: "skills", name: "Skills", tokens: 1_600 },
    { id: "messages", name: "Messages", tokens: 80_100 },
    { id: "free_space", name: "Free space", tokens: 364_000 },
  ],
  attachmentTokens: 2_500,
  toolResults: [{ name: "Read", tokens: 9_000 }],
};

function GalleryContextRing(props: Props) {
  const t = useT();
  const [requested, setRequested] = useState(false);
  return (
    <div className="context-ring-gallery" data-context-automation={requested ? "requested" : "idle"}>
      <ContextRing
        used={props.used}
        size={props.size}
        setup={props.setup}
        breakdown={props.breakdown}
        model={props.model}
        compactedAt={props.compactedMinutesAgo === undefined ? undefined : NOW - props.compactedMinutesAgo * 60_000}
        now={NOW}
        working={props.working}
        onCompact={props.compact ? () => {} : undefined}
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
  styles: () => Promise.all([import("./styles.css"), import("./composerControls.css")]),
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
      note: "Hover on a Claude chat: the glass card reads 23% used · 111K / 475K, the bar splits the agent's setup from the conversation, and Details › opens the Inspector's Context section. Plan limits are not reported to the pane yet, so the card shows none.",
      props: { used: 111_000, size: 475_000, setup: 21_000, details: true },
      play: hoverCard,
    },
    "card-claude-rich": {
      note: "Hover on a Claude chat that reported Claude Code's /context rows: 23% used, the bar and a row each for system, tools, files and messages, Opus 5.5's 475K window, when it last compacted, Compact now and Details ›.",
      props: {
        used: 111_000,
        size: 475_000,
        setup: 21_000,
        breakdown: CLAUDE_BREAKDOWN,
        model: "Opus 5.5",
        compactedMinutesAgo: 12,
        compact: true,
        details: true,
      },
      play: hoverCard,
    },
    "card-codex-rich": {
      note: "Hover on a Codex chat: Codex reports no breakdown and this chat never compacted, so the card shows the totals, the model's window, Compact now and Details ›, and no category rows.",
      props: { used: 111_000, size: 475_000, model: "GPT-5.5 Codex", compact: true, details: true },
      play: hoverCard,
    },
    "card-working": {
      note: "While a turn runs, Compact now stays in place but is off.",
      props: { used: 111_000, size: 475_000, breakdown: CLAUDE_BREAKDOWN, model: "Opus 5.5", compact: true, details: true, working: true },
      play: hoverCard,
    },
    "card-codex": {
      note: "Hover on a Codex chat that reports only the window: the context line, one used stretch on the bar, and Details ›.",
      props: { used: 111_000, size: 475_000, details: true },
      play: hoverCard,
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
