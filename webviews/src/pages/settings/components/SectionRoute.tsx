import { useParams, useSearch } from "@tanstack/react-router";
import { routeCard, shownSection } from "../categories";
import { useSettingsState } from "../context";
import type { SettingsSearch } from "../router";
import { routeSection } from "../sectionQueries";
import { routeFocus } from "../legacyLinks";
import { SectionView } from "./SectionView";

/**
 * A section route's component (and its pending component): the category the path or the focused
 * key names. Its loader has put the cards' host reads in the cache, so it draws complete. A
 * DEV-only category (Development) opens the default category outside DEV builds, however it was
 * reached, and then the focused key is dropped. A route that names a card of its category
 * (`#/settings/machines`: Accounts' Machines card) opens on that card, not the category's top. An
 * old Personalization link opens the page and card that draw its part now (legacyLinks.ts).
 */
export function SectionRoute() {
  const { section } = useParams({ strict: false }) as { section?: string };
  const search = useSearch({ strict: false }) as SettingsSearch;
  const state = useSettingsState();
  const routed = routeSection(section, search.focus);
  const shown = shownSection(routed, state.host?.dev_build === true);
  const routedFocus = routeFocus(section, search.focus);
  const focus = shown === routed ? routedFocus : null;
  const reveal = shown === routed ? routeCard(section, routedFocus, shown) : null;
  return <SectionView key={shown} section={shown} focus={focus} workspace={search.workspace ?? null} reveal={reveal} />;
}
