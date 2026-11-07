// Boots Page Info's certificate viewer window (`cmux-page://cmux.certificate/`), the content of a
// native window CmuxNextBrowser's PageInfoWindows owns, through CmuxNextPages BrowserChromeWebHost.
// The host pushes the window's state on `cmux.certificate.state`; the page sends its commands and
// the height its content needs, which sizes the window.
import "../shared/desktop";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { mountChromePage } from "../../browser-chrome/page-info/mountChromePage";
import { CertificateViewer } from "../../browser-chrome/page-info/CertificateViewer";
import type { PageInfoWindowCommand, CertificateState } from "../../browser-chrome/page-info/windows";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

export function mountCertificateViewerPage(root: HTMLElement, client: PageClient): () => void {
  return mountChromePage<CertificateState, PageInfoWindowCommand>(root, client, {
    page: "certificate",
    render: (state, send, strings) => <CertificateViewer state={state} onCommand={send} strings={strings} />,
  });
}

const root = document.getElementById("root");
const client = createPageClient();
if (root && client && document.documentElement.dataset.cmuxPage === "certificate")
  mountCertificateViewerPage(root, client);
