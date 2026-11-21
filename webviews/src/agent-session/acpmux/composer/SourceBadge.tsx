// The app an attachment came from, as a small icon at its tile's top-right corner (Leo,
// 2026-10-29: "I think, like, Spotlight has an interesting feature for that, where just at the top
// right, there's a little icon that says, Oh, hey, this came from Cmax, this came from Claude, or
// whatever."). The host says the source (composer/attachmentSources.ts) and draws the app's icon
// (`attachment.sourceIcon`); a source nobody knows, or an app this Mac does not have, wears none.
// The tile's tooltip names it ("From Google Chrome · github.com").

import type { AttachmentSource } from "../attachments";
import { useSourceIcon, useSourceLabel } from "./sourceBadgeModel";
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
