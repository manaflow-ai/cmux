// l10n-allow-file: gallery fixtures (sample wishes), not shipped UI.
// "Ask cmux to do this" under a search with no match, three looks for the pick (rulebook: more than
// two versions). From the cmux-design-references: one box that turns from search into ask, and
// search results as rows in a flyout. Shipped: `row`. It reads as the one result the search did find, it shows the words
// it will send (so nothing is sent that the person did not see), and it is as wide as a result row,
// so it lines up under "No settings match.". `button` hides the words; `link` is the quietest and
// the easiest to miss, and a person who searched and found nothing is looking for a next step.
import { componentEntry } from "../../../gallery/format";
import type { AskCmuxLook } from "./AskCmuxRow";

type Props = { look: AskCmuxLook; words: string };

async function load() {
  const { installCatalog, t } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { AskCmuxRow } = await import("./AskCmuxRow");
  return function AskCmuxLooks({ look, words }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <div className="search-results">
          <div className="empty">
            <p>{t("settingsPage.noResults")}</p>
            <AskCmuxRow words={words} look={look} onAsk={() => {}} />
          </div>
        </div>
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.ask-cmux",
  title: "Search: Ask cmux to do this",
  area: "Settings",
  height: 160,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/AskCmuxRow.tsx#AskCmuxRow"],
  load,
  styles: () => import("../page.css"),
  variants: {
    row: {
      note: "Shipped: a result-wide row with the words it sends under the action.",
      props: { look: "row", words: "show my PRs in the sidebar" },
    },
    button: {
      note: "A bordered button; the words are not shown.",
      props: { look: "button", words: "show my PRs in the sidebar" },
    },
    link: {
      note: "An accent link after the empty line: quietest, easy to miss.",
      props: { look: "link", words: "show my PRs in the sidebar" },
    },
    "row-long-wish": {
      note: "Shipped look with a long wish: the words truncate on one line.",
      props: {
        look: "row",
        words: "make the sidebar compact, add a weather widget above History and use a darker theme after sunset",
      },
    },
  },
});
