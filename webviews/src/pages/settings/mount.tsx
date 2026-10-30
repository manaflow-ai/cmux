// Mounts the Settings page on a page client. The locale is the document's language (set by
// the page host) or the browser's; the theme comes from the one web theme (--cmux-*); the
// route comes from the URL fragment (#/settings/<section>?focus=<key>).
import { createRoot } from "react-dom/client";
import { SettingsPage } from "./components/SettingsPage";
import type { SettingsClient } from "./ops";
import { parseLocation } from "./router";
import { ensureSection } from "./sectionQueries";
import { SettingsStore } from "./store";
import { setLocale, t } from "./strings";
import { holdPaintUntil } from "../shared/paintGate";
import { PARKED_NAME } from "../shared/pageClient";
import { setHarnessSymbolHost } from "../../agent-session/shared/harnessIcons";

/** A pooled document the host has not claimed yet (pageClient.ts). */
const parked = () => (globalThis as Record<string, unknown>)[PARKED_NAME] === true;

/** Renders the page and starts its store; the returned function unmounts both. */
export async function mountSettingsPage(root: HTMLElement, client: SettingsClient): Promise<() => void> {
  setLocale(document.documentElement.lang || navigator.language);
  // The one look (refined.css over layout.css): section nav, grouped cards, the app drawn as an
  // illustration in the Theme preview (Lucas #21120; the only look, Lawrence 2026-10-16).
  document.documentElement.dataset.settingsLook = "refined";
  document.title = t("settingsPage.title");
  const store = new SettingsStore(client);
  // A custom harness's SF Symbol icon: the host draws it (`agents.run {action: "symbol"}`).
  setHarnessSymbolHost(async (name) => {
    const reply = await store.runAgents({ action: "symbol", name });
    const src = reply.ok ? (reply.value as { src?: unknown } | null)?.src : undefined;
    return typeof src === "string" ? src : null;
  });
  const reactRoot = createRoot(root);
  reactRoot.render(<SettingsPage store={store} />);
  const started = store.start();
  // The host shows the page once its first screen is in: the user's values (no control drawn
  // disabled with its default), the host's lists (no card added after the first frame) and the
  // reads of the section the route opens on (its route's loader draws nothing before them). The
  // route is read when the host claims the page, which may route it first.
  const opening = () =>
    ensureSection(store.queryClient, store, parseLocation(location.hash.replace(/^#/, "") || "/").section);
  holdPaintUntil(() => Promise.all([started, opening()]), parked());
  await started;
  return () => {
    reactRoot.unmount();
    store.dispose();
  };
}
