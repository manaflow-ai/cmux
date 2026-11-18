// l10n-allow-file: gallery fixtures (Rust's golden surfaces), not shipped UI.
// The surfaces Rust (cmux-tui/crates/cmux-ui-surfaces) normalizes from the A2UI quickstart and MCP
// samples, read from its golden files as they are, drawn by the Mac card: what this page draws for
// exactly what Rust emits. One variant per sample; a sample with several surfaces draws them all.
// The handwritten looks and states are agent-pane.ui-surface (UiSurfaceCard.gallery.tsx).
// ./golden/*.json are byte-for-byte copies of cmux-tui/crates/cmux-ui-surfaces/tests/golden/*.json: CI's
// webviews checkout has nothing outside webviews/, so a page cannot import them from there. Copy them
// again when Rust's goldens change; golden/golden.test.ts checks each still reads as surfaces.
import { componentEntry } from "../../../gallery/format";
import cmuxCatalogCards from "./golden/cmux-catalog-cards.json";
import cmuxPending from "./golden/cmux-pending.json";
import contactForm from "./golden/contact_form_example.json";
import openingForm from "./golden/10-opening-form.json";
import refineSearch from "./golden/30-refine-search.json";
import homeDashboard from "./golden/60-home-dashboard.json";
import travelerForm from "./golden/70-traveler-form.json";
import restaurantCard from "./golden/restaurant-card.json";
import mcpAppFrame from "./golden/mcp-app-frame.json";
import type { UiSurfaceClient } from "./actions";
import { pendingFor } from "./fixtures";
import { readUiSurface, type UiSurface } from "./model";
import { UiSurfaceCard } from "./UiSurfaceCard";

const client: UiSurfaceClient = {
  uiSurfaceAction: async ({ actionId, values }) => pendingFor(actionId, values),
  uiSurfaceConfirm: async () => ({ sent: "agent" }),
  uiSurfaceCancel: async () => ({ ok: true }),
  uiSurfaceBridge: async () => ({}),
  openLink: () => undefined,
  draft: () => undefined,
};

/// A golden file's surfaces (`{sample, surfaces: [...]}`), read as the page reads a row's.
const surfaces = (golden: unknown): UiSurface[] =>
  ((golden as { surfaces?: unknown[] }).surfaces ?? []).flatMap((value) => readUiSurface(value) ?? []);

type Props = { golden: unknown };

function Stage({ golden }: Props) {
  return (
    <div
      className="acpmux-shell"
      data-ui-surface-fixture
      style={{ padding: 16, display: "grid", gap: 12, alignContent: "start" }}
    >
      {surfaces(golden).map((surface) => (
        <UiSurfaceCard key={surface.surfaceId} surface={surface} client={client} />
      ))}
    </div>
  );
}

const variant = (golden: unknown, note: string) => ({ note, props: { golden } });

export default componentEntry<Props>({
  id: "agent-pane.ui-surface-golden",
  title: "Agent UI surfaces: Rust goldens",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/uiSurface/model.ts#readUiSurface"],
  load: async () => Stage,
  styles: () => Promise.all([import("../styles.css"), import("../conversation/conversation.css")]),
  widths: { narrow: 380, normal: 560, wide: 760 },
  height: 720,
  variants: {
    "cmux-catalog-cards": variant(cmuxCatalogCards, "The cmux catalog: approval, review, table, chart, progress."),
    "cmux-pending": variant(
      cmuxPending,
      "A surface Rust sent with an action pending: the confirm strip from the start.",
    ),
    "travel-opening-form": variant(openingForm, "Quickstart 10-opening-form: travel widgets as fallbacks."),
    "travel-refine-search": variant(refineSearch, "Quickstart 30-refine-search."),
    "travel-home-dashboard": variant(homeDashboard, "Quickstart 60-home-dashboard: almost all fallbacks."),
    "travel-traveler-form": variant(travelerForm, "Quickstart 70-traveler-form."),
    "contact-form": variant(contactForm, "The A2UI basic catalog's contact form."),
    "restaurant-card": variant(restaurantCard, "The A2UI basic catalog's restaurant card: image alt, icon, text."),
    "mcp-app-frame": variant(
      mcpAppFrame,
      "An MCP App resource: a page with no render frame (the gallery) draws Rust's fallback root.",
    ),
  },
});
