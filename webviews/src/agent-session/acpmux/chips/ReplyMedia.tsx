// Video and audio in replies and tool output. The page loads no file itself: the host checks the
// path like a reply image (`media.load`) and answers a `cmux-agent://pane/__media/` URL that the
// pane's scheme handler serves in byte ranges (CSP `media-src 'self'`). A player mounts only
// once it nears the viewport and asks for metadata only, so a long transcript loads no media it
// does not show. A video plays inline with controls (muted while the pointer rests on it);
// Expand shows it large over the pane. Nothing opens a browser. Until the host answers, or when
// it will not play the file, the file shows as its name.
// Web media (a GitHub user attachment or an https media link, alone on its line or as an image)
// follows `agentPane.images.remote` like a web image: a placeholder with its site and Load
// (click, the default), its link only (never), or at once (always). The host fetches it under
// its network rules and plays a checked copy.
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { Dialog } from "../../../ui/Dialog";
import { useT } from "../i18n";
import { Close, Expand } from "../conversation/icons";
import { callChipHost } from "./host";
import { usePathInfo, useReplyPolicy } from "./linkStore";
import { useNearViewport } from "../useNearViewport";
import { isDeniedPath, linkPath, pathName } from "./paths";

const VIDEO = /\.(mp4|m4v|mov|webm)$/i;
const AUDIO = /\.(mp3|m4a|aac|wav|flac)$/i;
const ATTACHMENT = /^\/user-attachments\/assets\/[\w-]+$/;

/// Whether `src` (a path or `file://` URL) names a video or an audio file, by its extension.
export function mediaKind(src: string): "video" | "audio" | undefined {
  const path = (linkPath(src) ?? src).split(/[?#]/)[0] ?? "";
  return VIDEO.test(path) ? "video" : AUDIO.test(path) ? "audio" : undefined;
}

function webURL(src: string): URL | undefined {
  try {
    const url = new URL(src);
    return url.protocol === "https:" && !url.username && !url.password ? url : undefined;
  } catch {
    return undefined;
  }
}

/// Whether `src` is web media: an https link to a video or audio file, or a GitHub user attachment.
export function isRemoteMedia(src: string): boolean {
  const url = webURL(src);
  if (!url) return false;
  return (url.hostname === "github.com" && ATTACHMENT.test(url.pathname)) || mediaKind(url.pathname) !== undefined;
}

/// The host's answer per source, so a re-render or a second mention plays the same URL.
const granted = new Map<string, string>();

/// Asks the host for the URL `source` plays by: at once when `auto`, else on `load()`.
function useMediaLoad(source: string, auto: boolean) {
  const [src, setSrc] = useState(() => granted.get(source));
  const [state, setState] = useState<"idle" | "loading" | "failed">("idle");
  const load = useCallback(() => {
    setState("loading");
    void callChipHost("media.load", { src: source }).then((reply) => {
      const url = (reply as { src?: unknown } | undefined)?.src;
      // The gallery's fixture answers a data URL; the pane's CSP plays only its own media URLs.
      if (typeof url === "string" && /^(cmux-agent:\/\/pane\/__media\/|data:(video|audio)\/)/.test(url)) {
        granted.set(source, url);
        setSrc(url);
        setState("idle");
      } else setState("failed");
    });
  }, [source]);
  useEffect(() => {
    if (auto && !src && state === "idle") load();
  }, [auto, src, state, load]);
  const fail = useCallback(() => {
    granted.delete(source);
    setSrc(undefined);
    setState("failed");
  }, [source]);
  return { src, state, load, fail };
}

/// `path` is a local file (absolute or from the session's folder); `fallback` is how it draws when
/// the pane will not play it.
export function ReplyMedia({ path, alt, fallback }: { path: string; alt: string; fallback?: ReactNode }) {
  const kind = mediaKind(path) ?? "video";
  const { info, answered } = usePathInfo(path);
  const place = info?.place;
  const loadable = answered && !isDeniedPath(path) && place !== "denied" && place !== "outside" && place !== "missing";
  const [frame, setFrame] = useState<HTMLSpanElement | null>(null);
  const near = useNearViewport(frame);
  const { src, state, fail } = useMediaLoad(path, near && loadable);
  const name = alt || pathName(path);
  if (src) return <MediaPlayer src={src} kind={kind} name={name} title={path} onError={fail} />;
  if (state === "failed" && fallback) return <>{fallback}</>;
  return (
    <span ref={setFrame} className={`cv-media is-${kind}`} title={path}>
      <span className="cv-media__name">{name}</span>
    </span>
  );
}

/// Web media at `url`; `fallback` is its link, for `never` and a failed load.
export function RemoteMedia({ url, alt, fallback }: { url: string; alt: string; fallback?: ReactNode }) {
  const t = useT();
  const policy = useReplyPolicy();
  const kind = mediaKind(webURL(url)?.pathname ?? "") ?? "video";
  const [frame, setFrame] = useState<HTMLSpanElement | null>(null);
  const near = useNearViewport(frame);
  const { src, state, load, fail } = useMediaLoad(url, near && policy.remoteImages === "always");
  const name = alt || webURL(url)?.pathname.split("/").pop() || url;
  if (src) return <MediaPlayer src={src} kind={kind} name={name} title={url} onError={fail} />;
  if (policy.remoteImages === "never" || (state === "failed" && fallback)) return <>{fallback}</>;
  return (
    <span ref={setFrame} className={`cv-media is-${kind} is-remote`} title={url}>
      <span className="cv-media__host">{webURL(url)?.host}</span>
      {state === "failed" ? (
        <span className="cv-image-placeholder__note">{t("image.unavailable")}</span>
      ) : (
        <button type="button" className="cv-image-placeholder__load" disabled={state === "loading"} onClick={load}>
          {kind === "audio" ? t("media.loadAudio") : t("media.loadVideo")}
        </button>
      )}
    </span>
  );
}

function MediaPlayer({
  src,
  kind,
  name,
  title,
  onError,
}: {
  src: string;
  kind: "video" | "audio";
  name: string;
  title: string;
  onError(): void;
}) {
  const t = useT();
  const [expanded, setExpanded] = useState(false);
  const close = useRef<HTMLButtonElement>(null);
  if (kind === "audio")
    return (
      <span className="cv-media is-audio" title={title}>
        <span className="cv-media__name">{name}</span>
        {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- an agent's recording has no captions */}
        <audio src={src} controls preload="metadata" aria-label={name} onError={onError} />
      </span>
    );
  return (
    <span className="cv-media is-video" title={title}>
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
