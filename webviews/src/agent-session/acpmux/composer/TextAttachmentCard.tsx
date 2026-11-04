// A text attachment's chip as a small page of its text, as Claude and ChatGPT draw a long paste: its
// first lines in small monospace, left-aligned from the top and fading out at the bottom, over one
// quiet label (what it is and its line count). The strip (attachmentIntake.tsx AttachmentChip) and
// the prompt's inline chip (inlineAttachments.tsx) draw this one body inside their own button.
// Leo, 2026-11-01: "bro this is a TERRIBLE text preview we need to do better for these text type
// attachments' previews" (the inline chip drew the paste's first words large, centred, underlined
// and clipped). Gallery: agent-pane.text-attachment-card.
import React from "react";

/// The most lines a card can show (the strip's 64 px card shows three, the prompt's 48 px two).
export const TEXT_CARD_LINES = 4;
/// The most characters of one line the card keeps; the card is narrower than this at 11 px.
export const TEXT_CARD_LINE_CHARS = 120;

/// The first `lines` lines of `text` as the card draws them: leading blank lines skipped, each line
/// cut to `chars` and its trailing space dropped. Reads only as far as it needs, so a paste of a
/// megabyte costs the card no more than a short one.
export function textPreview(text: string, lines = TEXT_CARD_LINES, chars = TEXT_CARD_LINE_CHARS): string {
  const out: string[] = [];
  let at = 0;
  while (at < text.length && out.length < lines) {
    const end = text.indexOf("\n", at);
    const stop = end === -1 ? text.length : end;
    const line = text.slice(at, Math.min(stop, at + chars)).replace(/\s+$/, "");
    if (out.length || line.trim()) out.push(line);
    at = stop + 1;
  }
  return out.join("\n");
}

/// The card's body: the preview lines and the label under them. Its host (a button or a span)
/// carries the chip's box, its click and its accessible name.
export function TextAttachmentCard({ text, label }: { text: string; label: string }) {
  return (
    <>
      <span className="acpmux-text-card__lines" aria-hidden="true" dir="auto">
        {textPreview(text)}
      </span>
      <span className="acpmux-text-card__label">{label}</span>
    </>
  );
}
