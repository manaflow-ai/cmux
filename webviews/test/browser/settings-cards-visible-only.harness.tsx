// The real Settings page with N shared links or N keys (`#card=shares&n=10000`, or `card=keys`), for
// bench/settings-cards-visible-only.bench.ts: the in-memory mock host answers the card's list with
// all N, and the bench can change one row. `benchRowRenders` counts the mounted rows whose element
// React committed again since its last mark (test/support/rowPropsRenders.ts), so the page carries
// no counter.
import "../../src/pages/shared/desktop";
import "../../src/ui/ui.css";
import "../../src/pages/settings/page.css";
import "../../src/pages/settings/tailwind.css";
import { createRoot } from "react-dom/client";
import strings from "../../src/pages/settings/generated/strings.json";
import { SettingsPage } from "../../src/pages/settings/components/SettingsPage";
import { createMockClient } from "../../src/pages/settings/mockProvider";
import { KEYS_KEY, SHARES_KEY } from "../../src/pages/settings/sectionQueries";
import { SettingsStore } from "../../src/pages/settings/store";
import { installCatalog, setLocale } from "../../src/pages/settings/strings";
import { manyKeys, manyShares } from "../support/settingsCardFixtures";
import { rowPropsRenders } from "../support/rowPropsRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowSelector: string;
    benchRowRenders: { mark(): void; since(): number };
    /** Changes the `index`th row's share or key and has the page read the list again. */
    benchChangeOne(index: number): Promise<void>;
  }
}

const params = new URLSearchParams(location.hash.slice(1));
const card = params.get("card") === "keys" ? "keys" : "shares";
const n = Number(params.get("n") ?? 1000);
const NOW = Date.now();

installCatalog(strings as Record<string, Record<string, string>>);
setLocale("en");
document.documentElement.dataset.settingsLook = "refined";
const { client, provider } = createMockClient();
if (card === "keys") provider.keys = manyKeys(n, NOW);
else provider.shares = manyShares(n, NOW);
// The route the page reads: the card's section.
location.hash = card === "keys" ? "#/settings/keys" : "#/settings/privacy";
const store = new SettingsStore(client);
createRoot(document.getElementById("root")!).render(<SettingsPage store={store} />);
window.benchRowSelector =
  card === "keys" ? '[data-card="keys"] [data-key]' : '[data-card="sharedLinks"] [data-shared-link]';
window.benchRowRenders = rowPropsRenders(() => document.querySelectorAll(window.benchRowSelector));
window.benchChangeOne = async (index) => {
  if (card === "keys") {
    const keys = provider.keys.keys.map((key, at) =>
      at === index ? { ...key, uses: [{ target: `changed-${Date.now()}.example.com`, count: 1 }] } : key,
    );
    provider.keys = { ...provider.keys, keys };
    await store.queryClient.invalidateQueries({ queryKey: KEYS_KEY });
  } else {
    const shares = provider.shares.shares!.map((share, at) =>
      at === index
        ? { ...share, guests: [{ guest_id: "g", name: `Changed ${Date.now()}`, joined_at: NOW, state: "active" }] }
        : share,
    );
    provider.shares = { ...provider.shares, shares };
    await store.queryClient.invalidateQueries({ queryKey: SHARES_KEY });
  }
};
void store.start().then(() => {
  window.benchReady = true;
});
