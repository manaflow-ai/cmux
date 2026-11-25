// Where a settings deep link lands (settingsLinks.ts): the page scrolls its target (a row, a card, a
// connection) into view and highlights it for a moment; a link that named nothing, or a connection the
// host does not draw, gets a named line at the top of the page instead of a silent guess. The landing
// hook is linkLandingModel.ts.
import { t } from "../strings";

/** The line a link that landed on nothing shows, naming what it asked for. */
export function LinkMissing({ name }: { name: string }) {
  return (
    <output className="link-missing row-help" data-link-missing={name}>
      {t("settingsPage.link.missing", name)}
    </output>
  );
}
