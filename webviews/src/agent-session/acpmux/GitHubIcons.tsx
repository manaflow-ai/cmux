// The GitHub glyphs of the new Cloud chat's folder chip and menu (ComposerContext, FolderPopover): the
// mark, and a private repository's lock.

/// GitHub's mark (Primer Octicons mark-github, MIT, 16 px grid), in the text color.
/// `chip`: the mark as the folder chip's face, in the folder icon's own box (the location strip's glyph,
/// which grows with the density, on the icon column). It stayed a fixed 12 px beside a laptop and a
/// folder that scale, off their column (2026-11-23: the GitHub icon, This Mac's laptop and the
/// chevrons "look like different sizes"). Its solid disc fills its box, so it draws at three quarters
/// of the box: the ink footprint of the folder and the laptop (test/newtab-chip-icon-sizes.test.ts).
export function GitHubMark({ size = 12, chip = false }: { size?: number; chip?: boolean }) {
  return (
    <svg
      className={chip ? "acpmux-icon acpmux-location-icon ui-ghost-icon" : "acpmux-icon"}
      data-github-mark={chip ? "" : undefined}
      width={size}
      height={size}
      viewBox={chip ? "-2.6667 -2.6667 21.3333 21.3333" : "0 0 16 16"}
      fill="currentColor"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}

/// A private repository's lock, drawn as the folder menu's other glyphs are.
export function LockIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <rect x="3.5" y="7" width="9" height="6.5" rx="1.5" />
      <path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2" />
    </svg>
  );
}
