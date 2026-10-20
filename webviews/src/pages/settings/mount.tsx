// Mounts the Settings page on a page client. The locale is the document's language (set by
// the page host) or the browser's; the theme comes from the one web theme (--cmux-*); the
// route comes from the URL fragment (#/settings/<section>?focus=<key>).
import { createRoot } from "react-dom/client";
import { SettingsPage } from "./components/SettingsPage";
import type { SettingsClient } from "./ops";
import { SettingsStore } from "./store";
import { setLocale, t } from "./strings";

/** Renders the page and starts its store; the returned function unmounts both. */
export async function mountSettingsPage(root: HTMLElement, client: SettingsClient): Promise<() => void> {
  setLocale(document.documentElement.lang || navigator.language);
  // The one look (refined.css over layout.css): section nav, grouped cards, the app drawn as an
  // illustration in the Theme preview (Lucas #21120; the only look, Lawrence 2026-10-16).
  document.documentElement.dataset.settingsLook = "refined";
  document.title = t("settingsPage.title");
  const store = new SettingsStore(client);
  const reactRoot = createRoot(root);
  reactRoot.render(<SettingsPage store={store} />);
  await store.start();
  return () => {
    reactRoot.unmount();
    store.dispose();
  };
}
