// The real Settings page with N shared links, keys or library entries (`#card=shares&n=10000`, or
// `card=keys`, `card=library`), for
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
import { KEYS_KEY, LIBRARY_KEY, SHARES_KEY } from "../../src/pages/settings/sectionQueries";
import { mockLongLibrary, runLibrary } from "../../src/pages/settings/mockLibrary";
import { SettingsStore } from "../../src/pages/settings/store";
import { installCatalog, setLocale } from "../../src/pages/settings/strings";
import { manyKeys, manyShares } from "../support/settingsCardFixtures";
import { rowPropsRenders } from "../support/rowPropsRenders";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowSelector: string;
    benchRowRenders: { mark(): void; since(): number };
    /** Changes the `index`th row's share or key and has the page read the list again. Other
     * harnesses declare it returning void (one global Window), so this one's promise is optional. */
    benchChangeOne(index: number): Promise<void> | void;
  }
}

const params = new URLSearchParams(location.hash.slice(1));
// `card=search`: no list, the General page, for the search bench (its rows are the result slots).
const card = (["keys", "library", "search"] as const).find((name) => name === params.get("card")) ?? "shares";
const n = Number(params.get("n") ?? 1000);
const NOW = Date.now();

installCatalog(strings as Record<string, Record<string, string>>);
setLocale("en");
document.documentElement.dataset.settingsLook = "refined";
const { client, provider } = createMockClient();
if (card === "keys") provider.keys = manyKeys(n, NOW);
else if (card === "library") provider.library = mockLongLibrary(n);
else provider.shares = manyShares(n, NOW);
// The route the page reads: the card's section, or (`reveal=1`) the card's deep link.
const reveal = params.get("reveal") === "1";
location.hash = {
  keys: "#/settings/keys",
  library: reveal ? "#/settings/personalization?focus=card.customizeLibrary" : "#/settings/personalization",
  search: "#/settings/general",
  shares: reveal ? "#/settings/privacy?focus=card.sharedLinks" : "#/settings/privacy",
}[card];
const store = new SettingsStore(client);
createRoot(document.getElementById("root")!).render(<SettingsPage store={store} />);
window.benchRowSelector = {
  keys: '[data-card="keys"] [data-key]',
  library: '[data-card="customizeLibrary"] [data-library-entry]',
  search: "[data-search-results] .rows > .collapse",
  shares: '[data-card="sharedLinks"] [data-shared-link]',
}[card];
window.benchRowRenders = rowPropsRenders(() => document.querySelectorAll(window.benchRowSelector));
window.benchChangeOne = async (index) => {
  if (card === "library") {
    const entry = provider.library.entries[index]!;
    provider.library = runLibrary(provider.library, { verb: entry.on ? "off" : "on", name: entry.name })!;
    await store.queryClient.invalidateQueries({ queryKey: LIBRARY_KEY });
  } else if (card === "keys") {
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
