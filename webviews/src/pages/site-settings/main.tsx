// Boots Page Info's Site settings window (`cmux-page://cmux.site-settings/`), the content of a
// native window CmuxNextBrowser's PageInfoWindows owns, through CmuxNextPages BrowserChromeWebHost.
// The host pushes the window's state on `cmux.site-settings.state`; the page sends its commands and
// the height its content needs, which sizes the window.
import "../shared/desktop";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { mountChromePage } from "../../browser-chrome/page-info/mountChromePage";
import { SiteSettingsWindow } from "../../browser-chrome/page-info/SiteSettingsWindow";
import type { PageInfoWindowCommand, SiteSettingsState } from "../../browser-chrome/page-info/windows";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

export function mountSiteSettingsWindowPage(root: HTMLElement, client: PageClient): () => void {
  return mountChromePage<SiteSettingsState, PageInfoWindowCommand>(root, client, {
    page: "site-settings",
    render: (state, send, strings) => <SiteSettingsWindow state={state} onCommand={send} strings={strings} />,
  });
}

const root = document.getElementById("root");
const client = createPageClient();
if (root && client && document.documentElement.dataset.cmuxPage === "site-settings")
  mountSiteSettingsWindowPage(root, client);
