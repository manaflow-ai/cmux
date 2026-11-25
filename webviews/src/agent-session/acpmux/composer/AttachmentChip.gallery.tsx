// l10n-allow-file: public synthetic inspector reports and prompt text in gallery fixtures.
// The content chip (ContentChip.tsx) for an inspector pick (UIPickChip.tsx), compared for Leo's ask
// (2026-11-08), after he pasted a pick's report: "i just used the inspector. i think it could be more
// ergonomic... clicking it should be able to show the raw/full thing... idk how possible it'd be to
// also be able to have a well-designed button to click to re-collapse it too. might be cool."
// - `label-*`: what the closed chip says (uiPickModel.ts UIPickLabelForm); `element-snippet` ships.
// - `collapse-*`: how the opened report folds back (ChipCollapse), each opened and half way open;
//   `footer` ships.
// - `paste-*`: a huge paste opened in the viewer sheet (ships) beside the same in-place panel.
// Each shows the chip in the strip, placed in the prompt and in a sent message, at the entry's narrow
// and normal widths, in the host's dark and light themes.
import React from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerAttachment } from "../attachments";
import type { ChipCollapse } from "./contentChipModel";
import type { PasteChipDesign } from "./pastedTextChipModel";
import type { UIPickLabelForm } from "./uiPickModel";

type State = "closed" | "open" | "opening";
type Props = { label: UIPickLabelForm; collapse: ChipCollapse; paste: PasteChipDesign | null; state: State };

const REPORT = [
  "cmux NEXT app-owned webview selection",
  "Component: span",
  "Source: unavailable",
  "Selector: .cv-li__text",
  "Text: the Cloud version-check and Cloud Desktop fixes;",
  'Computed styles: ["color": "rgb(229, 229, 229)", "display": "inline", "font-size": "14px", "line-height": "22px", "margin": "0px", "padding": "0px", "white-space": "normal"]',
  'DOM: <span class="cv-li__text">the Cloud version-check and Cloud Desktop fixes;</span>',
].join("\n");

const PICK: ComposerAttachment = {
  id: "ui-pointer-gallery",
  kind: "text",
  name: "UI: span",
  mimeType: "text/plain",
  size: REPORT.length,
  text: REPORT,
};

/// A long build log, past the composer's chip limit (pastedText.ts).
const LOG = [
  "Ran a command, read a file",
  ...Array.from({ length: 200 }, (_, index) => `[build] step ${index + 1}: compiled module ${index + 1} of 200`),
].join("\n");

/// The face of the chip placed in the prompt (the paste's, or the pick's).
const FACE = (paste: boolean) =>
  `.acpmux-md-inline-chip[data-chip-kind="${paste ? "paste" : "ui"}"] .acpmux-paste-chip__face`;

async function open(ctx: PlayContext, props: Props) {
  await ctx.click({ selector: FACE(props.paste !== null) });
  const view =
    props.paste === "sheet" ? ".acpmux-paste-view" : ".acpmux-md-inline-chip[data-open] .acpmux-paste-chip__panel";
  await ctx.waitFor(() => ctx.document.querySelector(view));
  await ctx.waitFor(() => ctx.document.getAnimations().every((animation) => animation.playState !== "running"));
  const shown = ctx.find({ selector: view }).textContent ?? "";
  if (!shown.includes(props.paste ? "step 200: compiled module 200" : "DOM: <span"))
    throw new Error("the opened chip must show its whole content, its last line too");
}

async function opening(ctx: PlayContext, props: Props) {
  (ctx.find({ selector: FACE(props.paste !== null) }) as HTMLElement).click();
  await ctx.waitFor(() => ctx.document.getAnimations().some((animation) => animation.playState === "running"));
  for (const animation of ctx.document.getAnimations()) {
    animation.pause();
    animation.currentTime = Number(animation.effect?.getComputedTiming().duration ?? 0) / 2;
  }
}

const play = (props: Props) =>
  props.state === "closed"
    ? undefined
    : (ctx: PlayContext) => (props.state === "open" ? open(ctx, props) : opening(ctx, props));

const LABELS: Record<UIPickLabelForm, string> = {
  "element-snippet":
    'Ships: the element and its text, `span · "the Cloud version-check…"`, over UI element · its selector.',
  prefixed: 'The attachment\'s own name first, `UI: span · "the Cloud…"`, over UI element · its selector.',
  "element-selector": 'The element and its selector, `span · .cv-li__text`, over UI element · "the Cloud…".',
};
const COLLAPSES: Record<ChipCollapse, string> = {
  footer: "Ships: a bar under the report with a quiet ⌃ Collapse button at its end, always in view.",
  corner: "A small Collapse pill in the report's top-right corner, the text scrolling under it.",
  chevron: "Only a chevron in the face that turns over; the face folds it back (no button of its own).",
};
const STATES: Record<State, string> = {
  closed: "closed, in the strip, in the prompt and in a sent message",
  open: "opened by a click on the prompt's chip",
  opening: "its open transition stopped half way",
};

