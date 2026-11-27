// Send's arrow on its own, so a page that draws only a send button (the Chief web page) need not
// load the composer's pickers for it. ComposerPickers.tsx re-exports it beside its other glyphs.

/** Send's arrow: a plain outline glyph with the mic's stroke (Leo 2026-10-21: no disc). */
export const ArrowUpIcon = () => (
  // icon-scale-allow: the composer's own 18 glyph set (ComposerPickers' Icon size), moved here unchanged
  <svg
    className="acpmux-icon"
    width={18}
    height={18}
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.25}
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
    focusable="false"
  >
    <path d="M8 14.1V1.9M2.9 7 8 1.9 13.1 7" />
  </svg>
);
