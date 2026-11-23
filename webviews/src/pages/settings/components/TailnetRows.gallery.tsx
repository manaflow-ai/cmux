// l10n-allow-file: gallery fixtures (sample tailnet names and addresses), not shipped UI.
// This Mac on Your Tailnet's layouts, side by side for the pick (rulebook: more than two versions in the
// gallery). Shipped: `row`. It keeps Settings' one row shape (title over a muted detail line, one trailing
// control column, design/settings.md "Columns"), the Server card's own shape right above it; `stacked`
// puts the buttons under the detail on the title's column, which breaks the card's one control edge;
// `split` gives the actions a row of their own, a second row with no title for one state.
import { componentEntry } from "../../../gallery/format";
import { tailnetView } from "../tailnet";
import type { TailnetLayout } from "./TailnetCard";

type Props = { layout: TailnetLayout };

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { TailnetRows } = await import("./TailnetCard");
  const states = [
    tailnetView({ state: "stopped" }),
    tailnetView({ state: "needs_login", browse_to_url: "https://login.tailscale.com/a/1a2b3c4d5e" }),
    tailnetView({ state: "running", dns_name: "studio-mac.tail1234.ts.net", ips: ["100.101.102.103"] }),
  ];
  return function TailnetLayouts({ layout }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        {states.map((view) => (
          <section key={view.kind} className="group" data-card="tailnet">
            <div className="rows">
              <TailnetRows view={view} busy={false} onStep={() => {}} layout={layout} />
            </div>
          </section>
        ))}
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.tailnet-layouts",
  title: "This Mac on Your Tailnet layouts",
  area: "Settings",
  height: 420,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/TailnetCard.tsx#TailnetRows"],
  load,
  styles: () => import("../page.css"),
  variants: {
    row: {
      note: "Shipped: the state over its detail, the actions on the card's trailing edge.",
      props: { layout: "row" },
    },
    stacked: { note: "The actions under the detail, on the title's column.", props: { layout: "stacked" } },
    split: { note: "The actions on a row of their own under the state.", props: { layout: "split" } },
  },
});
