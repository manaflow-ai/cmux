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
import { useEffect, useMemo, useState, type MouseEvent, type ReactNode } from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { Lock } from "../conversation/icons";
import { useT } from "../i18n";
import { askChipHost, callChipHost, type ChipHostAnswer } from "./host";
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

/// How long a card waits for the host before it settles on the plain file card (name, path and
/// Open). A hover never waits on a host that doesn't answer.
const PREVIEW_TIMEOUT_MS = 4000;
let previewTimeout = PREVIEW_TIMEOUT_MS;

/// Tests shorten the wait; undefined restores it.
export function setPathPreviewTimeout(ms: number | undefined): void {
  previewTimeout = ms ?? PREVIEW_TIMEOUT_MS;
}

/// `askChipHost`, or a refusal with no code once `previewTimeout` passes. The native request
/// itself can't be withdrawn; the card just stops waiting for it.
function ask(method: string, params: Record<string, unknown>): Promise<ChipHostAnswer> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<ChipHostAnswer>((resolve) => {
    timer = setTimeout(() => resolve({ ok: false }), previewTimeout);
  });
  return Promise.race([askChipHost(method, params), late]).finally(() => clearTimeout(timer));
}

/// The host's preview of `path`, asked each time the card opens (a log grows, a screenshot is taken
/// again at the same path); null when it has none. `link.preview` goes first, for folders and
/// images too: in a chat on another machine it answers `{remote: true}` and the card asks nothing
/// more (no thumbnail of a same-named file on this Mac). A folder gets nothing else.
///
/// A `link.*` refusal is the host's answer about this path (an image isn't text, an outside file
/// isn't read): an image still asks for its thumbnail. Any other refusal (a host without
/// `link.preview`, a lost or timed-out call) can't say whether the chat is on this Mac, so the card
/// is the plain file card and asks nothing more. `cancelled` stops follow-ups once the card closes.
export async function loadPathPreview(
  path: string,
  folder: boolean,
  cancelled: () => boolean = () => false,
): Promise<PathPreview | null> {
  const answer = await ask("link.preview", { path });
  if (!answer.ok && !answer.code?.startsWith("link.")) return null;
  const reply = (answer.ok ? answer.value : undefined) as
    | { lines?: unknown; truncated?: unknown; remote?: unknown }
    | null
    | undefined;
  if (reply?.remote === true) return { kind: "remote" };
  if (folder || cancelled()) return null;
  if (IMAGE_PREVIEW.test(path)) {
    // An image the host would not draw is never shown as text: the card stays the plain file card.
    const image = await ask("image.load", { src: path });
    const src = image.ok ? (image.value as { src?: unknown } | null | undefined)?.src : undefined;
    return typeof src === "string" && src.startsWith("data:image/") ? { kind: "image", src } : null;
  }
  const lines = reply?.lines;
  return Array.isArray(lines) && lines.every((line) => typeof line === "string")
    ? { kind: "text", lines: lines as string[], truncated: reply?.truncated === true }
    : null;
}

/// This hover's preview: undefined until this hover's answer arrives, so a card opened again never
/// shows the last hover's image or Open while a new answer (perhaps `remote`) is out.
function usePathPreview(path: string, open: boolean, folder: boolean): PathPreview | null | undefined {
  // A new token each time the card opens (or its path changes): answers carry the token they were
  // asked under, and only the current one shows.
  const hover = useMemo(() => ({ open, path, folder }), [open, path, folder]);
  const [preview, setPreview] = useState<{ hover: object; value: PathPreview | null } | undefined>(undefined);
  useEffect(() => {
    if (!hover.open) return;
    let live = true;
    void loadPathPreview(hover.path, hover.folder, () => !live).then((value) => {
      if (live) setPreview({ hover, value });
    });
    return () => {
      live = false;
    };
  }, [hover]);
  return preview?.hover === hover ? preview.value : undefined;
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
          {/* Open waits for the host's answer, so a chat on another machine never flashes it. */}
          {preview !== undefined && preview?.kind !== "remote" && (
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
