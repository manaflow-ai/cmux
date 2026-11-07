// Boots the browser's Page Info bubble (`cmux-page://cmux.page-info/`), a page in the browser
// chrome's glass panel (CmuxNextBrowser PageInfoController through CmuxNextPages
// BrowserChromeWebHost). The host pushes the bubble's state on `cmux.page-info.state`; the page
// sends each control's command and the height its content needs, which places the panel.
import "../shared/desktop";
import { useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { setDocumentLanguage } from "../shared/i18n";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { PageInfoBubble } from "../../browser-chrome/page-info/PageInfoBubble";
import type { PageInfoCommand, PageInfoModel } from "../../browser-chrome/page-info/model";
import { pageInfoStrings } from "../../browser-chrome/page-info/strings";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

export function mountPageInfoPage(root: HTMLElement, client: PageClient): () => void {
  let model: PageInfoModel | null = null;
  const listeners = new Set<() => void>();
  const store = {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    get: () => model,
  };
  const unsubscribe = client.subscribe<PageInfoModel>("cmux.page-info.state", (next) => {
    model = next;
    for (const listener of listeners) listener();
  });
  const send = (command: PageInfoCommand) => void client.call("cmux.page-info.command", command);
  // Every content height goes to the host, which grows or shrinks the panel in place.
  let reported = 0;
  const sizes = new ResizeObserver(() => {
    const height = Math.ceil(root.getBoundingClientRect().height);
    if (height === 0 || height === reported) return;
    reported = height;
    void client.call("cmux.page-info.size", { height });
  });
  sizes.observe(root);

  const strings = pageInfoStrings();
  setDocumentLanguage(strings.language);
  function Bubble() {
    const current = useSyncExternalStore(store.subscribe, store.get);
    return current ? <PageInfoBubble model={current} onCommand={send} strings={strings} /> : null;
  }
  const react = createRoot(root);
  react.render(
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <Bubble />
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
if (root && client && document.documentElement.dataset.cmuxPage === "page-info") mountPageInfoPage(root, client);
