// Gallery-only: the direction rows' alternatives (scripts/cmux-next/art/chief_mascot_directions.py
// `VARIANTS`), each a whole sheet of a built-in set with other look or drag rows. Nothing shipped
// imports this; the sets' own sheets carry the picks (the face turning, the shear lean).
import { avatarSet, type AvatarSet } from "./sets";

const sheets = import.meta.glob<string>("./variants/*.png", { eager: true, import: "default" });

export const AVATAR_VARIANTS = ["look-eyes", "look-blink", "drag-offset", "drag-squash"] as const;
export type AvatarVariant = (typeof AVATAR_VARIANTS)[number];

/** Set `id` drawn from variant `variant`'s sheet (same manifest and size), or undefined. */
export function variantSet(id: string, variant: AvatarVariant): AvatarSet | undefined {
  const set = avatarSet(id);
  const sheet = sheets[`./variants/${id}-${variant}.png`];
  return set && sheet ? { ...set, sheet } : undefined;
}
