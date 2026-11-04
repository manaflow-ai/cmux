// l10n-allow-file: gallery fixtures exercise the stable automation label, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { useT } from "./i18n";
import { ContextRing } from "./ComposerPickers";
import { openPicker } from "./pickerOpeners";
import { compactingUsage } from "./usageStats";
import { contextRingLook } from "./contextRingLook.experiment";

type Props = {
  used?: number;
  size?: number;
  setup?: number;
  breakdown?: unknown;
  details?: boolean;
  wheel?: "compact" | "standard" | "minimal";
  /// The prompt cache's time left (ms; 0 or less: expired), on a pinned clock.
  cacheLeftMs?: number;
};

/// The gallery's pinned clock, so the cache countdown reads the same in every capture.
const GALLERY_NOW = Date.UTC(2026, 10, 3, 5, 11);
const galleryNow = () => GALLERY_NOW;

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
        cacheExpiresAt={props.cacheLeftMs === undefined ? undefined : GALLERY_NOW + props.cacheLeftMs}
        now={galleryNow}
        // The chat's Session Info reveal (App.tsx); the gallery has no Session Info to open.
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

// Details › runs edge to edge (full bleed) at the card's bottom, and its chevron centres on the label.
const detailsRow: Play = async (ctx) => {
  await hoverCard(ctx);
  const card = ctx.document.querySelector<HTMLElement>(".acpmux-context-card");
  const details = card?.querySelector<HTMLElement>(".acpmux-context-card-details");
  const chevron = details?.querySelector<SVGElement>(".acpmux-context-card-details-chevron");
  const label = [...(details?.childNodes ?? [])].find((node) => node.nodeType === 3);
  if (!card || !details || !chevron || !label) throw new Error("The context card's Details row is missing");
  const outer = card.getBoundingClientRect();
  const row = details.getBoundingClientRect();
  const gaps = [row.left - outer.left, outer.right - row.right, outer.bottom - row.bottom];
  if (gaps.some((gap) => Math.abs(gap) > 0.5)) throw new Error(`Details is inset from the card: ${gaps.join(", ")} px`);
  const range = ctx.document.createRange();
  range.selectNodeContents(label);
  const center = (rect: DOMRect) => rect.top + rect.height / 2;
  const delta = Math.abs(center(chevron.getBoundingClientRect()) - center(range.getBoundingClientRect()));
  if (delta > 0.5) throw new Error(`The Details chevron is ${delta.toFixed(2)} px off the label's centre`);
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
  // Leo (2026-11-03) read the ring at 68% as a loading spinner. Compare its looks at 25, 68 and 95%
  // (variants gauge-*); `track` shipped: a visible remaining-share track and flat arc ends.
  experiment: {
    definition: contextRingLook,
    script: [{ name: "Rest", run: async () => {} }],
  },
  variants: {
    ...Object.fromEntries(
      ([25, 68, 95] as const).map((percent) => [
        `gauge-${percent}`,
        {
          note: `${percent}% used, the quiet row's resting ring: the remaining share is a visible track, so the circle reads as a gauge and never as a spinner (compare the context-ring-look arms).`,
          props: { used: percent * 2_000, size: 200_000 },
        },
      ]),
    ),
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
      note: "A one-line context summary keeps the token count and percentage together over the menus' glass; Details › runs edge to edge at the bottom, its chevron centred on the label.",
      props: { used: 131_400, size: 1_000_000, details: true },
      play: detailsRow,
    },
    "popover-breakdown": {
      note: "When the harness reports categories, the card adds only the short Messages, Tools and System headline rows, on the summary's text column: swatches, names and tokens each on one line.",
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
    "card-autocompact-window": {
      note: "Shipped (Leo, 2026-11-02: \"whatever a user set their compact window to it should be that instead of always showing the defautl (e.g. we should be seieng 400k)\"): a 1M model whose chat compacts at 400K reads 85% · 339.9K / 400K, the window Claude Code's /context names (compactingUsage), not the model's 1M.",
      props: {
        ...compactingUsage({ used: 339_900, size: 1_000_000 }, undefined, { maxTokens: 400_000 }),
        details: true,
        breakdown: {
          maxTokens: 400_000,
          categories: [
            { name: "Messages", kind: "used", tokens: 280_900 },
            { name: "MCP tools", kind: "used", tokens: 10_600 },
            { name: "System prompt", kind: "used", tokens: 48_400 },
            { name: "Free space", kind: "free", tokens: 60_100 },
          ],
        },
      },
      play: async (ctx) => {
        await hoverCard(ctx);
        const line = ctx.document.querySelector(".acpmux-context-card-line")?.textContent ?? "";
        if (!/339\.9K\s*\/\s*400K/.test(line)) throw new Error(`The context card reads "${line}", not / 400K`);
      },
    },
    ...Object.fromEntries(
      (
        [
          ["cache-warm", 192_000, "Cache warm · 3:12 left"],
          ["cache-expiring-soon", 24_000, "Cache warm · 0:24 left"],
          ["cache-expired", 0, "Cache expired"],
        ] as const
      ).map(([id, cacheLeftMs, expected]) => [
        id,
        {
          note: `Leo (2026-11-03: "i heard claude's cache time was like 5min... idk if we maybe also wanna be showing that"): the Claude card of his screenshot, 79% · 316.9K / 399.1K, with the prompt cache's line under the bar: "${expected}". acpmux sends the expiry; the card only counts down to it${cacheLeftMs > 0 && cacheLeftMs <= 60_000 ? ", in the warning color in its last minute" : ""}.`,
          props: {
            used: 316_900,
            size: 399_100,
            details: true,
            cacheLeftMs,
            breakdown: {
              maxTokens: 399_100,
              categories: [
                { name: "Messages", kind: "used", tokens: 253_800 },
                { name: "MCP tools", kind: "used", tokens: 3_000 },
                { name: "System prompt", kind: "used", tokens: 60_100 },
                { name: "Free space", kind: "free", tokens: 82_200 },
              ],
            },
          },
          play: (async (ctx) => {
            await hoverCard(ctx);
            const line = ctx.document.querySelector(".acpmux-context-card-cache")?.textContent ?? "";
            if (line !== expected) throw new Error(`The cache line reads "${line}", not "${expected}"`);
          }) satisfies Play,
        },
      ]),
    ),
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
      note: "A fresh chat: usage is known but nothing is used, so only the track shows.",
      props: { used: 0, size: 200000 },
    },
    "usage-30": {
      note: "About a third used: an arc from twelve o'clock over the visible track, read as a share rather than a spinner.",
      props: { used: 60000, size: 200000 },
    },
    "usage-75": {
      note: "Three quarters used: the arc runs most of the way round, the rest of the circle still drawn as track.",
      props: { used: 150000, size: 200000 },
    },
    "usage-full": {
      note: "The window is full: the arc is the whole ring.",
      props: { used: 200000, size: 200000 },
    },
  },
});
