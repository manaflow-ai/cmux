// l10n-allow-file: gallery fixtures for the thinking indicator slot.
// The theme slot `chat.thinkingIndicator` (schemas/theme/slots.json) in the real live line (Thinking.tsx):
// each built-in variant chosen through the theme look's `slots` map, the still frame under Reduce
// Motion / static status indicators, and the two fallbacks: an id no variant has and a variant that
// throws, both drawing the default in its place.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { Thinking } from "../../agent-session/acpmux/conversation/Thinking";
import { configureThemeSlots, registerSlotVariant } from "../registry";
import { thinkingIndicatorSlot } from "./index";

type Props = {
  /** The variant the theme look names; absent is a look without `slots`. */
  variant?: string;
  /** How long the turn has thought when the stage opens. */
  thoughtMs?: number;
  /** The host's Reduce Motion push: `data-status-indicators="static"`. */
  still?: boolean;
  /** Registers a variant that throws, and selects it. */
  broken?: boolean;
};

function Broken(): never {
  throw new Error("gallery: a theme pack's variant that throws");
}

function Fixture({ variant, thoughtMs = 4_000, still = false, broken = false }: Props) {
  // Before the first render, as the host's theme push lands before the pane mounts.
  const [since] = useState(() => {
    if (broken) registerSlotVariant(thinkingIndicatorSlot, "gallery-broken", Broken);
    configureThemeSlots(variant ? { [thinkingIndicatorSlot.id]: variant } : undefined);
    if (still) document.documentElement.dataset.statusIndicators = "static";
    return Date.now() - thoughtMs;
  });
  return (
    <div style={{ padding: 24, maxWidth: 640 }}>
      <Thinking since={since} verbKey="thinking-indicator-gallery" />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.thinking-indicator-slot",
  title: "Thinking indicator (theme slot)",
  area: "Agent pane",
  pane: true,
  height: 160,
  widths: { narrow: 360, normal: 560 },
  styles: () =>
    Promise.all([
      import("../../agent-session/acpmux/styles.css"),
      import("../../agent-session/acpmux/conversation/conversation.css"),
      import("./thinkingIndicator.css"),
    ]),
  covers: [
    "slots/Slot.tsx#Slot",
    "slots/thinkingIndicator/DefaultThinkingIndicator.tsx",
    "slots/thinkingIndicator/CountingDots.tsx",
    "slots/thinkingIndicator/PulseMark.tsx",
    "slots/thinkingIndicator/CaretMark.tsx",
    "slots/thinkingIndicator/BlockSteps.tsx",
    "slots/thinkingIndicator/slot.tsx#ReservedLabel",
  ],
  keywords: ["theme", "slot", "thinking", "indicator", "dots", "caret", "pulse", "blocks", "retro"],
  variants: {
    default: {
      props: {},
      note: "No `slots` in the look: the default, the shipped shimmer, unchanged.",
    },
    "counting-dots": {
      props: { variant: "counting-dots" },
      note: "A lit dot steps across three dim dots.",
    },
    "counting-dots-long": {
      props: { variant: "counting-dots", thoughtMs: 32_000 },
      note: "Past 20 s of thinking a fourth dot joins and the lit dot counts four.",
    },
    pulse: {
      props: { variant: "pulse" },
      note: "One round mark swells in once, then holds still.",
    },
    caret: {
      props: { variant: "caret" },
      note: "A caret steps ahead after the word; it never blinks.",
    },
    blocks: {
      props: { variant: "blocks" },
      note: "A lit block steps across three cells, no easing: the retro look.",
    },
    "reduced-motion": {
      props: { variant: "counting-dots", still: true },
      note: "Reduce Motion or static status indicators: the still frame, three dots at full strength.",
    },
    "unknown-id": {
      props: { variant: "sparkles" },
      note: "The look names a variant no one registered: the default draws.",
    },
    "fallback-on-error": {
      props: { broken: true, variant: "gallery-broken" },
      note: "The selected variant throws: its slot alone falls back to the default; the chat keeps going.",
    },
  },
  load: () => Promise.resolve(Fixture),
});
