// l10n-allow-file: public synthetic paste and prompt text in gallery fixtures.
// An oversized paste's chip in the composer (PastedTextChip.tsx), in the three designs compared for
// Leo's ask (2026-11-08): "this is really ugly and bad and normally in chatgpt you can just click it
// to expand or smth and maybe in claude you see it in a viewer?". Each design shows its closed chip
// (in the strip and placed in the prompt), its opened state with Keep as .txt inside it, and its
// transition stopped half way:
// - `sheet` (ships): the compact row (page glyph, first words, label) opens a viewer sheet.
// - `expand`: the same row grows a panel under itself with the text and its actions.
// - `tile`: a tile of the glyph and the name over its size, no words, opening the same sheet.
// The narrow width shows the label dropping its size, then its line count, never cutting a word.
import React from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerAttachment } from "../attachments";
import type { PasteChipDesign } from "./pastedTextChipModel";

type State = "closed" | "open" | "opening";
type Props = { design: PasteChipDesign; state: State };

/// A long build log, past the composer's chip limit (pastedText.ts): 322 lines, about 22K characters.
const LOG = [
  "Ran a command, read a file",
  "$ bun run build --filter webviews",
  ...Array.from(
    { length: 320 },
    (_, index) => `[build] step ${index + 1}: compiled module ${index + 1} of 320 (src/module-${index + 1}.ts)`,
  ),
].join("\n");

const PASTE: ComposerAttachment = {
  id: "paste",
  kind: "pasted",
  name: "Ran a command, read a file",
  mimeType: "text/plain",
  size: LOG.length,
  text: LOG,
};

/// The face of the chip placed in the prompt.
const INLINE_FACE = ".acpmux-md-inline-chip.acpmux-paste-chip .acpmux-paste-chip__face";

/// Opens the prompt's chip with a click and waits for its opened view, Keep as .txt in it.
async function open(ctx: PlayContext, design: PasteChipDesign) {
  await ctx.click({ selector: INLINE_FACE });
  const view =
    design === "expand" ? ".acpmux-md-inline-chip[data-open] .acpmux-paste-chip__panel" : ".acpmux-paste-view";
  await ctx.waitFor(() => ctx.document.querySelector(`${view} .acpmux-attachment-keep-file`));
  // The opened state is its end state: the move in is over.
  await ctx.waitFor(() => ctx.document.getAnimations().every((animation) => animation.playState !== "running"));
  if (!ctx.find({ selector: view }).textContent?.includes("step 320: compiled module 320"))
    throw new Error("the opened chip must show the whole paste, its last line too");
}

/// Opens the chip and stops every running transition half way, to show the move between the states.
async function opening(ctx: PlayContext, design: PasteChipDesign) {
  // The element's own click: the play's `click` resolves only once the page settles, the transition
  // over by then.
  (ctx.find({ selector: INLINE_FACE }) as HTMLElement).click();
  await ctx.waitFor(() => ctx.document.getAnimations().some((animation) => animation.playState === "running"));
  for (const animation of ctx.document.getAnimations()) {
    animation.pause();
    const total = Number(animation.effect?.getComputedTiming().duration ?? 0);
    animation.currentTime = total / 2;
  }
  if (design !== "expand" && !ctx.document.querySelector(".acpmux-paste-view"))
    throw new Error("the sheet must be on its way in");
}

const play = (design: PasteChipDesign, state: State) =>
  state === "closed" ? undefined : (ctx: PlayContext) => (state === "open" ? open(ctx, design) : opening(ctx, design));

const NOTES: Record<PasteChipDesign, string> = {
  sheet: "Ships: a compact row (page glyph, first words, label) that opens the whole text in a viewer sheet.",
  expand: "The same row, opening a panel under itself in the composer with the text and its actions.",
  tile: "A tile of the glyph and the name over its size, no words, opening the same viewer sheet.",
};
const STATES: Record<State, string> = {
  closed: "closed, in the strip and in the prompt",
  open: "opened by a click: the whole text, Edit in Prompt and Keep as .txt inside",
  opening: "its open transition stopped half way",
};

/// One state of the gallery: what it shows, its props, the stage's height and its steps.
type Variant = { note: string; props: Props; height?: number; play?: (ctx: PlayContext) => Promise<void> };

const variants: Record<string, Variant> = Object.fromEntries(
  (["sheet", "expand", "tile"] as const).flatMap((design) =>
    (["closed", "open", "opening"] as const).map((state) => {
      const run = play(design, state);
      return [
        state === "closed" ? design : `${design}-${state}`,
        { note: `${NOTES[design]} State: ${STATES[state]}.`, props: { design, state }, ...(run ? { play: run } : {}) },
      ];
    }),
  ),
);

/// The sheet opened in a short pane (a split, a small window): its bar and actions stay in the pane,
/// the text taking only what is left (review of #38350).
variants["sheet-open-short"] = {
  note: "Ships, opened in a 200 px pane: the bar and both actions stay in the pane, the text scrolls in what is left.",
  height: 200,
  props: { design: "sheet", state: "open" },
  play: (ctx: PlayContext) => open(ctx, "sheet"),
};

export default componentEntry<Props>({
  id: "agent-pane.composer-paste-chip",
  title: "Composer pasted text chip",
  area: "Composer",
  pane: true,
  height: 560,
  widths: { narrow: 320, normal: 640 },
  covers: ["agent-session/acpmux/composer/PastedTextChip.tsx"],
  styles: () => import("../styles.css"),
  load: () =>
    Promise.all([import("./attachmentIntake"), import("./PastedTextChip"), import("./pastedTextChipModel")]).then(
      ([{ AttachmentStrip }, { PastedTextChip }, { PasteChipDesignContext }]) =>
        function PasteChips({ design }: Props) {
          return (
            <PasteChipDesignContext.Provider value={design}>
              <div className="acpmux-shell" style={{ padding: 24, display: "block", height: "auto" }}>
                <div className="acpmux-composer">
                  <div className="acpmux-composer-box ui-glass">
                    <AttachmentStrip
                      attachments={[PASTE]}
                      onRemove={() => {}}
                      onExpand={() => {}}
                      onKeepFile={() => {}}
                    />
                    <div className="acpmux-md" style={{ padding: 16 }}>
                      <p style={{ margin: 0 }}>
                        Why does the build fail?{" "}
                        <span className="acpmux-md-inline">
                          <PastedTextChip
                            host="inline"
                            text={LOG}
                            name="Pasted text"
                            accessibleName="Ran a command, read a file, Pasted text"
                            remove={null}
                            onEdit={() => {}}
                            onKeep={() => {}}
                          />
                        </span>
                      </p>
                    </div>
                  </div>
                </div>
              </div>
            </PasteChipDesignContext.Provider>
          );
        },
    ),
  variants,
});
