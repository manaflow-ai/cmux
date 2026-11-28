import type { SenderIconCorner } from "./senderIconLook";

/// The badge's side for a slot of `size` px, and how far it hangs past the slot's corner.
export function badgeGeometry(size: number): { badge: number; overhang: number } {
  const badge = Math.max(6, Math.round(size * 0.58));
  return { badge, overhang: Math.round(badge * 0.25) };
}

/// The mask that cuts the big glyph under the badge, a ring 1 px wider than the badge.
export function badgeCut(size: number, corner: SenderIconCorner): string {
  const { badge, overhang } = badgeGeometry(size);
  const right = corner.endsWith("right");
  const bottom = corner.startsWith("bottom");
  const cx = right ? size + overhang - badge / 2 : badge / 2 - overhang;
  const cy = bottom ? size + overhang - badge / 2 : badge / 2 - overhang;
  const r = badge / 2 + 1;
  // l10n-allow: a CSS mask value, never shown as text.
  return `radial-gradient(circle at ${cx}px ${cy}px, transparent ${r}px, #000 ${r + 0.5}px)`; // colour-allow: the mask's opaque stop, never drawn as a colour
}
