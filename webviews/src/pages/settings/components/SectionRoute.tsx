import { useParams, useSearch } from "@tanstack/react-router";
import { shownSection } from "../categories";
import { useSettingsState } from "../context";
import { routeSection } from "../sectionQueries";
import { SectionView } from "./SectionView";

/**
 * A section route's component (and its pending component): the category the path or the focused
 * key names. Its loader has put the cards' host reads in the cache, so it draws complete. A
 * DEV-only category (Development) opens the default category outside DEV builds, however it was
 * reached, and then the focused key is dropped.
 */
export function SectionRoute() {
  const { section } = useParams({ strict: false }) as { section?: string };
  const search = useSearch({ strict: false }) as { focus?: string; workspace?: string };
  const state = useSettingsState();
  const routed = routeSection(section, search.focus);
  const shown = shownSection(routed, state.host?.dev_build === true);
  const focus = shown === routed ? (search.focus ?? null) : null;
  return <SectionView key={shown} section={shown} focus={focus} workspace={search.workspace ?? null} />;
}
