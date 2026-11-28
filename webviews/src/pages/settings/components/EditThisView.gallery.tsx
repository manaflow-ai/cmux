// l10n-allow-file: gallery fixtures (sample section titles), not shipped UI.
// "Edit this view" beside a Settings section's title (Labs: labs.editThisView), three looks for
// the pick (rulebook: more than two versions). Shipped: `chip`. A bordered chip with the words
// says what it does before the click and sits at the title's end, where the page has room; `icon`
// is the quietest but needs a hover to read; `link` reads as navigation, not an action.
import { componentEntry } from "../../../gallery/format";
import type { EditThisViewLook } from "./EditThisView";

type Props = { look: EditThisViewLook; title: string };

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { EditThisViewButton } = await import("./EditThisView");
  return function EditThisViewLooks({ look, title }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <div className="section">
          <div className="section-head">
            <h1 className="section-title">{title}</h1>
            <EditThisViewButton look={look} onEdit={() => {}} />
          </div>
        </div>
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.edit-this-view",
  title: "Section: Edit this view",
  area: "Settings",
  height: 120,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/EditThisView.tsx#EditThisViewButton"],
  load,
  styles: () => import("../page.css"),
  variants: {
    chip: {
      note: "Shipped: a bordered chip with the words, at the end of the title row.",
      props: { look: "chip", title: "General" },
    },
    icon: {
      note: "Only the wand; its name shows on hover.",
      props: { look: "icon", title: "General" },
    },
    link: {
      note: "Accent words with no border: reads as a link.",
      props: { look: "link", title: "General" },
    },
    "chip-long-title": {
      note: "Shipped look beside a long section title.",
      props: { look: "chip", title: "Keyboard Shortcuts and Command Palette" },
    },
  },
});
