// l10n-allow-file: gallery fixtures (sample accounts), not shipped UI.
// Connectors' layouts, side by side for the pick (rulebook: more than two versions in the gallery).
// Shipped: `grouped`. It keeps Settings' one row shape (mark, name over one detail line, one
// trailing control; design/settings.md "Columns") and answers the two questions in order, what is
// connected and what else can be, like Claude's Manage and Browse connectors. `catalog` mixes both
// in one provider list, so a connection's account and sharing read like a provider's description;
// `tiles` (a connector gallery of cards) spends a card per provider and breaks the page's one text
// column and one control edge.
import { componentEntry } from "../../../gallery/format";
import { connectorRows } from "../connectors";
import { mockConnectors } from "../mockProvider";
import type { ConnectorsLayout } from "./ConnectorsCard";

type Props = { layout: ConnectorsLayout };

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { ConnectorsList } = await import("./ConnectorsCard");
  const rows = connectorRows(mockConnectors());
  return function ConnectorsLayouts({ layout }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <section className="group" data-card="connectors">
          <div className="rows">
            <ConnectorsList
              connected={rows.connected}
              available={rows.available}
              team
              busy={false}
              onConnect={() => {}}
              onDisconnect={() => {}}
              layout={layout}
            />
          </div>
        </section>
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.connectors-layouts",
  title: "Connectors layouts",
  area: "Settings",
  height: 520,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/ConnectorsCard.tsx#ConnectorsList"],
  load,
  styles: () => import("../page.css"),
  variants: {
    grouped: {
      note: "Shipped: Connected (account, who may use it, anything it waits on), then Available with Connect.",
      props: { layout: "grouped" },
    },
    catalog: { note: "One row per provider: its connection, else its Connect.", props: { layout: "catalog" } },
    tiles: { note: "Tiles: a card per provider in a grid.", props: { layout: "tiles" } },
  },
});
