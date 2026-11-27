import "../shared/desktop";
import "../shared/transientMaterial";
import { createRoot } from "react-dom/client";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { renderLocalized } from "../shared/localizedRoot";
import type { StringTable } from "../shared/i18n";
import { MockOnboardingProvider } from "./mockProvider";
import { OnboardingPage } from "./Onboarding";
import { OnboardingStore } from "./store";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";
import "./walkArms.css";

// The page's strings. As shipped (build-pages-web.sh SPLIT_STRINGS), the head's locales/<locale>.js
// scripts have already put English and the app's language in `__cmuxStrings`, so the 21-locale
// table (about 470 KB, most of a first launch's startup JS) is not in app.js. The dev server, tests
// and a shipped page whose locale script failed load the whole table as a chunk of its own.
const shipped = (globalThis as { __cmuxStrings?: StringTable }).__cmuxStrings;
const table: StringTable = shipped?.en ? shipped : ((await import("./generated/strings.json")).default as StringTable);

export function mountOnboarding(root: HTMLElement, client: PageClient | null = defaultClient()): OnboardingStore {
  const store = new OnboardingStore(client);
  renderLocalized(createRoot(root), table, (strings) => (
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <OnboardingPage store={store} strings={strings} />
    </UiProvider>
  ));
  void store.start();
  return store;
}

/** `?mock` (optionally `?mock=importData` or `?mock=computerUse`) runs the page on fixtures. */
function defaultClient(): PageClient | null {
  const params = new URLSearchParams(location.search);
  return createPageClient(
    params.has("mock") ? () => new MockOnboardingProvider(params.get("mock") || "agents") : undefined,
  );
}
const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "onboarding") mountOnboarding(root);
