// The bookmark glyph the minimap's card and a prompt's row actions draw: an outline, filled when set.
export function BookmarkIcon({ filled, size = 16 }: { filled: boolean; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
      <path
        d="M3.75 3.5a1.5 1.5 0 0 1 1.5-1.5h5.5a1.5 1.5 0 0 1 1.5 1.5v10.05a.4.4 0 0 1-.63.33L8 11.25l-3.62 2.63a.4.4 0 0 1-.63-.33Z"
        fill={filled ? "currentColor" : "none"}
        stroke="currentColor"
        strokeWidth="1.15"
        strokeLinejoin="round"
      />
    </svg>
  );
}
