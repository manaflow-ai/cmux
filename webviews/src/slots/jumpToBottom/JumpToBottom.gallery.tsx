// l10n-allow-file: gallery fixtures for the Jump to latest slot.
// The theme slot `chat.jumpToBottom` (schemas/theme/slots.json) in the real button (VirtualTranscript.tsx
// JumpToLatest), over a few lines of text so the glass has something to bend: each built-in variant
// chosen through the theme look's `slots` map, idle and while the agent works, the still frame under
// Reduce Motion / static status indicators, and the two fallbacks (an id no variant has, a variant that
// throws), both drawing the default arrow in its place. Press the button to see a variant's dip.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { JumpToLatest } from "../../agent-session/acpmux/VirtualTranscript";
import { configureThemeSlots, registerSlotVariant } from "../registry";
import { jumpToBottomSlot } from "./index";

type Props = {
  /** The variant the theme look names; absent is a look without `slots`. */
  variant?: string;
  /** The agent is working. */
  working?: boolean;
  /** The host's Reduce Motion push: `data-status-indicators="static"`. */
  still?: boolean;
  /** Registers a variant that throws, and selects it. */
  broken?: boolean;
};

function Broken(): never {
  throw new Error("gallery: a theme pack's variant that throws");
}

const LINES = Array.from(
  { length: 6 },
  (_, index) => `Case ${index + 1} passes: the client retries a temporary failure and keeps the request id.`,
);

function Fixture({ variant, working = false, still = false, broken = false }: Props) {
  // Before the first render, as the host's theme push lands before the pane mounts.
  useState(() => {
    if (broken) registerSlotVariant(jumpToBottomSlot, "gallery-broken", Broken);
    configureThemeSlots(variant ? { [jumpToBottomSlot.id]: variant } : undefined);
    if (still) document.documentElement.dataset.statusIndicators = "static";
    return null;
  });
  return (
    <div style={{ position: "relative", height: 140, padding: 16, overflow: "hidden" }}>
      {LINES.map((line) => (
        <p key={line} style={{ margin: "0 0 4px" }}>
          {line}
        </p>
      ))}
      <JumpToLatest shown working={working} lift={0} onJump={() => {}} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.jump-to-bottom-slot",
  title: "Jump to latest (theme slot)",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 360, normal: 560 },
  styles: () =>
    Promise.all([
      import("../../agent-session/acpmux/styles.css"),
      import("../../agent-session/acpmux/conversation/conversation.css"),
      import("../../ui/glass/glass.css"),
      import("./jumpToBottom.css"),
    ]),
  covers: [
    "slots/jumpToBottom/DefaultJumpArrow.tsx",
    "slots/jumpToBottom/NudgeArrow.tsx",
    "slots/jumpToBottom/BobArrow.tsx",
    "slots/jumpToBottom/CascadeChevrons.tsx",
  ],
  keywords: ["theme", "slot", "jump", "latest", "bottom", "arrow", "nudge", "bob", "cascade"],
  variants: {
    default: {
      props: {},
      note: "No `slots` in the look: the default, the shipped static arrow, unchanged.",
    },
    nudge: {
      props: { variant: "nudge" },
      note: "The arrow drops in on the spring as the button appears; it dips while pressed.",
    },
    "bob-working": {
      props: { variant: "bob", working: true },
      note: "While the agent works the arrow bobs toward the latest message once per breath.",
    },
    "bob-idle": {
      props: { variant: "bob" },
      note: "Idle: the arrow rests.",
    },
    "cascade-working": {
      props: { variant: "cascade", working: true },
      note: "Two arrows rest dim and a lit arrow steps from the upper to the lower while the agent works.",
    },
    "reduced-motion": {
      props: { variant: "cascade", working: true, still: true },
      note: "Reduce Motion or static status indicators: the still frame, both arrows at full strength.",
    },
    "unknown-id": {
      props: { variant: "sparkles" },
      note: "The look names a variant no one registered: the default draws.",
    },
    "fallback-on-error": {
      props: { broken: true, variant: "gallery-broken" },
      note: "The selected variant throws: its slot alone falls back to the default arrow.",
    },
  },
  load: () => Promise.resolve(Fixture),
});
