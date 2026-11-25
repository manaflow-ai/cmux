// l10n-allow-file: gallery fixtures (sample chats and guests), not shipped UI.
// Shared Links' layouts, side by side for the pick (rulebook: more than two versions in the
// gallery). Shipped: `rows`. It keeps Settings' one row shape (title over a muted detail line, one
// trailing control column, design/settings.md "Columns"), so it reads like every other card and its
// long chat names truncate in one column; `table` (ChatGPT's Shared links) spends four columns that
// crowd at narrow widths and leave no room for who is in the chat; `compact` hides the dates and the
// guests behind a tooltip, and when a link ends is what the owner checks before revoking.
import { componentEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { mockShares } from "../mockProvider";
import { sharedLinkRows } from "../sharedLinks";
import type { SharedLinksLayout } from "./SharedLinksCard";

type Props = { layout: SharedLinksLayout };

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { SharedLinksList } = await import("./SharedLinksCard");
  const rows = sharedLinkRows(mockShares(GALLERY_NOW), GALLERY_NOW);
  return function SharedLinksLayouts({ layout }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <section className="group" data-card="sharedLinks">
          <div className="rows">
            <SharedLinksList rows={rows} now={GALLERY_NOW} busy={false} onRevoke={() => {}} layout={layout} />
          </div>
        </section>
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.shared-links-layouts",
  title: "Shared Links layouts",
  area: "Settings",
  height: 260,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/SharedLinksCard.tsx#SharedLinksList"],
  load,
  styles: () => import("../page.css"),
  variants: {
    rows: {
      note: "Shipped: the chat over one detail line (kind, shared, ends) and who is in it now.",
      props: { layout: "rows" },
    },
    table: { note: "ChatGPT-style columns: kind, shared and ends each get a column.", props: { layout: "table" } },
    compact: { note: "One line per chat; dates and guests only in the tooltip.", props: { layout: "compact" } },
  },
});
