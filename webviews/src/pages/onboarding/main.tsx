import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockOnboardingProvider } from "./mockProvider";
import { OnboardingPage } from "./Onboarding";
import { OnboardingStore } from "./store";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

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
