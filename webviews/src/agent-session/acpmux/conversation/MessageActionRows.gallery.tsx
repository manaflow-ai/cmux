// l10n-allow-file: gallery fixtures (a prompt, a reply and model names), not shipped UI.
// A prompt's action row (its age, Copy, Retry and Retry's model chevron) above a reply's footer
// (Copy, Retry and its chevron, Pin, Read aloud, its time), drawn with one button box and one glyph
// for both (conversation.css --cv-action-*). Leo, 2026-11-08: "the symbols for yours and the
// symbols for mine, the sizes are different. Like mine are a bit bigger than yours" and, of Retry's
// model chevron, "on the left side, it's too tucked in, and on the right side, it's too far away.
// We need the Goldilocks here." The variants try the space between Retry's glyph and its chevron
// (--cv-action-chevron-gap): the reply footer's old 2, then 4, 6 and the prompt row's old 12. Each
// draws the rows' button boxes outlined, so their sizes and the chevron's room read at rest; the
// pointed variant shows the shipped gap under the pointer, Retry's one hover box.
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

/// `gap`: the chevron gap tried; `boxes`: outline each button box; `sentSeconds`: the prompt's age.
type Props = { gap?: number; boxes?: boolean; sentSeconds?: number };

const models = [
  { id: "opus", name: "Opus 5.5" },
  { id: "sonnet", name: "Sonnet 5.5" },
  { id: "haiku", name: "Haiku 5.5" },
];

const prompt: AcpmuxRow = {
  id: "user-1",
  version: 1,
  at: minutesAgo(2),
  kind: "user",
  text: "Add retry with backoff to the uploader",
};

// The chat's last turn: its footer carries Retry and the model chevron (turns.ts retryTarget).
const footer: AcpmuxRow = {
  id: "summary-1",
  version: 1,
  at: minutesAgo(1),
  kind: "turnSummary",
  status: "completed",
  durationMs: 42_000,
  text: "Done: three tries, doubling from 200 ms, only on 5xx and timeouts.",
  retryable: true,
  retryTarget: true,
  prompt: prompt.text,
  retryRowId: prompt.id,
};

const pointRetry: Play = async (ctx) => {
  await ctx.hover({ selector: ".cv-user__actions .cv-message-retry > .cv-iconbtn:first-child" });
};

export default componentEntry<Props>({
  id: "agent-pane.message-action-rows",
  title: "Message action rows",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 360, normal: 520, wide: 680 },
  anchors: [{ selector: ".cv-user__actions" }, { selector: ".cv-turn-actions" }],
  covers: ["agent-session/acpmux/conversation/MessageActions.tsx"],
  load: async () => {
    const { PromptActions } = await import("./MessageActions");
    const { TurnFooter } = await import("./TurnRows");
    const { PresentationContext } = await import("./presentationContextModel");
    const { TurnActionsContext } = await import("./turnActions");
    const actions = {
      retry: () => {},
      retryWith: { models, current: "opus", harness: "Claude Code", retry: () => {} },
    };
    return function GalleryMessageActionRows({ gap, boxes, sentSeconds }: Props) {
      const sent = sentSeconds === undefined ? prompt : { ...prompt, at: GALLERY_NOW - sentSeconds * 1000 };
      const style = gap === undefined ? undefined : ({ "--cv-action-chevron-gap": `${gap}px` } as CSSProperties);
      return (
        <TurnActionsContext.Provider value={actions}>
          <div
            className={boxes ? "cv-gallery-action-rows cv-gallery-action-boxes" : "cv-gallery-action-rows"}
            style={{ padding: "16px 24px 0", ...style }}
          >
            {/* The prompt's row shows as it does under the pointer, so both rows read at once. */}
            <style>{`.cv-gallery-action-rows .cv-user__actions { opacity: 1; }`}</style>
            {boxes && (
              <style>{`.cv-gallery-action-boxes .cv-iconbtn { outline: 1px dashed color-mix(in srgb, var(--cv-text-muted) 60%, transparent); outline-offset: -1px; }`}</style>
            )}
            {/* The prompt's row keeps its Retry in the Messages view (MessageActions.tsx PromptActions). */}
            <PresentationContext.Provider value="messages">
              <div
                className="cv-user"
                style={{ position: "relative", display: "flex", flexDirection: "column", alignItems: "flex-end" }}
              >
                <div className="cv-user__body">
                  <div className="ui-glass cv-user__bubble">{prompt.text}</div>
                  <PromptActions row={sent} text={sent.text ?? ""} />
                </div>
              </div>
            </PresentationContext.Provider>
            <div style={{ height: 56 }} />
            <div
              className="acpmux-row acpmux-turnSummary acpmux-row--final-footer"
              style={{ position: "relative", insetInline: 0, contain: "layout" }}
            >
              <TurnFooter row={footer} />
            </div>
          </div>
        </TurnActionsContext.Provider>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    tight: {
      note: "2px from Retry's glyph to its chevron, the reply footer's before: the chevron reads as part of Retry's glyph.",
      props: { gap: 2, boxes: true },
    },
    snug: {
      note: "4px, Retry's own inset: the chevron sits as close to Retry as Retry's box edge, one split control with the same room on each end.",
      props: { gap: 4, boxes: true },
    },
    even: {
      note: "6px: between the two, the chevron starts to read as its own button.",
      props: { gap: 6, boxes: true },
    },
    loose: {
      note: "12px, the prompt row's before (a full 28 box for a 16 chevron): the chevron reads as a separate control.",
      props: { gap: 12, boxes: true },
    },
    pointed: {
      note: "The shipped gap, Retry under the pointer: one hover box over Retry and its chevron, 4px of room at each end.",
      props: {},
      play: pointRetry,
    },
    "just-now": {
      note: 'A prompt sent half a minute ago: "just now" in the same box "1 minute ago" takes when the minute turns, set against Copy, so nothing moves as it ticks.',
      props: { sentSeconds: 30 },
    },
  },
});
