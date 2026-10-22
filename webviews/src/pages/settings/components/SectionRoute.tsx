import { useParams, useSearch } from "@tanstack/react-router";
import { routeSection } from "../sectionQueries";
import { SectionView } from "./SectionView";

/**
 * A section route's component (and its pending component): the category the path or the focused
 * key names. Its loader has put the cards' host reads in the cache, so it draws complete.
 */
export function SectionRoute() {
  const { section } = useParams({ strict: false }) as { section?: string };
  const search = useSearch({ strict: false }) as { focus?: string; workspace?: string };
  const shown = routeSection(section, search.focus);
  return <SectionView key={shown} section={shown} focus={search.focus ?? null} workspace={search.workspace ?? null} />;
}
