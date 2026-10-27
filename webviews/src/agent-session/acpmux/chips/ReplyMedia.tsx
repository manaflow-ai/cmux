// Video and audio in replies and tool output. The page loads no file itself: the host checks the
// path like a reply image (`media.load`) and answers a `cmux-agent://pane/__media/` URL that the
// pane's scheme handler serves in byte ranges (CSP `media-src 'self'`). A player mounts only
// once it nears the viewport and asks for metadata only, so a long transcript loads no media it
// does not show. A video first draws as its thumbnail (Leo 2026-10-21: "id like to be able to watch
// .mp4s direclty in cmux next"): its poster frame, a play button and its length. The pointer
// resting on it previews it muted; a click plays it with sound and controls. Expand shows it large
// over the pane (paused until Play), and Open in tab opens it in a tab the way a link opens (the host's link setting):
// a file in cmux's file pages, a web video in a cmux browser tab. Until the host answers, or when
// it will not play the file, the file shows as its name.
// Web media (a GitHub user attachment or an https media link, alone on its line or as an image)
// follows `agentPane.images.remote` like a web image: a placeholder with its site and Load
// (click, the default), its link only (never), or at once (always). The host fetches it under
// its network rules and plays a checked copy.
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { Dialog } from "../../../ui/Dialog";
import { keyedIconProps } from "../../../ui/DialogButton";
import { useT } from "../i18n";
import { Close, Expand, OpenTab, PlayTriangle } from "../conversation/icons";
import { callChipHost } from "./host";
import { usePathInfo, useReplyPolicy } from "./linkStore";
import { useNearViewport } from "../useNearViewport";
import { isDeniedPath, linkPath, pathName } from "./paths";
import { MEDIA_PREVIEW_DWELL, useHoverIntent } from "../../../ui/hoverIntent";
import { mediaPreviewAllowed } from "../../../ui/mediaPreviewPolicy";

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

/// The host request that opens `source` in a tab, as a link to it would open: a web video
/// (https only) in a cmux browser tab (`browser.openIn` with `cmux`), a file through the path
/// chip's `link.openPath` (cmux's file pages, which play video and run nothing). The host checks
/// either again and places the tab by the link setting. Nil for anything else.
export function mediaOpenRequest(source: string): { method: string; params: Record<string, string> } | undefined {
  if (webURL(source)) return { method: "browser.openIn", params: { url: source, browserId: "cmux" } };
  // A path or a local `file://` URL; any other scheme (and a file URL on another host) opens nothing.
  const path = linkPath(source);
  if (!path || isDeniedPath(path)) return undefined;
  return { method: "link.openPath", params: { path } };
}

