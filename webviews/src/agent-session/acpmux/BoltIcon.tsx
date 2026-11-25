/// The composer's bolt glyph (FastToggle.tsx draws the same one for Codex's speed toggle): the `/`
/// menu's Fast row (Composer.tsx SlashMenu) shows it beside the plain name Fast, in the row's ink.
export function BoltIcon({ size = 16 }: { size?: number }) {
  return (
    <svg
      className="acpmux-icon"
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M9.2 1.5 3.6 9h4.1l-1 5.5L12.4 7H8.3Z" />
    </svg>
  );
}
