// Images in replies that are not data URLs (decision D5). The page loads no image itself (CSP
// `img-src data:`, `connect-src 'none'`); the host reads or fetches it (`image.load`) and answers
// a data URL. A file inside the session's folders loads at once; a web image follows
// `agentPane.images.remote`: a placeholder with its site and "Load image" (click, the default),
// its link only (never), or at once (always). Every web load uses the host's network rules.
// A local image the host will not show (outside the folders, missing, or a failed load) draws as
// a compact card: its alt text, its file name and Open, the path chip's open with the same
// outside-folders confirmation. A deny-listed path is its alt text only.
import { useContext, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { ImageIcon, Lock } from "../conversation/icons";
import { ImageViewerContext } from "../conversation/imageViewerContext";
import { callChipHost } from "./host";
import { usePathInfo, useReplyPolicy } from "./linkStore";
import { isRemoteMedia, mediaKind, RemoteMedia, ReplyMedia } from "./ReplyMedia";
import { isDeniedPath, linkPath, pathName } from "./paths";

type State = { kind: "idle" } | { kind: "loading" } | { kind: "shown"; src: string } | { kind: "failed" };

/// A local image: an absolute path, a `file://` URL or a relative path (from the session's folder).
export function localImageSource(src: string): string | undefined {
  const path = linkPath(src);
  if (path) return path;
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(src) || src.startsWith("//") || src.startsWith("#") || src.startsWith("?"))
    return undefined;
  return src.split(/[?#]/)[0] || undefined;
}

/// The https image's site, or undefined for anything else.
export function remoteImageHost(src: string): string | undefined {
  try {
    const url = new URL(src);
    return url.protocol === "https:" && !url.username && !url.password ? url.host : undefined;
  } catch {
    return undefined;
  }
}

const loaded = new Map<string, string>();
/// Sources an automatic load started for, so a render twice in a row asks the host once.
const started = new Set<string>();

function useImageLoad(src: string, auto: boolean) {
  const [state, setState] = useState<State>(() => {
    const known = loaded.get(src);
    return known ? { kind: "shown", src: known } : { kind: "idle" };
  });
  const load = () => {
    setState({ kind: "loading" });
    void callChipHost("image.load", { src }).then((reply) => {
      const data = (reply as { src?: unknown } | undefined)?.src;
      if (typeof data === "string" && data.startsWith("data:image/")) {
        loaded.set(src, data);
        setState({ kind: "shown", src: data });
      } else {
        started.delete(src);
        setState({ kind: "failed" });
      }
    });
  };
  if (auto && state.kind === "idle" && !started.has(src)) {
    started.add(src);
    queueMicrotask(load);
  }
  return { state, load };
}

/// A shown image: a click opens it in the image viewer where the pane has one.
export function OpenableImage({ src, alt }: { src: string; alt: string }) {
  const t = useT();
  const openImage = useContext(ImageViewerContext);
  const image = <img className="cv-img" src={src} alt={alt} loading="lazy" decoding="async" />;
  if (!openImage) return image;
  return (
    <button
      type="button"
      className="cv-img-open"
      data-open-image
      title={alt || t("image.view")}
      onClick={() => openImage(src, alt)}
    >
      {image}
    </button>
  );
}

/// `fallback` is how the image draws when the pane will not show it (its name as a link or text).
export function ReplyImage({ src, alt, fallback }: { src: string; alt: string; fallback: ReactNode }) {
  const local = localImageSource(src);
  if (local && mediaKind(local)) return <ReplyMedia path={local} alt={alt} fallback={fallback} />;
  if (!local && isRemoteMedia(src)) return <RemoteMedia url={src} alt={alt} fallback={fallback} />;
  const host = local ? undefined : remoteImageHost(src);
  if (!local && !host) return <>{fallback}</>;
  return local ? (
    <LocalImage src={src} path={local} alt={alt} fallback={fallback} />
  ) : (
    <RemoteImage src={src} alt={alt} host={host!} fallback={fallback} />
  );
}

function LocalImage({ src, path, alt, fallback }: { src: string; path: string; alt: string; fallback: ReactNode }) {
  const t = useT();
  const { info, answered, policy } = usePathInfo(path);
  const place = info?.place;
  const denied = place === "denied" || isDeniedPath(path);
  // The host refuses a file outside the folders, so the page asks only for one it may show.
  const loadable = answered && !denied && place !== "outside" && place !== "missing";
  const { state } = useImageLoad(src, loadable);
  if (state.kind === "shown") return <OpenableImage src={state.src} alt={alt} />;
  if (denied) return <span className="cv-chip-plain">{alt || pathName(path)}</span>;
  const outside = place === "outside";
  if (!outside && place !== "missing" && state.kind !== "failed") return <>{fallback}</>;
  const canOpen = outside ? policy.outsideRoots !== "text" : place !== "missing";
  return (
    <span
      className={`cv-image-file${outside ? " is-outside" : ""}`}
      title={outside ? `${path}\n${t("chip.outsideProject")}` : path}
      data-path={path}
    >
      <ImageIcon size={16} className="cv-chip__icon" />
      {alt && <span className="cv-image-file__alt">{alt}</span>}
      <span className="cv-image-file__name">{pathName(path)}</span>
      {outside && <Lock size={11} className="cv-chip__lock" />}
      {!outside && <span className="cv-image-file__note">{t("image.unavailable")}</span>}
      {canOpen && (
        <button
          type="button"
          className="cv-image-file__open"
          onClick={() => void callChipHost("link.openPath", { path })}
        >
          {t("image.open")}
        </button>
      )}
    </span>
  );
}

function RemoteImage({ src, alt, host, fallback }: { src: string; alt: string; host: string; fallback: ReactNode }) {
  const t = useT();
  const policy = useReplyPolicy();
  const { state, load } = useImageLoad(src, policy.remoteImages === "always");
  if (state.kind === "shown") return <OpenableImage src={state.src} alt={alt} />;
  if (policy.remoteImages === "never") return <>{fallback}</>;
  return (
    <span className="cv-image-placeholder" title={src}>
      <ImageIcon size={16} className="cv-chip__icon" />
      <span className="cv-image-placeholder__host">{host}</span>
      {state.kind === "failed" ? (
        <span className="cv-image-placeholder__note">{t("image.unavailable")}</span>
      ) : (
        <button type="button" className="cv-image-placeholder__load" disabled={state.kind === "loading"} onClick={load}>
          {t("image.load")}
        </button>
      )}
    </span>
  );
}
