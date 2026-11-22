/** The × on an attachment chip's remove badge (the strip's tiles, a chip placed in the prompt, a
 *  queued prompt's image), drawn at its own size: an 8px box with an 8-unit view box, so no glyph is
 *  scaled down and its strokes end on whole device pixels at 2x. Its badge is solid and inverted
 *  (composerAttachments.css `--acpmux-remove-*`), so it reads over a thumbnail or a text card's lines
 *  (Leo, 2026-11-06: "Also this close button, this is bad clarity. Like it just is. Why is this
 *  like this?"). */
export const REMOVE_GLYPH_PX = 8;

export function RemoveGlyph() {
  return (
    <svg
      className="acpmux-remove-glyph"
      viewBox={`0 0 ${REMOVE_GLYPH_PX} ${REMOVE_GLYPH_PX}`}
      width={REMOVE_GLYPH_PX}
      height={REMOVE_GLYPH_PX}
      aria-hidden="true"
    >
      <path d="M1.5 1.5l5 5m0-5l-5 5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}
