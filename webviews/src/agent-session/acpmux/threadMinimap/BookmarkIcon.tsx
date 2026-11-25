import { Icon } from "../icons/Icon";

// The bookmark glyph the minimap's card and a prompt's row actions draw: an outline, filled when set.
export function BookmarkIcon({ filled, size = 16 }: { filled: boolean; size?: number }) {
  return <Icon name="tabgroup.save" selected={filled} size={size} />;
}
