// Video and audio in replies and tool output. The page loads no file itself: the host checks the
// path like a reply image (`media.load`) and answers a `cmux-agent://pane/__media/` URL that the
// pane's scheme handler serves in byte ranges (CSP `media-src 'self'`). A player mounts only
// once it nears the viewport and asks for metadata only, so a long transcript loads no media it
// does not show. A video plays inline with controls (muted while the pointer rests on it);
// Expand shows it large over the pane. Nothing opens a browser. Until the host answers, or when
// it will not play the file, the file shows as its name.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Dialog } from "../../../ui/Dialog";
import { useT } from "../i18n";
import { Close, Expand } from "../conversation/icons";
import { callChipHost } from "./host";
import { usePathInfo } from "./linkStore";
import { useNearViewport } from "../useNearViewport";
import { isDeniedPath, linkPath, pathName } from "./paths";

const VIDEO = /\.(mp4|m4v|mov|webm)$/i;
const AUDIO = /\.(mp3|m4a|aac|wav|flac)$/i;

/// Whether `src` (a path or `file://` URL) names a video or an audio file, by its extension.
export function mediaKind(src: string): "video" | "audio" | undefined {
  const path = (linkPath(src) ?? src).split(/[?#]/)[0] ?? "";
  return VIDEO.test(path) ? "video" : AUDIO.test(path) ? "audio" : undefined;
}

/// The host's answer per path, so a re-render or a second mention plays the same URL.
const granted = new Map<string, string>();

/// `path` is a local file (absolute or from the session's folder); `fallback` is how it draws when
/// the pane will not play it.
export function ReplyMedia({ path, alt, fallback }: { path: string; alt: string; fallback?: ReactNode }) {
  const t = useT();
  const kind = mediaKind(path) ?? "video";
  const { info, answered } = usePathInfo(path);
  const place = info?.place;
  const loadable = answered && !isDeniedPath(path) && place !== "denied" && place !== "outside" && place !== "missing";
  const [frame, setFrame] = useState<HTMLSpanElement | null>(null);
  const near = useNearViewport(frame);
  const [src, setSrc] = useState(() => granted.get(path));
  const [failed, setFailed] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const close = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!near || !loadable || src || failed) return;
    let live = true;
    void callChipHost("media.load", { src: path }).then((reply) => {
      const url = (reply as { src?: unknown } | undefined)?.src;
      if (!live) return;
      // The gallery's fixture answers a data URL; the pane's CSP plays only its own media URLs.
      if (typeof url === "string" && /^(cmux-agent:\/\/pane\/__media\/|data:(video|audio)\/)/.test(url)) {
        granted.set(path, url);
        setSrc(url);
      } else setFailed(true);
    });
    return () => {
      live = false;
    };
  }, [near, loadable, src, failed, path]);

  const name = alt || pathName(path);
  if (!src || failed) {
    if (failed && fallback) return <>{fallback}</>;
    return (
      <span ref={setFrame} className={`cv-media is-${kind}`} title={path}>
        <span className="cv-media__name">{name}</span>
      </span>
    );
  }
  const onError = () => {
    granted.delete(path);
    setFailed(true);
  };
  if (kind === "audio")
    return (
      <span className="cv-media is-audio" title={path}>
        <span className="cv-media__name">{name}</span>
        {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- an agent's recording has no captions */}
        <audio src={src} controls preload="metadata" aria-label={name} onError={onError} />
      </span>
    );
  return (
    <span className="cv-media is-video" title={path}>
      {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- an agent's recording has no captions */}
      <video
        src={src}
        controls
        muted
        playsInline
        preload="metadata"
        aria-label={name}
        onError={onError}
        onMouseEnter={(event) => {
          const video = event.currentTarget;
          if (video.paused && video.currentTime === 0) void video.play().catch(() => {});
        }}
        onMouseLeave={(event) => {
          const video = event.currentTarget;
          if (video.muted) video.pause();
        }}
      />
      <button
        type="button"
        className="cv-media__expand"
        aria-label={t("media.expand")}
        title={t("media.expand")}
        onClick={() => setExpanded(true)}
      >
        <Expand size={14} />
      </button>
      {expanded && (
        <Dialog
          open
          onOpenChange={(open) => {
            if (!open) setExpanded(false);
          }}
          label={name || t("media.player")}
          className="acpmux-image-viewer"
          backdropClassName="acpmux-image-viewer-backdrop"
          initialFocus={close}
        >
          <div className="acpmux-image-viewer-body">
            <div className="acpmux-image-viewer-bar">
              <span className="acpmux-image-viewer-title">{name}</span>
              <button
                type="button"
                className="acpmux-image-viewer-action"
                ref={close}
                aria-label={t("image.close")}
                title={t("image.close")}
                onClick={() => setExpanded(false)}
              >
                <Close />
              </button>
            </div>
            <div className="cv-media-stage">
              {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- an agent's recording has no captions */}
              <video src={src} controls autoPlay playsInline aria-label={name} />
            </div>
          </div>
        </Dialog>
      )}
    </span>
  );
}
