// The GitHub glyphs of the new Cloud chat's folder chip and menu (ComposerContext, FolderPopover): the
// mark, and a private repository's lock.

import { AGENT_BRANDS } from "../shared/agentBrands.generated";

/// GitHub's mark (Primer Octicons mark-github, MIT, 16 px grid), in the text color.
export function GitHubMark({ size = 12 }: { size?: number }) {
  return (
    <svg
      className="acpmux-icon"
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="currentColor"
      aria-hidden="true"
      focusable="false"
    >
      <path d={AGENT_BRANDS.github.paths[0].d} />
    </svg>
  );
}

/// GitHub's mark as a menu glyph: the 18 px box of the folder picker's other glyphs (ComposerPickers `Icon`), the
/// mark inset so its circle (about 14.4 px) reads as large as the folder glyph's ink (about 13.7 px wide).
export function GitHubGlyph() {
  return (
    // icon-scale-allow: match the shared 18 px box of the composer folder glyph.
    <svg
      className="acpmux-icon"
      width={18}
      height={18}
      viewBox="-2 -2 20 20"
      fill="currentColor"
      aria-hidden="true"
      focusable="false"
    >
      <path d={AGENT_BRANDS.github.paths[0].d} />
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
