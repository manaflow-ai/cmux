// Boots the browser's Import Cookies card (`cmux-page://cmux.cookie-import/`), a page inside the
// card's native glass at the bottom of a browser page (CmuxNextBrowser BrowserCookieImportCard
// through CmuxNextPages BrowserChromeWebHost). The host pushes the card's lines on
// `cmux.cookie-import.state`; the page sends the person's answer and the height its content needs
// at the host's width, which sizes the card.
import "../shared/desktop";
import { useLayoutEffect, useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { CookieImportCard } from "../../browser-chrome/cookie-import/CookieImportCard";
import {
  APP_COOKIE_IMPORT_LOOK,
  cookieImportModel,
  type CookieImportCardModel,
  type CookieImportCommand,
} from "../../browser-chrome/cookie-import/model";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

/** The host's state: the card's lines, the number of this push and the app's language. */
type HostState = { model: CookieImportCardModel; revision: number; language: string };

function hostState(raw: unknown): HostState | null {
  const model = cookieImportModel(raw);
  if (!model || !raw || typeof raw !== "object") return null;
  const value = raw as Record<string, unknown>;
  const revision = typeof value.revision === "number" ? value.revision : 0;
  const language = typeof value.language === "string" && value.language ? value.language : "en";
  return { model, revision, language };
}

export function mountCookieImportPage(root: HTMLElement, client: PageClient): () => void {
  let state: HostState | null = null;
  const listeners = new Set<() => void>();
  const store = {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    get: () => state,
  };
  const unsubscribe = client.subscribe<unknown>("cmux.cookie-import.state", (next) => {
    state = hostState(next);
    if (state) {
      document.documentElement.lang = state.language;
      document.documentElement.dir = languageDirection(state.language);
    }
    for (const listener of listeners) listener();
  });
  const send = (command: CookieImportCommand, revision: number) =>
    void client.call("cmux.cookie-import.command", { ...command, revision });
  // The host sizes the card from the height of each state it pushed, and again when the width it
  // gave changes the wrapping (a pane resize).
  const report = () => {
    const height = Math.ceil(root.getBoundingClientRect().height);
    if (height > 0 && state) void client.call("cmux.cookie-import.size", { height, revision: state.revision });
  };
  const sizes = new ResizeObserver(report);
  sizes.observe(root);

  function Card() {
    const current = useSyncExternalStore(store.subscribe, store.get);
    useLayoutEffect(() => {
      if (current) report();
    }, [current]);
    return current ? (
      <CookieImportCard
        model={current.model}
        look={APP_COOKIE_IMPORT_LOOK}
        onChoice={(command) => send(command, current.revision)}
        glass={false}
      />
    ) : null;
  }
  const react = createRoot(root);
  react.render(
    <UiProvider container={root} dir={languageDirection(document.documentElement.lang || "en")}>
      <Card />
    </UiProvider>,
  );
  return () => {
    sizes.disconnect();
    void unsubscribe.then((stop) => stop());
    react.unmount();
  };
}

const root = document.getElementById("root");
const client = createPageClient();
if (root && client && document.documentElement.dataset.cmuxPage === "cookie-import")
  mountCookieImportPage(root, client);
