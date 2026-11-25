// l10n-allow-file: gallery fixtures for a look's thinking glyph.
// A look's thinking glyph (thinkingLook.ts `glyph`, a cmux.particles/1 document) on the real live status
// line (Thinking.tsx) and the real Jump to latest button (VirtualTranscript.tsx JumpToLatest, with
// jumpButton "glyph" at glyphSize 2.4), as the host's display push sets them. Leo, 2026-11-19: "the dots
// and the way it moves changes a lot". Three sample looks of our own (thinkingGlyphSamples.ts) with
// different dot behavior, each while the agent thinks and while it runs a command; `none` is cmux
// without a look, unchanged.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { JumpToLatest } from "../VirtualTranscript";
import { setChatDisplay } from "../chatDisplay";
import { Thinking } from "./Thinking";
import { THINKING_GLYPH_KEY, THINKING_GLYPH_SIZE_KEY, THINKING_JUMP_BUTTON_KEY } from "./thinkingLook";
import { setLiveGlyphTrigger } from "./thinkingGlyphModel";
import { SAMPLE_GLYPHS } from "./thinkingGlyphSamples";

type Props = {
  look?: keyof typeof SAMPLE_GLYPHS;
  /** The agent's activity: the document's trigger. */
  trigger?: string;
  /** The host's Reduce Motion push: `data-status-indicators="static"`. */
  still?: boolean;
};

function Fixture({ look, trigger = "thinking", still = false }: Props) {
  // Before the first render, as the host's display push lands before the pane mounts.
  useState(() => {
    setChatDisplay(
      look
        ? {
            [THINKING_GLYPH_KEY]: SAMPLE_GLYPHS[look],
            [THINKING_JUMP_BUTTON_KEY]: "glyph",
            [THINKING_GLYPH_SIZE_KEY]: 2.4,
          }
        : {},
    );
    setLiveGlyphTrigger(trigger);
    if (still) document.documentElement.dataset.statusIndicators = "static";
    return null;
  });
  return (
    <div style={{ position: "relative", height: 150, padding: "16px 24px", overflow: "hidden" }}>
      <Thinking glyphTrigger={trigger} />
      <JumpToLatest shown working lift={0} onJump={() => {}} />
    </div>
  );
}

const variants: Record<string, { props: Props; note: string }> = {
  none: { props: {}, note: "No look: the line and the arrow as cmux draws them." },
  "reduced-motion": {
    props: { look: "trade", still: true },
    note: "Reduce Motion: the glyph holds the first frame of what would play.",
  },
};
for (const look of Object.keys(SAMPLE_GLYPHS) as (keyof typeof SAMPLE_GLYPHS)[]) {
  variants[look] = { props: { look }, note: `The ${look} sample while the agent thinks.` };
  variants[`${look}-execute`] = {
    props: { look, trigger: "execute" },
    note: `The ${look} sample while the agent runs a command (the document's execute trigger, else cycle).`,
  };
}

export default componentEntry<Props>({
  id: "agent-pane.thinking-glyph",
  title: "Thinking glyph (a look's particles document on the live line and Jump to latest)",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 360, normal: 560 },
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../../../ui/glass/glass.css"),
      import("../jumpPair.css"),
    ]),
  covers: [
    "agent-session/acpmux/conversation/ThinkingGlyph.tsx",
    "agent-session/acpmux/conversation/thinkingGlyphModel.ts",
    "agent-session/acpmux/conversation/thinkingLook.ts",
  ],
  keywords: ["thinking", "glyph", "particles", "choreography", "dots", "look", "claude", "jump"],
  variants,
  load: () => Promise.resolve(Fixture),
});
