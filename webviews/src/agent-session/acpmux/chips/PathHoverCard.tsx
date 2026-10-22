// A path chip's hover card (Leo 2026-10-21: "all these I hope can be previewed"): the file's
// name and path, Open, and a quick look at it: an image's thumbnail (`image.load`) or a text file's
// first lines (`link.preview`, a bounded read on the host). A locked chip (outside the session's
// folders) has the card too: the lock means outside, not "can't open". What the host sends from
// outside the folders follows `agentPane.links.outsideRoots`: images as #23879 shows them inline,
// text only under `open` (the default), never a deny-listed path. A folder shows only its name and
// Open. Open is the chip's own open (`link.openPath`), so the host decides where the file shows
// ("Open new tabs and links"), never the chat pane's own navigation.
import { useEffect, useState, type MouseEvent, type ReactNode } from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { Lock } from "../conversation/icons";
import { useT } from "../i18n";
import { callChipHost } from "./host";
import { pathName } from "./paths";
import type { HoverCard } from "./useHoverCard";

/// What the card shows under its head.
export type PathPreview = { kind: "image"; src: string } | { kind: "text"; lines: string[]; truncated: boolean };

/// Files the host draws as an image (`image.load`): rasters, an SVG rebuilt without script, and a
/// PDF's first page.
const IMAGE_PREVIEW = /\.(?:png|jpe?g|gif|webp|heic|tiff?|bmp|svg|pdf)$/i;

/// The host's preview of `path`, asked each time the card opens (a log grows, a screenshot is taken
/// again at the same path); null when it has none.
export async function loadPathPreview(path: string): Promise<PathPreview | null> {
  if (IMAGE_PREVIEW.test(path)) {
    const reply = (await callChipHost("image.load", { src: path })) as { src?: unknown } | undefined;
    const src = reply?.src;
    if (typeof src !== "string" || !src.startsWith("data:image/")) return null;
    return { kind: "image", src };
  }
  const reply = (await callChipHost("link.preview", { path })) as { lines?: unknown; truncated?: unknown } | undefined;
  const lines = reply?.lines;
  return Array.isArray(lines) && lines.every((line) => typeof line === "string")
    ? { kind: "text", lines: lines as string[], truncated: reply?.truncated === true }
    : null;
}

function usePathPreview(path: string, open: boolean, folder: boolean): PathPreview | null | undefined {
  const [preview, setPreview] = useState<{ path: string; value: PathPreview | null } | undefined>(undefined);
  useEffect(() => {
    if (!open || folder) return;
    let live = true;
    void loadPathPreview(path).then((value) => {
      if (live) setPreview({ path, value });
    });
    return () => {
      live = false;
    };
  }, [open, folder, path]);
  return preview?.path === path ? preview.value : undefined;
}

export function PathHoverCard({
  path,
  anchor,
  hover,
  icon,
  folder,
  outside,
}: {
  path: string;
  /// The chip the card describes; it shows while `hover.open`.
  anchor: HTMLElement | null;
  hover: HoverCard;
  icon: ReactNode;
  folder: boolean;
  outside: boolean;
}) {
  const t = useT();
  const preview = usePathPreview(path, hover.open, folder);
  const onOpen = (event: MouseEvent<HTMLButtonElement>) => {
    event.preventDefault();
    event.stopPropagation();
    void callChipHost("link.openPath", { path });
  };
  return (
    <AnchoredCard
      anchor={hover.open ? anchor : null}
      className="ui-glass cv-link-preview cv-path-preview"
      interactive
      ariaLabel={pathName(path)}
    >
      <div className="cv-link-preview__content" {...hover.card}>
        <div className="cv-link-preview__head">
          <span className="cv-link-preview__icon">{icon}</span>
          <span className="cv-link-preview__titles">
            <span className="cv-link-preview__site">
              {pathName(path)}
              {outside && <Lock size={11} className="cv-chip__lock" />}
            </span>
            <span className="cv-link-preview__target">{path}</span>
          </span>
          <button type="button" className="cv-link-preview__open" onClick={onOpen}>
            {t("image.open")}
            <span aria-hidden="true">↗</span>
          </button>
        </div>
        {preview?.kind === "image" && <img className="cv-path-preview__image" src={preview.src} alt="" />}
        {preview?.kind === "text" && (
          <pre className="cv-path-preview__text" data-truncated={preview.truncated || undefined}>
            {preview.lines.join("\n")}
          </pre>
        )}
      </div>
    </AnchoredCard>
  );
}
