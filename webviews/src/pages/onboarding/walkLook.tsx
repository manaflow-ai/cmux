// A look tile's two faces (the intro walk, hq RFD 0057): a miniature of the whole app (titlebar with
// tabs, sidebar, a pane with a composer) drawn once light and once dark, since every look follows the
// Mac's appearance. Shared by the shipped look screen (MakeItYoursStep) and the gallery arms (walkArms).
// Draws no text. Styles: walkArms.css.

/** What a miniature draws differently per look. */
export interface WalkTraits {
  glass?: boolean;
  twoTone?: boolean;
  solid?: boolean;
  dense?: boolean;
  /** Chat as message bubbles (Codex). */
  messages?: boolean;
  /** One round composer (Codex, Studio). */
  round?: boolean;
  /** A new chat's composer in the middle of the pane (Studio). */
  centered?: boolean;
}

/** A miniature of the whole app (titlebar with tabs, sidebar, a pane with a composer) in one scheme,
 * drawn from the system's canvas colors and the theme accent, so a tile has a true light and dark
 * face on either appearance. */
export function Miniature({ bundle, face }: { bundle: { traits: WalkTraits }; face: "light" | "dark" }) {
  const t = bundle.traits;
  return (
    <span
      className="onb-walk-mini"
      data-face={face}
      data-glass={t.glass || undefined}
      data-two-tone={t.twoTone || undefined}
      data-solid={t.solid || undefined}
      data-dense={t.dense || undefined}
      data-messages={t.messages || undefined}
      data-round={t.round || undefined}
      data-centered={t.centered || undefined}
      aria-hidden="true"
    >
      <span className="onb-walk-mini-bar">
        <span className="onb-walk-mini-tab" data-active="" />
        <span className="onb-walk-mini-tab" />
        <span className="onb-walk-mini-tab" />
      </span>
      <span className="onb-walk-mini-body">
        <span className="onb-walk-mini-side">
          {Array.from({ length: t.dense ? 7 : 4 }, (_, i) => (
            <span key={i} className="onb-walk-mini-row" data-active={i === 0 || undefined} />
          ))}
        </span>
        <span className="onb-walk-mini-pane">
          <span className="onb-walk-mini-line" />
          <span className="onb-walk-mini-line" data-short="" data-mine={t.messages || undefined} />
          {t.dense && <span className="onb-walk-mini-line" />}
          <span className="onb-walk-mini-composer" />
        </span>
      </span>
    </span>
  );
}

/** A bundle's two faces, light beside dark. */
export function Faces({ bundle }: { bundle: { traits: WalkTraits } }) {
  return (
    <span className="onb-walk-faces">
      <Miniature bundle={bundle} face="light" />
      <Miniature bundle={bundle} face="dark" />
    </span>
  );
}
