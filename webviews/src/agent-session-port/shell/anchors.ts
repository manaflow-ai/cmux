// Anchor names for the anchored popovers (Popover.tsx). The control that opens a popover
// carries `anchor-name` (anchorProps); the popover names it in `position-anchor`.
import type { CSSProperties } from "react";

/**
 * Props that make an element a named anchor. `data-anchor` lets a popover find the element
 * as its `source`. CSS anchor names are document-global; one window per page uses fixed
 * names (below), repeated components prefix theirs (src/changes).
 */
export const anchorProps = (name: string, style?: CSSProperties) => ({
  "data-anchor": name,
  style: { ...style, anchorName: name } as CSSProperties,
});

/** A rail button, for the menus it opens (`--cx-rail-settings`, `--cx-rail-explore`). */
export const railAnchor = (id: string) => `--cx-rail-${id}`;

/** The sidebar title ("Codex ⌄"), for the mode menu. */
export const SIDEBAR_TITLE_ANCHOR = "--cx-sidebar-title";

/** The composer box and its chips, for the menus they open. */
export const COMPOSER_ANCHORS = {
  box: "--cx-composer",
  permission: "--cx-composer-permission",
  model: "--cx-composer-model",
} as const;
