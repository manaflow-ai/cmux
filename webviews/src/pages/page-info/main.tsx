// Boots the browser's Page Info bubble (`cmux-page://cmux.page-info/`), a page in the browser
// chrome's glass panel (CmuxNextBrowser PageInfoController through CmuxNextPages
// BrowserChromeWebHost). The host pushes the bubble's state on `cmux.page-info.state`, numbered and
// with the card's metrics; the page sends each control's command and the height of each state.
import "../shared/desktop";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { mountChromePage } from "../../browser-chrome/page-info/mountChromePage";
import { PageInfoBubble } from "../../browser-chrome/page-info/PageInfoBubble";
import type { PageInfoCommand, PageInfoModel } from "../../browser-chrome/page-info/model";
import { forgetSiteData, withLastSiteData } from "../../browser-chrome/page-info/siteDataMemory";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

/** The card's metrics at the app's density (PageInfoStyle), in CSS px. */
type Metrics = { width: number; row: number; rowSubtitle: number; padding: number; rowInset: number };
/**
 * The host's state: the bubble's model, the number of this push, the opening it belongs to (each
 * command names it, so the host drops one from an earlier opening) and the card's metrics.
 */
type HostState = PageInfoModel & { revision: number; opening: number; metrics?: Metrics };

export function mountPageInfoPage(root: HTMLElement, client: PageClient): () => void {
  return mountChromePage<HostState, PageInfoCommand & { opening: number }>(root, client, {
    page: "page-info",
    onState: (state) => applyMetrics(state.metrics),
    focus: ".pi-bubble",
    // The native panel's card is the glass; the page draws only the rows.
    // A site read in an earlier opening draws its last cookie summary while the host reads it again.
    render: (pushed, send, strings) => {
      const model = withLastSiteData(pushed);
      return (
        <PageInfoBubble
          model={model}
          onCommand={(command) => {
            // Managing the site's data can change its counts: the next opening waits for the host.
            if (command.type === "manageSiteData") forgetSiteData(model.site.displayName);
            send({ ...command, opening: model.opening });
          }}
          strings={strings}
          glass={false}
        />
      );
    },
  });
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
