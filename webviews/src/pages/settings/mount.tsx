// Mounts the Settings page on a page client. The locale is the document's language (set by
// the page host) or the browser's; the theme comes from the one web theme (--cmux-*); the
// route comes from the URL fragment (#/settings/<section>?focus=<key>).
import { createRoot } from "react-dom/client";
import { SettingsPage } from "./components/SettingsPage";
import type { SettingsClient } from "./ops";
import { SettingsStore } from "./store";
import { setLocale, t } from "./strings";

/**
 * The shipped look (layout.css): quiet, the grouped cards of macOS System Settings. "dense" (no
 * cards, hairline rows) stays a gallery variant; shipping it is this one line.
 */
export const SHIPPED_LOOK: "quiet" | "dense" = "quiet";

/** Renders the page and starts its store; the returned function unmounts both. */
export async function mountSettingsPage(root: HTMLElement, client: SettingsClient): Promise<() => void> {
  setLocale(document.documentElement.lang || navigator.language);
  // A gallery variant sets its own look first; the app takes the shipped one.
  document.documentElement.dataset.settingsLook ??= SHIPPED_LOOK;
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
