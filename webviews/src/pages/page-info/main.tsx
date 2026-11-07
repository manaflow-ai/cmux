// Boots the browser's Page Info bubble (`cmux-page://cmux.page-info/`), a page in the browser
// chrome's glass panel (CmuxNextBrowser PageInfoController through CmuxNextPages
// BrowserChromeWebHost). The host pushes the bubble's state on `cmux.page-info.state`; the page
// sends each control's command and the height its content needs, which places the panel.
import "../shared/desktop";
import { useLayoutEffect, useSyncExternalStore } from "react";
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

/** The card's metrics at the app's density (PageInfoStyle), in CSS px. */
type Metrics = { width: number; row: number; rowSubtitle: number; padding: number; rowInset: number };
/** The host's state: the bubble's model, the number of this push and the card's metrics. */
type HostState = PageInfoModel & { revision: number; metrics?: Metrics };

export function mountPageInfoPage(root: HTMLElement, client: PageClient): () => void {
  let model: HostState | null = null;
  const listeners = new Set<() => void>();
  const store = {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    get: () => model,
  };
  const unsubscribe = client.subscribe<HostState>("cmux.page-info.state", (next) => {
    model = next;
    applyMetrics(next.metrics);
    for (const listener of listeners) listener();
  });
  const send = (command: PageInfoCommand) => void client.call("cmux.page-info.command", command);
  // The host places the panel from the height of each state it pushed (a reopen with the same
  // height too), and resizes an open panel when the content changes height by itself.
  const report = () => {
    const height = Math.ceil(root.getBoundingClientRect().height);
    if (height > 0 && model) void client.call("cmux.page-info.size", { height, revision: model.revision });
  };
  const sizes = new ResizeObserver(report);
  sizes.observe(root);

  const strings = pageInfoStrings();
  setDocumentLanguage(strings.language);
  function Bubble() {
    const current = useSyncExternalStore(store.subscribe, store.get);
    // After each committed state: report its height, and keep the keys in the card.
    useLayoutEffect(() => {
      if (!current) return;
      report();
      const card = root.querySelector<HTMLElement>(".pi-bubble");
      if (card && !card.contains(document.activeElement)) card.focus();
    }, [current]);
    return current ? <PageInfoBubble model={current} onCommand={send} strings={strings} glass={false} /> : null;
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

function applyMetrics(metrics: Metrics | undefined) {
  if (!metrics) return;
  const style = document.documentElement.style;
  style.setProperty("--pi-host-width", `${metrics.width}px`);
  style.setProperty("--pi-host-row", `${metrics.row}px`);
  style.setProperty("--pi-host-row-subtitle", `${metrics.rowSubtitle}px`);
  style.setProperty("--pi-host-padding", `${metrics.padding}px`);
  style.setProperty("--pi-host-row-inset", `${metrics.rowInset}px`);
}

const root = document.getElementById("root");
const client = createPageClient();
if (root && client && document.documentElement.dataset.cmuxPage === "page-info") mountPageInfoPage(root, client);
