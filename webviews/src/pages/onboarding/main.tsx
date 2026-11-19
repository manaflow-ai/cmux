import "../shared/desktop";
import "../shared/transientMaterial";
import { createRoot } from "react-dom/client";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings, type StringTable } from "../shared/i18n";
import { MockOnboardingProvider } from "./mockProvider";
import { OnboardingPage } from "./Onboarding";
import { OnboardingStore } from "./store";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

// The app's page loads English and the active locale before this module (build-pages-web.sh
// SPLIT_STRINGS: locales/<locale>.js fill window.__cmuxStrings), so the first page a new user sees
// parses two small tables instead of all 21. The dev server has no locales/*.js and reads the whole
// table; the production bundle drops that branch (NODE_ENV is defined as production).
const shipped = (globalThis as { __cmuxStrings?: StringTable }).__cmuxStrings;
const table: StringTable =
  process.env.NODE_ENV !== "production" && !shipped
    ? ((await import("./generated/strings.json")).default as StringTable)
    : (shipped ?? {});

export function mountOnboarding(root: HTMLElement, client: PageClient | null = defaultClient()): OnboardingStore {
  const store = new OnboardingStore(client);
  const strings = createStrings(table);
  createRoot(root).render(
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <OnboardingPage store={store} strings={strings} />
    </UiProvider>,
  );
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
