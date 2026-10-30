// The card under a turn that started or mentioned a local web page (previewUrl.ts), behind the Debug
// toggle agentPane.debug.turnPreviewCards: one compact
// row with the page's address, "Load preview", "Open in tab" and "Open in"; after the reader clicks
// "Load preview", the card grows to show that address, live, at a quarter of its size. Until then
// there is no thumbnail box, so an address a turn merely mentioned costs one line. The address
// comes from reply text or shell output, which is not trusted, so the pane never requests a
// loopback page by itself: the click is the reader's consent. The
// frame takes no input, so the transcript scrolls over it; clicking it opens the page it shows.
// The address is a plain link too, which opens outside the pane where the host has no browser tab.
// A component gallery stage (`isGalleryFrame`) is the exception: it draws at its own size and takes
// input, so the reader tries the component in the chat (a live gallery frame, not a screenshot).
import { useState } from "react";
import { useT } from "../i18n";
import { Globe } from "./icons";
import { isGalleryFrame, previewFrameUrl } from "./previewUrl";
import { useSiteInfo } from "../chips/linkStore";
import { OpenInMenu } from "../previewCard/OpenInMenu";
import { redactUrlText } from "../chips/linkDisplay";

/// `onOpen` asks the host for a browser tab on `url` (`browser.open`).
export function PreviewCard({ url, onOpen }: { url: string; onOpen: (url: string) => void }) {
  const t = useT();
  const parsed = new URL(url);
  // A secret-looking query value (`?token=…`) reads as ••• (linkDisplay.ts); the link and frame keep it.
  const address = redactUrlText(`${parsed.host}${parsed.pathname === "/" ? "" : parsed.pathname}${parsed.search}`);
  // The thumbnail shows the address the head shows, and opens what it shows.
  const frame = previewFrameUrl(url);
  // A dev-server pane is itself on loopback; a frame of the pane's own origin would be the pane.
  const own = typeof location !== "undefined" && parsed.origin === location.origin;
  const [loaded, setLoaded] = useState(false);
  const live = isGalleryFrame(url);
  // The page's title and favicon, only from cmux's own browsing (D6: nothing is fetched).
  const site = useSiteInfo(url);
  const compact = own || !loaded;
  return (
    <div className="acpmux-turn-preview" data-compact={compact ? "" : undefined}>
      <div className="acpmux-turn-preview-head">
        <span className="acpmux-turn-preview-icon">
          {site?.icon ? <img src={site.icon} alt="" width={16} height={16} /> : <Globe size={16} />}
        </span>
        <a className="acpmux-turn-preview-address" href={url}>
          {site?.title ? <span className="acpmux-turn-preview-title">{site.title}</span> : null}
          {address}
        </a>
        {!own && !loaded && (
          <button
            type="button"
            className="acpmux-turn-preview-load"
            aria-label={t("preview.loadLabel", { address })}
            onClick={() => setLoaded(true)}
          >
            {t("preview.load")}
          </button>
        )}
        <button
          type="button"
          className="acpmux-review-changes"
          aria-label={t("preview.openLabel", { address })}
          onClick={() => onOpen(url)}
        >
          {t("preview.open")}
        </button>
        <OpenInMenu url={url} onOpenInPane={onOpen} />
      </div>
      {!own && loaded && live && (
        <div className="acpmux-turn-preview-frame acpmux-turn-preview-frame--live">
          <iframe src={frame} title={address} referrerPolicy="no-referrer" sandbox="allow-scripts allow-same-origin" />
        </div>
      )}
      {!own && loaded && !live && (
        <div className="acpmux-turn-preview-frame" data-interactive="" aria-hidden="true" onClick={() => onOpen(frame)}>
          <iframe
            src={frame}
            title={address}
            tabIndex={-1}
            referrerPolicy="no-referrer"
            sandbox="allow-scripts allow-same-origin"
          />
        </div>
      )}
    </div>
  );
}
