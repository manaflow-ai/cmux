// The app an attachment came from, as a small icon at its tile's top-right corner (Leo,
// 2026-10-29: "I think, like, Spotlight has an interesting feature for that, where just at the top
// right, there's a little icon that says, Oh, hey, this came from Cmax, this came from Claude, or
// whatever."). The host says the source (composer/attachmentSources.ts) and draws the app's icon
// (`attachment.sourceIcon`); a source nobody knows, or an app this Mac does not have, wears none.
// The tile's tooltip names it ("From Google Chrome · github.com").
import { useCallback, useEffect, useSyncExternalStore } from "react";
import type { AttachmentSource } from "../attachments";
import { useT } from "../i18n";
import { callHost } from "./attachmentSources";

/// Each app's icon once the host drew it: its data URL. Only answers are kept, for the page's life
/// (a person's sources are a handful of apps).
const icons = new Map<string, string>();
/// The apps asked now: at most one ask per app is in flight.
const asking = new Set<string>();
/// When each app's last ask came back with no icon (refused, empty, not a PNG). The host may draw it
/// later (this Mac said a new attachment came from it), so the next badge of that app asks again,
/// but no sooner than ``ICON_RETRY_MS`` after.
const failed = new Map<string, number>();
const listeners = new Set<() => void>();

/// How long after an ask that came back with no icon the next badge of that app may ask again.
export const ICON_RETRY_MS = 30_000;

function askIcon(bundleId: string): void {
  if (icons.has(bundleId) || asking.has(bundleId)) return;
  const at = failed.get(bundleId);
  if (at !== undefined && Date.now() - at < ICON_RETRY_MS) return;
  asking.add(bundleId);
  void callHost("attachment.sourceIcon", { bundleId })
    .then((answer) => {
      const src = (answer as { src?: unknown } | null | undefined)?.src;
      return typeof src === "string" && src.startsWith("data:image/png;base64,") ? src : null;
    })
    .catch(() => null)
    .then((src) => {
      asking.delete(bundleId);
      if (!src) {
        failed.set(bundleId, Date.now());
        return;
      }
      failed.delete(bundleId);
      icons.set(bundleId, src);
      for (const listener of listeners) listener();
    });
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

/// The data URL of the icon of the app `bundleId` names, once the host drew it.
export function useSourceIcon(bundleId: string | undefined): string | undefined {
  const read = useCallback(() => (bundleId ? icons.get(bundleId) : undefined), [bundleId]);
  const src = useSyncExternalStore(subscribe, read, read);
  useEffect(() => {
    if (bundleId) askIcon(bundleId);
  }, [bundleId]);
  return src;
}

/// "From Google Chrome", or "From Google Chrome · github.com" for a download; undefined for none.
export function useSourceLabel(source: AttachmentSource | undefined): string | undefined {
  const t = useT();
  if (!source) return undefined;
  return source.site
    ? t("attachment.sourceSite", { name: source.name, site: source.site })
    : t("attachment.source", { name: source.name });
}

/// A tile's tooltip with its source's line under its own.
export function withSourceLabel(title: string | undefined, label: string | undefined): string | undefined {
  if (!label) return title;
  return title ? `${title}\n${label}` : label;
}

/// The source's app icon at the tile's top-right corner: nothing while it is unknown, or when this
/// Mac has no such app. The icon's alt names the source for screen readers. In the composer the tile's × takes the corner while the pointer is on it
/// (composerAttachments.css).
export function SourceBadge({ source }: { source: AttachmentSource | undefined }) {
  const icon = useSourceIcon(source?.bundleId);
  const label = useSourceLabel(source);
  if (!source || !icon) return null;
  return (
    <span className="acpmux-source-badge" data-label={label}>
      <img src={icon} alt={label} draggable={false} />
    </span>
  );
}

/// Forgets the icons (the gallery's fixtures, a test).
export function resetSourceIcons(): void {
  icons.clear();
  asking.clear();
  failed.clear();
}
