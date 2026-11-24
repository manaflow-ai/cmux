// l10n-allow-file: bench fixture listings, not shipped UI.
// The real App Store page over N listings (`#n=10000&layout=grid`), for
// bench/apps-catalog-visible-only.bench.ts: a stand-in owner that answers `catalog.list` 200
// listings at a time (as the real one does) and lets the bench change one listing. `benchRowRenders`
// counts the catalog cards that rendered since its last mark, read from each mounted card's fiber
// (test/support/mountedRowRenders.ts), so the page carries no counter.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/apps/styles.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/apps/generated/strings.json";
import { AppsPage } from "../../src/pages/apps/AppsPage";
import { AppsStore } from "../../src/pages/apps/store";
import { AppsOps } from "../../src/pages/apps/types";
import type { WireCatalogPage, WireListing } from "../../src/pages/apps/wire";
import type { PageClient } from "../../src/pages/shared/pageClient";
import { UiProvider } from "../../src/ui/UiProvider";
import { mountedRowRenders } from "../support/mountedRowRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Renames the `index`th listing and has the page read the catalog again. */
    benchChangeListing(index: number): Promise<void>;
  }
}

const params = new URLSearchParams(location.hash.slice(1));
const n = Number(params.get("n") ?? 1000);
const layout = params.get("layout") ?? "grid";

const listings: WireListing[] = Array.from({ length: n }, (_, index) => ({
  app: `acme.tool-${index}`,
  name: `Tool ${index}`,
  summary: `Does thing ${index} for you: a short summary that runs to about two lines on a card.`,
  publisher: "Acme",
  tier: "verified",
  version: "1.0.0",
  icon: null,
  categories: ["productivity"],
  hide_only: false,
  install: null,
}));

const client = {
  async call<R>(op: string, raw: Record<string, unknown> = {}): Promise<R> {
    if (op === AppsOps.catalogList) {
      const start = Number(raw.cursor ?? 0);
      const end = Math.min(listings.length, start + Number(raw.limit ?? 200));
      return {
        listings: listings.slice(start, end).map((listing) => ({ ...listing })),
        next_cursor: end < listings.length ? String(end) : null,
        revision: 1,
      } satisfies WireCatalogPage as R;
    }
    if (op === AppsOps.installedList) return { revision: 1, apps: [] } as R;
    if (op === AppsOps.updatesList) return { revision: 1, updates: [] } as R;
    throw new Error(`unexpected ${op}`);
  },
  async subscribe() {
    return () => {};
  },
} as unknown as PageClient;

const store = new AppsStore(client, `#/discover?layout=${layout}`);
const root = document.getElementById("root")!;
const strings = createStrings(table, ["en"]);
createRoot(root).render(
  <UiProvider container={root}>
    <AppsPage store={store} strings={strings} />
  </UiProvider>,
);
const catalogCards = () => document.querySelectorAll(".apps-catalog-section:last-of-type :is(.apps-card, .apps-row)");
window.benchRowRenders = mountedRowRenders(catalogCards);
window.benchChangeListing = async (index) => {
  listings[index] = { ...listings[index]!, name: `Changed ${Date.now()}` };
  await store.reload();
};
const ready = store.subscribe(() => {
  if (store.getSnapshot().catalog.length >= n) window.benchReady = true;
});
void ready;
