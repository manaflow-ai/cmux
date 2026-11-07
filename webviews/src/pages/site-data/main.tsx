// Boots Page Info's On-device site data window (`cmux-page://cmux.site-data/`), the content of a
// native window CmuxNextBrowser's PageInfoWindows owns, through CmuxNextPages BrowserChromeWebHost.
// The host pushes the window's state on `cmux.site-data.state`; the page sends its commands and the
// height its content needs, which sizes the window.
import "../shared/desktop";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { mountChromePage } from "../../browser-chrome/page-info/mountChromePage";
import { SiteDataWindow } from "../../browser-chrome/page-info/SiteDataWindow";
import type { PageInfoWindowCommand, SiteDataState } from "../../browser-chrome/page-info/windows";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

export function mountSiteDataWindowPage(root: HTMLElement, client: PageClient): () => void {
  return mountChromePage<SiteDataState, PageInfoWindowCommand>(root, client, {
    page: "site-data",
    render: (state, send, strings) => <SiteDataWindow state={state} onCommand={send} strings={strings} />,
  });
}

const root = document.getElementById("root");
const client = createPageClient();
if (root && client && document.documentElement.dataset.cmuxPage === "site-data") mountSiteDataWindowPage(root, client);
