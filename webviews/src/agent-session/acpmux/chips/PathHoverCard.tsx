// A path chip's hover card (Leo 2026-10-21: "all these I hope can be previewed"): the file's
// name and path, Open, and a quick look at it: an image's thumbnail (`image.load`) or a text file's
// first lines (`link.preview`, a bounded read on the host). A locked chip (outside the session's
// folders) has the card too: the lock means outside, not "can't open". What the host sends from
// outside the folders follows `agentPane.links.outsideRoots`: images as #23879 shows them inline,
// text only under `open` (the default), never a deny-listed path. A folder shows only its name and
// Open (or, in a chat on another machine, the note and no Open). Open is the chip's own open (`link.openPath`), so the host decides where the file shows
// ("Open new tabs and links"), never the chat pane's own navigation.
// When the host has no preview (an image it refuses, such as one outside the folders before
// #23879, or a file it won't read) the card is the plain file card: name, path and Open, never an
// empty thumbnail. In a chat on another machine the host reads nothing here (`{remote: true}`),
// and the card says the file is on that machine, with no Open of a same-named file or folder on
// this Mac; the host refuses that chat's `image.load` and `link.openPath` before any lookup too.
import { useEffect, useState, type MouseEvent, type ReactNode } from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { Lock } from "../conversation/icons";
import { useT } from "../i18n";
import { callChipHost } from "./host";
import { pathName } from "./paths";
import type { HoverCard } from "./useHoverCard";

/// What the card shows under its head.
export type PathPreview =
  | { kind: "image"; src: string }
  | { kind: "text"; lines: string[]; truncated: boolean }
  | { kind: "remote" };

/// Files the host draws as an image (`image.load`): rasters, an SVG rebuilt without script, and a
/// PDF's first page.
const IMAGE_PREVIEW = /\.(?:png|jpe?g|gif|webp|heic|tiff?|bmp|svg|pdf)$/i;

/// The host's preview of `path`, asked each time the card opens (a log grows, a screenshot is taken
/// again at the same path); null when it has none. `link.preview` goes first, for folders and
/// images too: in a chat on another machine it answers `{remote: true}` and the card asks nothing
/// more (no thumbnail of a same-named file on this Mac). A folder gets nothing else.
export async function loadPathPreview(path: string, folder: boolean): Promise<PathPreview | null> {
  const reply = (await callChipHost("link.preview", { path })) as
    | { lines?: unknown; truncated?: unknown; remote?: unknown }
    | undefined;
  if (reply?.remote === true) return { kind: "remote" };
  if (folder) return null;
  if (IMAGE_PREVIEW.test(path)) {
    // An image the host would not draw is never shown as text: the card stays the plain file card.
    const image = (await callChipHost("image.load", { src: path })) as { src?: unknown } | undefined;
    const src = image?.src;
    return typeof src === "string" && src.startsWith("data:image/") ? { kind: "image", src } : null;
  }
  const lines = reply?.lines;
  return Array.isArray(lines) && lines.every((line) => typeof line === "string")
    ? { kind: "text", lines: lines as string[], truncated: reply?.truncated === true }
    : null;
}

function usePathPreview(path: string, open: boolean, folder: boolean): PathPreview | null | undefined {
  const [preview, setPreview] = useState<{ path: string; value: PathPreview | null } | undefined>(undefined);
  useEffect(() => {
    if (!open) return;
    let live = true;
    void loadPathPreview(path, folder).then((value) => {
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
          {preview?.kind !== "remote" && (
            <button type="button" className="cv-link-preview__open" onClick={onOpen}>
              {t("image.open")}
              <span aria-hidden="true">↗</span>
            </button>
          )}
        </div>
        {preview?.kind === "image" && <img className="cv-path-preview__image" src={preview.src} alt="" />}
        {preview?.kind === "remote" && <p className="cv-path-preview__note">{t("pathPreview.remote")}</p>}
        {preview?.kind === "text" && (
          <pre className="cv-path-preview__text" data-truncated={preview.truncated || undefined}>
            {preview.lines.join("\n")}
          </pre>
        )}
      </div>
    </AnchoredCard>
  );
}
