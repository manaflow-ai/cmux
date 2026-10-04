// Mounts the Settings page on a page client. The locale is the document's language (set by
// the page host) or the browser's; the theme comes from the one web theme (--cmux-*); the
// route comes from the URL fragment (#/settings/<section>?focus=<key>).
import { createRoot } from "react-dom/client";
import { SettingsPage } from "./components/SettingsPage";
import type { SettingsClient } from "./ops";
import { SettingsStore } from "./store";
import { setLocale, t } from "./strings";

export async function mountSettingsPage(root: HTMLElement, client: SettingsClient): Promise<SettingsStore> {
  setLocale(document.documentElement.lang || navigator.language);
  document.title = t("settingsPage.title");
  const store = new SettingsStore(client);
  createRoot(root).render(<SettingsPage store={store} />);
  await store.start();
  return store;
}
