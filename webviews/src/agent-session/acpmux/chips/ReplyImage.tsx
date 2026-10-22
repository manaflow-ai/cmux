// Images in replies that are not data URLs (decision D5). The page loads no image itself (CSP
// `img-src data:`, `connect-src 'none'`); the host reads or fetches it (`image.load`) and answers
// a data URL. A file inside the session's folders loads at once; a web image follows
// `agentPane.images.remote`: a placeholder with its site and "Load image" (click, the default),
// its link only (never), or at once (always). Every web load uses the host's network rules.
// A local image the host will not show (outside the folders, missing, or a failed load) draws as
// a compact card: its alt text, its file name and Open, the path chip's open with the same
// outside-folders confirmation. A deny-listed path is its alt text only.
// A reply's own images (`thumb`) draw in a glass thumbnail of a fixed shape whatever their state
// (waiting, Load image, unavailable, shown), so an image that loads never moves the reply; a click
// opens it whole in the image viewer.
// While the host doesn't yet know where the chat runs, `image.load` answers pending: the image
// keeps its waiting look and asks again on the `locality` event (locality.ts).
import { useContext, useEffect, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { ImageIcon, Lock } from "../conversation/icons";
import { ImageViewerContext } from "../conversation/imageViewerContext";
import { callChipHost } from "./host";
import { DataUrlCache, IMAGE_CACHE_MAX_CHARS, IMAGE_CACHE_MAX_ENTRIES } from "./imageCache";
import { ElsewhereChip } from "./LinkChips";
import { useMessageScope } from "./messageScope";
import { usePathInfo, useReplyPolicy } from "./linkStore";
import { isPending, localityGeneration, onLocalityChange, useLocalityGeneration } from "./locality";
import { isRemoteMedia, mediaKind, RemoteMedia, ReplyMedia } from "./ReplyMedia";
import { isDeniedPath, linkPath, pathName } from "./paths";

/// `generation` is the locality an answer came under (locality.ts): a pending one, or a file this
/// Mac read, is asked again under a new one. `byClick`: the reader started it with Load image.
type Pending = { generation: number; byClick: boolean };
type State =
  | { kind: "idle" }
  | { kind: "loading" }
  | ({ kind: "pending" } & Pending)
  | { kind: "shown"; src: string; generation: number }
  | { kind: "failed"; generation: number };

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

/// Sources an automatic load started for, so a render twice in a row asks the host once.
const started = new Set<string>();
/// Images that loaded on their own (a file in the folders, a web image under "always"), the most
/// recently drawn first. One it forgets loads again on its own when it draws.
const loaded = new DataUrlCache(IMAGE_CACHE_MAX_ENTRIES, IMAGE_CACHE_MAX_CHARS, (src) => started.delete(src));
/// Images the reader loaded with "Load image". They stay: loading one again would need another
/// click (the host spends a gesture on each), so forgetting it would leave its placeholder.
const clicked = new Map<string, string>();
/// Sources the host answered pending, kept outside the components so one that scrolls out of the
/// virtual transcript and back waits instead of asking again.
const waiting = new Map<string, Pending>();
/// A new locality forgets the local files read under the old one: the host decides them again.
onLocalityChange(() => {
  loaded.forget((src) => localImageSource(src) !== undefined);
});

function initialState(src: string): State {
  const known = clicked.get(src) ?? loaded.get(src);
  if (known) return { kind: "shown", src: known, generation: localityGeneration() };
  const pending = waiting.get(src);
  return pending ? { kind: "pending", ...pending } : { kind: "idle" };
}

function useImageLoad(src: string, auto: boolean) {
  const generation = useLocalityGeneration();
  const [state, setState] = useState<State>(() => initialState(src));
  const load = (byClick: boolean) => {
    setState({ kind: "loading" });
    const asked = localityGeneration();
    void callChipHost("image.load", { src }).then((reply) => {
      const data = (reply as { src?: unknown } | undefined)?.src;
      started.delete(src);
      // Pending, or any answer about a locality that has changed since (an image, a refusal, web
      // or local): nothing is kept, and it is asked again under the new one.
      if (isPending(reply) || asked !== localityGeneration()) {
        const pending = { generation: asked, byClick };
        waiting.set(src, pending);
        setState({ kind: "pending", ...pending });
        return;
      }
      waiting.delete(src);
      if (typeof data === "string" && data.startsWith("data:image/")) {
        if (byClick) clicked.set(src, data);
        else loaded.set(src, data);
        setState({ kind: "shown", src: data, generation: asked });
      } else setState({ kind: "failed", generation: asked });
    });
  };
  if (auto && state.kind === "idle" && !started.has(src)) {
    started.add(src);
    queueMicrotask(() => load(false));
  }
  // Under a new locality, a failure and a file read on this Mac are the host's to decide again, and
  // a pending answer is asked again: on its own, or because the reader asked with Load image.
  const reread =
    (state.kind === "failed" && state.generation !== generation) ||
    (state.kind === "shown" &&
      state.generation !== generation &&
      !clicked.has(src) &&
      localImageSource(src) !== undefined);
  const retry = state.kind === "pending" && state.generation !== generation && (state.byClick || auto);
  const byClick = state.kind === "pending" && state.byClick;
  useEffect(() => {
    if (retry) load(byClick);
    else if (reread) setState({ kind: "idle" });
    // `load` is this render's; the flags decide when it runs.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [retry, reread, byClick]);
  return { state: reread ? ({ kind: "idle" } as State) : state, load: () => load(true) };
}

/// A shown image: a click opens it in the image viewer where the pane has one. `path` is the file
/// a reply named for it, so the viewer's Show in Finder selects that file.
export function OpenableImage({
  src,
  alt,
  path,
  thumb = false,
}: {
  src: string;
  alt: string;
  path?: string;
  thumb?: boolean;
}) {
  const t = useT();
  const openImage = useContext(ImageViewerContext);
  // Use the shared compositor-only fade for a calm handoff from the placeholder.
  // The motion is disabled under reduced-motion; opacity never affects layout.
  const image = (
    <img
      className={thumb ? "cv-thumb__img cv-img--enter" : "cv-img cv-img--enter"}
      src={src}
      alt={alt}
      loading="lazy"
      decoding="async"
    />
  );
  if (!openImage) return thumb ? <span className="cv-thumb">{image}</span> : image;
  return (
    <button
      type="button"
      className={thumb ? "cv-thumb cv-thumb--open" : "cv-img-open"}
      data-open-image
      /* The file a reply read the image from: the context menu's Show in Finder selects it. */
      data-image-path={path || undefined}
      /* A button is not draggable by default: the image drags out as a file (conversation/dragOut.ts). */
      draggable
      title={alt || t("image.view")}
      onClick={() => openImage(src, alt, path)}
    >
      {image}
    </button>
  );
}

/// The thumbnail's box while its image is not shown: the same shape as the shown image.
function ThumbFrame({ state, children }: { state: "waiting" | "placeholder"; children?: ReactNode }) {
  return <span className={`cv-thumb is-${state}`}>{children}</span>;
}

/// `fallback` is how the image draws when the pane will not show it (its name as a link or text).
/// `thumb`: draw in the reply's fixed-shape thumbnail (Markdown.tsx), in every state.
export function ReplyImage({
  src,
  alt,
  fallback,
  thumb = false,
}: {
  src: string;
  alt: string;
  fallback: ReactNode;
  thumb?: boolean;
}) {
  const scope = useMessageScope();
  const local = localImageSource(src);
  // Another machine's image: its chip, never a file of the same path here; a denied one is its name.
  if (local && scope?.host !== undefined)
    return isDeniedPath(local) ? (
      <span className="cv-chip-plain">{alt || pathName(local)}</span>
    ) : (
      <ElsewhereChip path={local} host={scope.host} label={alt || undefined} />
    );
  if (local && mediaKind(local)) return <ReplyMedia path={local} alt={alt} fallback={fallback} />;
  if (!local && isRemoteMedia(src)) return <RemoteMedia url={src} alt={alt} fallback={fallback} />;
  const host = local ? undefined : remoteImageHost(src);
  if (!local && !host) return <>{fallback}</>;
  return local ? (
    <LocalImage src={src} path={local} alt={alt} fallback={fallback} thumb={thumb} />
  ) : (
    <RemoteImage src={src} alt={alt} host={host!} fallback={fallback} thumb={thumb} />
  );
}

function LocalImage({
  src,
  path,
  alt,
  fallback,
  thumb,
}: {
  src: string;
  path: string;
  alt: string;
  fallback: ReactNode;
  thumb: boolean;
}) {
  const t = useT();
  const { info, answered, pending, policy } = usePathInfo(path);
  const place = info?.place;
  const denied = place === "denied" || isDeniedPath(path);
  // The host refuses a file outside the folders, so the page asks only for one it may show.
  const loadable = answered && !denied && place !== "outside" && place !== "missing";
  const { state } = useImageLoad(src, loadable);
  if (state.kind === "shown") return <OpenableImage src={state.src} alt={alt} path={path} thumb={thumb} />;
  if (denied) return <span className="cv-chip-plain">{alt || pathName(path)}</span>;
  const outside = place === "outside";
  // While the host can't yet say where the chat runs, every image waits in its frame, a tool's
  // image too: its file name alone would read as an image that will not show.
  const waits = pending || state.kind === "pending";
  if (!outside && place !== "missing" && (state.kind !== "failed" || waits))
    return thumb || waits ? (
      <ThumbFrame state="waiting">
        <ImageIcon size={18} className="cv-chip__icon" />
        <span className="cv-thumb__name">{alt || pathName(path)}</span>
      </ThumbFrame>
    ) : (
      <>{fallback}</>
    );
  const canOpen = outside ? policy.outsideRoots !== "text" : place !== "missing";
  const card = (
    <span className={`cv-image-file${outside ? " is-outside" : ""}`} data-path={path}>
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
  return thumb ? <ThumbFrame state="placeholder">{card}</ThumbFrame> : card;
}

function RemoteImage({
  src,
  alt,
  host,
  fallback,
  thumb,
}: {
  src: string;
  alt: string;
  host: string;
  fallback: ReactNode;
  thumb: boolean;
}) {
  const t = useT();
  const policy = useReplyPolicy();
  const { state, load } = useImageLoad(src, policy.remoteImages === "always");
  if (state.kind === "shown") return <OpenableImage src={state.src} alt={alt} thumb={thumb} />;
  if (policy.remoteImages === "never") return <>{fallback}</>;
  const placeholder = (
    <span className="cv-image-placeholder">
      <ImageIcon size={16} className="cv-chip__icon" />
      <span className="cv-image-placeholder__host">{host}</span>
      {state.kind === "failed" ? (
        <span className="cv-image-placeholder__note">{t("image.unavailable")}</span>
      ) : (
        <button
          type="button"
          className="cv-image-placeholder__load"
          disabled={state.kind === "loading" || state.kind === "pending"}
          onClick={load}
        >
          {t("image.load")}
        </button>
      )}
    </span>
  );
  return thumb ? <ThumbFrame state="placeholder">{placeholder}</ThumbFrame> : placeholder;
}
