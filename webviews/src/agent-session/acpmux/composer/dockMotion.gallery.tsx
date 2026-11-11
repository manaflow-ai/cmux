// l10n-allow-file: deterministic motion fixture text.
// The composer growing over a followed transcript, then sending, per arm of the dock motion
// (dockMotion.experiment.ts; Leo, 2026-11-11, on his NIGHTLY: "ok the fact that [it] is animated up...
// do we even want stuff to push up vs just simple... covering stuff? im not sure. if we can get it
// fast, MAYBE / otherwise idk / but if you look at the [animation] for when things get sent: it's not
// good"). The real transcript and composer in the floating bottom stack, as fieldGrowth.gallery.tsx.
// test/agent-pane-composer-dock-motion.test.ts measures both arms frame by frame in the real pane.
import { useMemo, useState } from "react";
import { chat } from "../../../gallery/fixtures/acpmux";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import { Composer } from "../Composer";
import type { AcpmuxRow } from "../model";
import { turnView } from "../conversation/turns";
import { composerDockMotion } from "./dockMotion.experiment";

const paragraph = (index: number) =>
  `Answer ${index + 1}: the client waits longer before each retry, capped at eight seconds, and stops after five attempts.`;
const snapshot = chat([], { title: "Dock motion" });
const NoChips = () => null;
const expanded = new Set<string>();

function DockMotionGallery() {
  const [dock, setDock] = useState<HTMLElement | null>(null);
  const rows = useMemo(
    () =>
      turnView(
        Array.from({ length: 10 }, (_, index): AcpmuxRow[] => [
          { id: `user-${index}`, kind: "user", version: 1, at: index + 1, text: `Check step ${index + 1}` },
          { id: `answer-${index}`, kind: "assistant", version: 1, at: index + 1, text: paragraph(index) },
        ]).flat(),
        expanded,
        { working: false },
      ),
    [],
  );
  return (
    <section className="acpmux-shell" style={{ height: "100%" }} aria-label="Dock motion">
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <VirtualTranscript
            rows={rows}
            sessionId="dock-motion"
            dock={dock}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </div>
        <div ref={setDock} className="acpmux-dock">
          <Composer snapshot={snapshot} chips={NoChips} onSend={() => true} onStop={() => undefined} />
        </div>
      </div>
    </section>
  );
}

const LINES = ["oh this is super wack looking", "when there's a composer thing raised", "then it gets sent"];
const settled = (ctx: Parameters<Play>[0]) =>
  ctx.waitFor(
    () => (ctx.find({ selector: ".acpmux-composer-box" }) as HTMLElement).getAnimations({ subtree: true }).length === 0,
    { capMs: 2_000 },
  );

/// Three lines, each after Shift-Return, as Leo typed them.
const typeLines: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-composer-box .acpmux-md" });
  for (const [index, line] of LINES.entries()) {
    if (index > 0) await ctx.press("Shift+Enter");
    await ctx.type(line);
    await settled(ctx);
  }
};

/// The lines, then Return.
const typeAndSend: Play = async (ctx) => {
  await typeLines(ctx);
  await ctx.press("Enter");
  await settled(ctx);
};

/// The lines, then the reader's wheel past the end: the rows under the grown composer come into reach.
const typeAndReach: Play = async (ctx) => {
  await typeLines(ctx);
  await ctx.scroll({ selector: ".acpmux-scroll" }, 400);
};

export default componentEntry<Record<string, never>>({
  id: "agent-pane.composer-dock-motion",
  title: "Composer growth over the transcript: overlay or push",
  area: "Agent pane",
  height: 640,
  checks: {
    settleMaxMs: { value: 6_000, reason: "Three typed lines, then the send, settle." },
  },
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript"],
  load: async () => DockMotionGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../composerControls.css"),
      import("../bottomStack.css"),
    ]),
  variants: {
    "grown-overlay": {
      props: {},
      play: typeLines,
      note: "Selected (overlay): three lines typed, the transcript where it was; the composer's glass covers its foot.",
    },
    "grown-reached": {
      props: {},
      play: typeAndReach,
      note: "Overlay, then a wheel past the end: the room takes the composer's growth at once and the last row scrolls into view.",
    },
    "sent-overlay": {
      props: {},
      play: typeAndSend,
      note: "Overlay, then Return: the composer clears and the transcript rises once, into the sent prompt's room.",
    },
  },
  experiment: {
    definition: composerDockMotion,
    script: [
      { name: "Type three lines", run: typeLines },
      { name: "Type and send", run: typeAndSend },
    ],
  },
});
