// The card under a turn that started or mentioned a local web page (previewUrl.ts): the page's
// address, "Open in tab", and the page's root, live, at a quarter of its size (the frame loads
// without a click, so never the path or query the transcript named). The frame takes no
// input, so the transcript scrolls over it; clicking it opens the root it shows. The
// address is a plain link too, which opens outside the pane where the host has no browser tab.
import { useT } from "../i18n";
import { Globe } from "./icons";
import { previewFrameUrl } from "./previewUrl";

/// `onOpen` asks the host for a browser tab on `url` (`browser.open`).
export function PreviewCard({ url, onOpen }: { url: string; onOpen: (url: string) => void }) {
  const t = useT();
  const parsed = new URL(url);
  const address = `${parsed.host}${parsed.pathname === "/" ? "" : parsed.pathname}${parsed.search}`;
  // The thumbnail shows the root and opens what it shows; the full address opens from the head,
  // where the reader sees it before clicking.
  const frame = previewFrameUrl(url);
  // A dev-server pane is itself on loopback; a frame of the pane's own origin would be the pane.
  const own = typeof location !== "undefined" && parsed.origin === location.origin;
  return (
    <div className="acpmux-turn-preview">
      <div className="acpmux-turn-preview-head">
        <span className="acpmux-turn-preview-icon">
          <Globe size={16} />
        </span>
        <a className="acpmux-turn-preview-address" href={url} title={url}>
          {address}
        </a>
        <button
          type="button"
          className="acpmux-review-changes"
          aria-label={t("preview.openLabel", { address })}
          onClick={() => onOpen(url)}
        >
          {t("preview.open")}
        </button>
      </div>
      {!own && (
        <div className="acpmux-turn-preview-frame" aria-hidden="true" onClick={() => onOpen(frame)}>
          <iframe
            src={frame}
            title={address}
            tabIndex={-1}
            loading="lazy"
            referrerPolicy="no-referrer"
            sandbox="allow-scripts allow-same-origin allow-forms"
          />
        </div>
      )}
    </div>
  );
}
