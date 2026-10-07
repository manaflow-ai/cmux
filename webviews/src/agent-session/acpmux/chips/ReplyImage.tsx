// Images in replies that are not data URLs (decision D5). The page loads no image itself (CSP
// `img-src data:`, `connect-src 'none'`); the host reads or fetches it (`image.load`) and answers
// a data URL. A file inside the session's folders loads at once; a web image follows
// `agentPane.images.remote`: a placeholder with its site and "Load image" (click, the default),
// its link only (never), or at once (always). Every web load uses the host's network rules.
import { useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { ImageIcon } from "../conversation/icons";
import { callChipHost } from "./host";
import { useReplyPolicy } from "./linkStore";
import { linkPath } from "./paths";

type State = { kind: "idle" } | { kind: "loading" } | { kind: "shown"; src: string } | { kind: "failed" };

/// A local image: an absolute path, a `file://` URL or a relative path (from the session's folder).
export function localImageSource(src: string): string | undefined {
  const path = linkPath(src);
  if (path) return path;
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(src) || src.startsWith("//") || src.startsWith("#") || src.startsWith("?")) return undefined;
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

/// `fallback` is how the image draws when the pane will not show it (its name as a link or text).
export function ReplyImage({ src, alt, fallback }: { src: string; alt: string; fallback: ReactNode }) {
  const local = localImageSource(src);
  const host = local ? undefined : remoteImageHost(src);
  if (!local && !host) return <>{fallback}</>;
  return local ? (
    <LocalImage src={src} alt={alt} fallback={fallback} />
  ) : (
    <RemoteImage src={src} alt={alt} host={host!} fallback={fallback} />
  );
}

function LocalImage({ src, alt, fallback }: { src: string; alt: string; fallback: ReactNode }) {
  const { state } = useImageLoad(src, true);
  return state.kind === "shown" ? <img className="cv-img" src={state.src} alt={alt} /> : <>{fallback}</>;
}

function RemoteImage({ src, alt, host, fallback }: { src: string; alt: string; host: string; fallback: ReactNode }) {
  const t = useT();
  const policy = useReplyPolicy();
  const { state, load } = useImageLoad(src, policy.remoteImages === "always");
  if (state.kind === "shown") return <img className="cv-img" src={state.src} alt={alt} />;
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