/// A video's length as the thumbnail shows it: `m:ss`, or `h:mm:ss` from an hour. Nil when the
/// length is unknown (a live stream, metadata not read yet).
export function formatDuration(seconds: number): string | undefined {
  if (!Number.isFinite(seconds) || seconds <= 0) return undefined;
  const total = Math.max(1, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
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
  if (src) return <MediaPlayer src={src} source={path} kind={kind} name={name} path={path} onError={fail} />;
  if (state === "failed" && fallback) return <>{fallback}</>;
  return (
    <span ref={setFrame} className={`cv-media is-${kind}`}>
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
  if (src) return <MediaPlayer src={src} source={url} kind={kind} name={name} onError={fail} />;
  if (policy.remoteImages === "never" || (state === "failed" && fallback)) return <>{fallback}</>;
  return (
    <span ref={setFrame} className={`cv-media is-${kind} is-remote`}>
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

export function MediaPlayer({
  src,
  source,
  kind,
  name,
  path,
  onError,
}: {
  src: string;
  /** The path or link the reply named, for Open in tab (never the granted `src`). */
  source: string;
  kind: "video" | "audio";
  name: string;
  /// The file it plays: its right-click menu's Copy, Save As… and Reveal in Finder act on it.
  path?: string;
  onError(): void;
}) {
  const t = useT();
  const [expanded, setExpanded] = useState(false);
  const close = useRef<HTMLButtonElement>(null);
  if (kind === "audio")
    return (
      <span className="cv-media is-audio" data-path={path}>
        {/* The name drags out as the file itself (conversation/dragOut.ts). */}
        <span className="cv-media__name" draggable={Boolean(path)}>
          {name}
        </span>
        {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- an agent's recording has no captions */}
        <audio src={src} controls preload="metadata" aria-label={name} onError={onError} />
      </span>
    );
  const open = mediaOpenRequest(source);
  return (
    <span className="cv-media is-video" data-path={path}>
      <VideoThumbnail src={src} name={name} onError={onError} />
      <span className="cv-media__actions">
        {open && (
          <button
            type="button"
            className="ui-glass cv-media__action"
            aria-label={t("media.openInTab")}
            title={t("media.openInTab")}
            onClick={() => void callChipHost(open.method, open.params)}
          >
            <OpenTab size={14} />
          </button>
        )}
        <button
          type="button"
          className="ui-glass cv-media__action cv-media__expand"
          aria-label={t("media.expand")}
          title={t("media.expand")}
          onClick={() => setExpanded(true)}
        >
          <Expand size={14} />
        </button>
      </span>
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
                {...keyedIconProps(t("image.close"), "escape")}
                onClick={() => setExpanded(false)}
              >
                <Close />
              </button>
            </div>
            <div className="cv-media-stage">
              {/* Opens paused, like the thumbnail: only Play starts it with sound (never autoplay). */}
              <VideoThumbnail src={src} name={name} onError={onError} />
            </div>
          </div>
        </Dialog>
      )}
    </span>
  );
}

function useMediaPreviewAllowed(): boolean {
  const [allowed, setAllowed] = useState(() => mediaPreviewAllowed());
  useEffect(() => {
    const root = document.documentElement;
    const query = window.matchMedia?.("(prefers-reduced-motion: reduce)");
    const update = () => setAllowed(mediaPreviewAllowed(root));
    update();
    query?.addEventListener("change", update);
    const observer = typeof MutationObserver === "undefined" ? undefined : new MutationObserver(update);
    observer?.observe(root, {
      attributes: true,
      attributeFilter: ["data-agent-motion", "data-cmux-motion", "data-status-indicators"],
    });
    return () => {
      query?.removeEventListener("change", update);
      observer?.disconnect();
    };
  }, []);
  return allowed;
}

/// A video before it plays: its poster frame (the frame just after the start, read with the
/// metadata), a glass play button in its middle and its length in a corner. The pointer resting on
/// it previews it muted after the shared hover-intent dwell; a click plays it from the start with
/// sound and the player's controls. Every part a click lands on shows the pointing hand.
export function VideoThumbnail({ src, name, onError }: { src: string; name: string; onError(): void }) {
  const t = useT();
  const video = useRef<HTMLVideoElement>(null);
  const startedRef = useRef(false);
  const [started, setStarted] = useState(false);
  const [hovered, setHovered] = useState(false);
  const [duration, setDuration] = useState<string | undefined>();
  const previewAllowed = useMediaPreviewAllowed();
  const { shown, hover: setHover, dismiss } = useHoverIntent<boolean>({ delay: MEDIA_PREVIEW_DWELL });
  const previewing = previewAllowed && shown === true;

  useEffect(() => {
    if (!previewAllowed) dismiss();
  }, [dismiss, previewAllowed]);

  useEffect(() => {
    if (started || !hovered || !previewAllowed) return;
    const element = video.current;
    const cancel = () => {
      if (startedRef.current) return;
      dismiss();
      if (element?.muted) element.pause();
    };
    document.addEventListener("scroll", cancel, true);
    document.addEventListener("visibilitychange", cancel);
    window.addEventListener("pagehide", cancel);
    return () => {
      if (!startedRef.current) cancel();
      document.removeEventListener("scroll", cancel, true);
      document.removeEventListener("visibilitychange", cancel);
      window.removeEventListener("pagehide", cancel);
    };
  }, [dismiss, hovered, previewAllowed, started]);

  useEffect(() => {
    const element = video.current;
    if (!element || started) return;
    if (previewing) void element.play()?.catch(() => {});
    else if (element.muted) element.pause();
  }, [previewing, started]);

  const play = () => {
    const element = video.current;
    startedRef.current = true;
    dismiss();
    setStarted(true);
    if (!element) return;
    element.muted = false;
    element.currentTime = 0;
    void element.play()?.catch(() => {});
  };
  return (
    <span
      className={started ? "cv-media__frame is-playing" : "cv-media__frame"}
      data-previewing={previewing ? "true" : undefined}
    >
      {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- an agent's recording has no captions */}
      <video
        ref={video}
        src={src}
        controls={started}
        muted={!started}
        playsInline
        preload="metadata"
        aria-label={name}
        onError={onError}
        onLoadedMetadata={(event) => {
          const element = event.currentTarget;
          setDuration(formatDuration(element.duration));
          // The poster: seeking a hair past the start makes the player draw that frame (with
          // preload="metadata" it otherwise shows black until it plays).
          if (element.paused && element.currentTime === 0 && element.duration > 0.2) element.currentTime = 0.1;
        }}
      />
      {!started && (
        <button
          type="button"
          className="cv-media__poster"
          aria-label={duration ? t("media.playLength", { length: duration }) : t("media.play")}
          onClick={play}
          onMouseEnter={() => {
            setHovered(true);
            if (previewAllowed) setHover(true, MEDIA_PREVIEW_DWELL);
          }}
          onMouseLeave={() => {
            setHovered(false);
            setHover(null);
          }}
        >
          <span className="ui-glass cv-media__play" aria-hidden="true">
            <PlayTriangle size={18} style={{ color: "inherit" }} />
          </span>
          {duration && (
            <span className="cv-media__duration" aria-hidden="true">
              {duration}
            </span>
          )}
        </button>
      )}
    </span>
  );
}
