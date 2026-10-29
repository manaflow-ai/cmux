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

/// Each app's icon once the host answered: its data URL, or null for none. Kept for the page's life
/// (a person's sources are a handful of apps).
const icons = new Map<string, string | null>();
const asked = new Set<string>();
const listeners = new Set<() => void>();

function askIcon(bundleId: string): void {
  if (asked.has(bundleId)) return;
  asked.add(bundleId);
  void callHost("attachment.sourceIcon", { bundleId })
    .then((answer) => {
      const src = (answer as { src?: unknown } | null | undefined)?.src;
      return typeof src === "string" && src.startsWith("data:image/png;base64,") ? src : null;
    })
    .catch(() => null)
    .then((src) => {
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
  const read = useCallback(() => (bundleId ? (icons.get(bundleId) ?? undefined) : undefined), [bundleId]);
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
/// Mac has no such app. In the composer the tile's × takes the corner while the pointer is on it
/// (composerAttachments.css).
export function SourceBadge({ source }: { source: AttachmentSource | undefined }) {
  const icon = useSourceIcon(source?.bundleId);
  const label = useSourceLabel(source);
  if (!source || !icon) return null;
  return (
    <span className="acpmux-source-badge" role="img" aria-label={label}>
      <img src={icon} alt="" draggable={false} />
    </span>
  );
}

/// Forgets the icons (the gallery's fixtures, a test).
export function resetSourceIcons(): void {
  icons.clear();
  asked.clear();
}
