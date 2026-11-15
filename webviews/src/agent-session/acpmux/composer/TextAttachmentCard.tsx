// A text attachment's chip as a small page of its text, as Claude and ChatGPT draw a long paste: its
// first lines in small monospace, left-aligned from the top and fading out at the bottom, over one
// quiet label (what it is and its line count). The strip (attachmentIntake.tsx AttachmentChip) draws
// a text file's chip with it, here or placed in the prompt; an oversized paste has its own compact
// chip that opens its whole text (PastedTextChip.tsx).
// Leo, 2026-11-01: "bro this is a TERRIBLE text preview we need to do better for these text type
// attachments' previews" (the inline chip drew the paste's first words large, centred, underlined
// and clipped). A paste's card wraps its lines in the composer's font, so a long paragraph fills the
// card instead of showing its first five words, and its label gives its size in lines and characters
// (Leo, 2026-11-05: "it says pasted text one line, but there's a lot more than this ... you're
// previewing one, two, three, four, five words out of a multi-hundred-word pasted text bit").
// Gallery: agent-pane.text-attachment-card.
import { TEXT_CARD_LINES, TEXT_CARD_LINE_CHARS, TEXT_CARD_WRAP_CHARS, textPreview } from "./textAttachmentCardModel";
/// The card's body: the preview lines and the label under them. Its host (a button or a span)
/// carries the chip's box, its click and its accessible name. `wrap` (a paste's card) wraps each line
/// at the card's width in the composer's font; a file's keeps its lines as they are, in monospace.
export function TextAttachmentCard({ text, label, wrap = false }: { text: string; label: string; wrap?: boolean }) {
  return (
    <>
      <span className="acpmux-text-card__lines" aria-hidden="true" dir="auto" data-wrap={wrap ? "" : undefined}>
        {textPreview(text, TEXT_CARD_LINES, wrap ? TEXT_CARD_WRAP_CHARS : TEXT_CARD_LINE_CHARS)}
      </span>
      <span className="acpmux-text-card__foot">
        <span className="acpmux-text-card__label">{label}</span>
      </span>
    </>
  );
}
