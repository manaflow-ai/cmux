// Gallery-only: the direction rows' alternatives (scripts/cmux-next/art/chief_mascot_directions.py
// `VARIANTS`), each a whole sheet of a built-in set with other look or drag rows. Nothing shipped
// imports this; the sets' own sheets carry the picks (the face turning, the shear lean). Imported
// one by one, not by a glob: Bun's scripts (the gallery's entry picker) load this module too.
import { avatarSet, type AvatarSet } from "./sets";
import mochiLookEyes from "./variants/mochi-look-eyes.png";
import mochiLookBlink from "./variants/mochi-look-blink.png";
import mochiDragOffset from "./variants/mochi-drag-offset.png";
import mochiDragSquash from "./variants/mochi-drag-squash.png";
import captainLookEyes from "./variants/captain-look-eyes.png";
import captainLookBlink from "./variants/captain-look-blink.png";
import captainDragOffset from "./variants/captain-drag-offset.png";
import captainDragSquash from "./variants/captain-drag-squash.png";
import sproutLookEyes from "./variants/sprout-look-eyes.png";
import sproutLookBlink from "./variants/sprout-look-blink.png";
import sproutDragOffset from "./variants/sprout-drag-offset.png";
import sproutDragSquash from "./variants/sprout-drag-squash.png";
import boltLookEyes from "./variants/bolt-look-eyes.png";
import boltLookBlink from "./variants/bolt-look-blink.png";
import boltDragOffset from "./variants/bolt-drag-offset.png";
import boltDragSquash from "./variants/bolt-drag-squash.png";

export const AVATAR_VARIANTS = ["look-eyes", "look-blink", "drag-offset", "drag-squash"] as const;
export type AvatarVariant = (typeof AVATAR_VARIANTS)[number];

const SHEETS: Record<string, string> = {
  "mochi-look-eyes": mochiLookEyes,
  "mochi-look-blink": mochiLookBlink,
  "mochi-drag-offset": mochiDragOffset,
  "mochi-drag-squash": mochiDragSquash,
  "captain-look-eyes": captainLookEyes,
  "captain-look-blink": captainLookBlink,
  "captain-drag-offset": captainDragOffset,
  "captain-drag-squash": captainDragSquash,
  "sprout-look-eyes": sproutLookEyes,
  "sprout-look-blink": sproutLookBlink,
  "sprout-drag-offset": sproutDragOffset,
  "sprout-drag-squash": sproutDragSquash,
  "bolt-look-eyes": boltLookEyes,
  "bolt-look-blink": boltLookBlink,
  "bolt-drag-offset": boltDragOffset,
  "bolt-drag-squash": boltDragSquash,
};

/** Set `id` drawn from variant `variant`'s sheet (same manifest and size), or undefined. */
export function variantSet(id: string, variant: AvatarVariant): AvatarSet | undefined {
  const set = avatarSet(id);
  const sheet = SHEETS[`${id}-${variant}`];
  return set && sheet ? { ...set, sheet } : undefined;
}
