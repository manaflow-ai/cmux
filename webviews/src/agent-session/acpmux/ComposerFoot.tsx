import React, { createContext } from "react";

/// True inside the quiet row: controls rendered here stay in the footer and never move into the box.
export const InQuietRow = createContext(false);

// The quiet row under a composer box, as Claude Code draws it (Leo 2026-10-19: "stick it to the
// bottom"): the permission mode on the left as plain text, and on the right one model button
// ("Opus 5.5  Medium", Leo 2026-10-20) and the context ring. No pill at rest; each answers the pointer with the soft pill and opens its menu
// (composerLocation.css, `.acpmux-composer-foot`). The box above keeps only +, the prompt, the mic
// and Send or Stop. The chat composer (Composer.tsx) and the New Tab page (NewTabScreen.tsx) draw
// the same row: it is the composer bar's controls (`acpmux-composer-bar`, its fit steps and chip
// states) moved out of the box.
export function ComposerFoot({
  ref,
  children,
  plain = true,
}: {
  ref?: React.Ref<HTMLDivElement>;
  children: React.ReactNode;
  plain?: boolean;
}) {
  return (
    <div ref={ref} className="acpmux-composer-bar acpmux-composer-foot" data-footer-look={plain ? "plain" : undefined}>
      <InQuietRow.Provider value={true}>{children}</InQuietRow.Provider>
    </div>
  );
}
