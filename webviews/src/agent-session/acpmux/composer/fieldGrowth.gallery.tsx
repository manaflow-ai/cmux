// l10n-allow-file: deterministic motion fixture text.
// The composer growing as the reader types onto a new line, deletes one, and pastes forty lines,
// per arm of the composer growth motion (fieldGrowth.experiment.ts; Leo, 2026-11-07: "it's like
// the composer kind of doesn't grow smoothly. It grows in bursts."). The real composer in the
// floating bottom stack under a followed transcript, so its rows move with the card.
import { useMemo, useState } from "react";
import { chat } from "../../../gallery/fixtures/acpmux";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import { Composer } from "../Composer";
import type { AcpmuxRow } from "../model";
import { turnView } from "../conversation/turns";
import { fieldGrowthMotion } from "./fieldGrowth.experiment";

const paragraph = (index: number) =>
  `Answer ${index + 1}: the client waits longer before each retry, capped at eight seconds, and stops after five attempts.`;
const snapshot = chat([], { title: "Retry policy" });
const NoChips = () => null;
const expanded = new Set<string>();

function FieldGrowthGallery() {
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
    <section className="acpmux-shell" style={{ height: "100%" }} aria-label="Retry policy">
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <VirtualTranscript
            rows={rows}
            sessionId="field-growth"
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

const WRAP =
  "the client waits a little longer before each retry and adds random jitter so a crowd of clients does not retry in step";
const PASTE = Array.from({ length: 40 }, (_, index) => `Line ${index + 1} of the pasted notes`).join("\n");

const field = (ctx: Parameters<Play>[0]) => ctx.find({ selector: ".acpmux-composer-box .acpmux-md" }) as HTMLElement;
const card = (ctx: Parameters<Play>[0]) =>
  (ctx.find({ selector: ".acpmux-composer-box" }) as HTMLElement).getBoundingClientRect().height;
const settled = (ctx: Parameters<Play>[0]) =>
  ctx.waitFor(
    () => (ctx.find({ selector: ".acpmux-composer-box" }) as HTMLElement).getAnimations({ subtree: true }).length === 0,
    {
      capMs: 2_000,
    },
  );

/// Types onto a second line, then a third with Shift-Return, and deletes it again.
const typeWrap: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-composer-box .acpmux-md" });
  const before = card(ctx);
  await ctx.type(WRAP);
  await ctx.press("Shift+Enter");
  await ctx.type("and one more line");
  await settled(ctx);
  if (card(ctx) <= before) throw new Error("the composer did not grow");
  for (let index = 0; index < "and one more line".length + 1; index++) await ctx.press("Backspace");
  await settled(ctx);
};

/// Pastes forty lines at once, as a dictation pasted from another app does.
const pasteLines: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-composer-box .acpmux-md" });
  const data = new DataTransfer();
  data.setData("text/plain", PASTE);
  field(ctx).dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  await settled(ctx);
};

export default componentEntry<Record<string, never>>({
  id: "agent-pane.composer-growth",
  title: "Composer growth",
  area: "Agent pane",
  height: 640,
  checks: {
    settleMaxMs: { value: 6_000, reason: "The typed wrap runs about four seconds of keys, then settles." },
  },
  covers: ["agent-session/acpmux/MarkdownField.tsx#MarkdownField"],
  load: async () => FieldGrowthGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../composerControls.css"),
      import("../bottomStack.css"),
    ]),
  variants: {
    "typed-wrap": { props: {}, play: typeWrap, note: "Typing onto a second line, a third, and deleting it." },
    "paste-forty-lines": { props: {}, play: pasteLines, note: "Forty lines pasted at once grow to the cap." },
  },
  experiment: {
    definition: fieldGrowthMotion,
    script: [
      { name: "Type a wrap", run: typeWrap },
      { name: "Paste forty lines", run: pasteLines },
    ],
  },
});
