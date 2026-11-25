// Old Settings > Personalization links. Personalization folded into Appearance (one settings area,
// David Beyer 2026-11-20: "Personalization and Settings are redundant"), so each of its old parts
// opens the page and card that draw it now. Old links still arrive from bookmarks, a host that has
// not updated, shortcuts and docs: `#/settings/personalization?part=background`,
// `?focus=personalization.chief`. The category itself is an alias of Appearance (page-layout.json
// legacy_ids). Data only, so the router reads it without importing the page's components.

/** The prefix of an old part link's focus (`personalization.background`). */
const PREFIX = "personalization.";

/** Each old part: the category that draws it now, and the focus that lands on it there. */
const PARTS: Readonly<Record<string, { section: string; focus: string | null }>> = {
  theme: { section: "appearance", focus: null },
  background: { section: "appearance", focus: "appearance.background" },
  chief: { section: "chief", focus: "card.chiefPet" },
  text: { section: "appearance", focus: "card.density" },
  sounds: { section: "notifications", focus: "notifications.sound" },
};

/** Where an old part link lands now; null for any other link. `part` is the old `?part=` param,
 * read only on the old Personalization path. */
export function legacyPart(
  section: string | undefined,
  focus: string | null | undefined,
  part?: string | null,
): { section: string; focus: string | null } | null {
  if (focus?.startsWith(PREFIX)) return PARTS[focus.slice(PREFIX.length)] ?? PARTS.theme!;
  if (section !== "personalization" || (focus && !focus.startsWith(PREFIX))) return null;
  return (part && PARTS[part]) || PARTS.theme!;
}

/** The focus a route means: an old part link's new focus, else the focus as written. */
export function routeFocus(
  section: string | undefined,
  focus: string | null | undefined,
  part?: string | null,
): string | null {
  const legacy = legacyPart(section, focus, part);
  return legacy ? legacy.focus : (focus ?? null);
}