const base: Props = { label: "element-snippet", collapse: "footer", paste: null, state: "closed" };
const variant = (props: Props, note: string) => {
  const run = play(props);
  return { note: `${note} State: ${STATES[props.state]}.`, props, ...(run ? { play: run } : {}) };
};

const variants = {
  ...Object.fromEntries(
    (["element-snippet", "prefixed", "element-selector"] as const).map((label) => [
      `label-${label}`,
      variant({ ...base, label }, LABELS[label]),
    ]),
  ),
  ...Object.fromEntries(
    (["footer", "corner", "chevron"] as const).flatMap((collapse) =>
      (["open", "opening"] as const).map((state) => [
        `collapse-${collapse}${state === "open" ? "" : `-${state}`}`,
        variant({ ...base, collapse, state }, COLLAPSES[collapse]),
      ]),
    ),
  ),
  "paste-sheet": variant(
    { ...base, paste: "sheet", state: "open" },
    "Ships for a huge paste: its chip opens the whole text in a viewer sheet, Edit in Prompt and Keep as .txt in its bar.",
  ),
  "paste-expand": variant(
    { ...base, paste: "expand", state: "open" },
    "The same paste opened in place, as a pick opens: a 200-line log in a bounded scroller, its actions and Collapse under it.",
  ),
};

export default componentEntry<Props>({
  id: "agent-pane.attachment-chip",
  title: "Composer attachment chip: inspector pick",
  area: "Composer",
  pane: true,
  height: 640,
  widths: { narrow: 320, normal: 640 },
  covers: [
    "agent-session/acpmux/composer/ContentChip.tsx",
    "agent-session/acpmux/composer/UIPickChip.tsx",
    "agent-session/acpmux/conversation/SentUIPick.tsx",
  ],
  styles: () => Promise.all([import("../styles.css"), import("../conversation/conversation.css")]),
  load: () =>
    Promise.all([
      import("./attachmentIntake"),
      import("./PastedTextChip"),
      import("./UIPickChip"),
      import("./pastedTextChipModel"),
      import("./uiPickModel"),
      import("../conversation/PromptText"),
      import("../attachments"),
    ]).then(
      ([
        { AttachmentStrip },
        { PastedTextChip },
        { UIPickChip },
        { PasteChipDesignContext },
        { UIPickDesignContext },
        { PromptTyped },
        { promptText },
      ]) =>
        function AttachmentChips({ label, collapse, paste }: Props) {
          const sent = promptText("Why is this list item cut off?", [PICK]);
          return (
            <UIPickDesignContext.Provider value={{ label, collapse }}>
              <PasteChipDesignContext.Provider value={paste ?? "sheet"}>
                <div className="acpmux-shell" style={{ padding: 24, display: "block", height: "auto" }}>
                  {paste ? null : (
                    <div className="cv-user" style={{ marginBottom: 16 }}>
                      <div className="ui-glass cv-user__bubble">
                        <div className="cv-user__text">
                          <PromptTyped text={sent} show={(text) => text} />
                        </div>
                      </div>
                    </div>
                  )}
                  <div className="acpmux-composer">
                    <div className="acpmux-composer-box ui-glass">
                      <AttachmentStrip attachments={paste ? [] : [PICK]} onRemove={() => {}} onExpand={() => {}} />
                      <div className="acpmux-md" style={{ padding: 16 }}>
                        <p style={{ margin: 0 }}>
                          {paste ? "Why does the build fail? " : "Why is this list item cut off? "}
                          <span className="acpmux-md-inline">
                            {paste ? (
                              <PastedTextChip
                                host="inline"
                                text={LOG}
                                name="Pasted text"
                                accessibleName="Ran a command, read a file, Pasted text"
                                remove={null}
                                onEdit={() => {}}
                                onKeep={() => {}}
                              />
                            ) : (
                              <UIPickChip host="inline" name={PICK.name} text={REPORT} />
                            )}
                          </span>
                        </p>
                      </div>
                    </div>
                  </div>
                </div>
              </PasteChipDesignContext.Provider>
            </UIPickDesignContext.Provider>
          );
        },
    ),
  variants,
});
