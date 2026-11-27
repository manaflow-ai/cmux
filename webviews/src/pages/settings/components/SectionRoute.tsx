import { useParams, useSearch } from "@tanstack/react-router";
import { LANDING_KEY, landingCategory, shownSection } from "../categories";
import { useSettingsState } from "../context";
import { valueOf } from "../store";
import type { SettingsSearch } from "../router";
import { resolveSettingsLink } from "../settingsLinks";
import { SectionView } from "./SectionView";

/**
 * A section route's component (and its pending component): where the link resolves
 * (settingsLinks.ts): the category the path, card, row, connection or focused key names. Its loader
 * has put the cards' host reads in the cache, so it draws complete. A DEV-only category
 * (Development) opens the default category outside DEV builds, however it was reached, and then the
 * focused key is dropped. A link that names a card, row or connection opens on it and highlights it;
 * a link that names nothing the page knows says so at the top of the page it opened.
 */
export function SectionRoute() {
  const { section } = useParams({ strict: false }) as { section?: string };
  const search = useSearch({ strict: false }) as SettingsSearch;
  const state = useSettingsState();
  const devBuild = state.host?.dev_build === true;
  const resolved = resolveSettingsLink(section, search.focus);
  // A bare open (no section: Cmd-comma, a Settings row) lands on the profile's page (window.settingsLanding).
  const link = section || search.focus ? resolved : { ...resolved, section: landingCategory(valueOf(state, LANDING_KEY), devBuild) };
  const shown = shownSection(link.section, devBuild);
  const same = shown === link.section;
  return (
    <SectionView
      key={shown}
      section={shown}
      focus={same ? link.focus : null}
      workspace={search.workspace ?? null}
      reveal={same ? link.card : null}
      target={same ? link.target : null}
      targetRequired={same && link.targetRequired}
      missing={link.missing}
    />
  );
}
