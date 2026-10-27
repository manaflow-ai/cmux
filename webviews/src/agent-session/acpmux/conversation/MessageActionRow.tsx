import { useEffect, useSyncExternalStore, type ReactNode } from "react";
import { harnessSymbolsSnapshot, loadHarnessSymbol, subscribeHarnessIcons } from "../../shared/harnessIcons";
import { Icon } from "../icons/Icon";
import "./messageActionRow.css";

export const MESSAGE_ACTION_ICON = 16;

/// Every message kind uses this geometry; its existing class owns placement and visibility.
export function MessageActionRow({
  as: Tag = "span",
  className,
  children,
}: {
  as?: "span" | "div";
  className: string;
  children: ReactNode;
}) {
  return <Tag className={`cv-message-actions ${className}`}>{children}</Tag>;
}

// Fixed names only, through the host's existing validated, cached SF Symbol image operation.
const GLYPHS = {
  copy: ["doc.on.doc", "action.copy"],
  copied: ["checkmark", "action.confirm"],
  retry: ["arrow.counterclockwise", "action.reload"],
  menu: ["chevron.down", "disclosure.expanded"],
  pin: ["pin", "action.pin"],
  pinned: ["pin.fill", "action.pin"],
  fork: ["arrow.triangle.branch", "agent.fork"],
  speaker: ["speaker.wave.2", "media.audio"],
  more: ["ellipsis", "action.more"],
  edit: ["pencil", "action.edit"],
  previous: ["chevron.left", "nav.back"],
  next: ["chevron.right", "nav.forward"],
} as const;

/// Native pages draw the actual SF Symbol, not a hand-drawn approximation. A gallery/older host
/// without that image keeps the icon catalog fallback, in the same box and current text color.
export function MessageActionIcon({ name }: { name: keyof typeof GLYPHS }) {
  const [symbol, fallback] = GLYPHS[name];
  const images = useSyncExternalStore(subscribeHarnessIcons, harnessSymbolsSnapshot, harnessSymbolsSnapshot);
  useEffect(() => loadHarnessSymbol(symbol), [symbol]);
  const src = images.get(symbol);
  return src ? (
    <span
      aria-hidden="true"
      className="cv-message-action-symbol"
      data-symbol={symbol}
      style={{
        width: MESSAGE_ACTION_ICON,
        height: MESSAGE_ACTION_ICON,
        maskImage: `url("${src}")`,
        WebkitMaskImage: `url("${src}")`,
      }}
    />
  ) : (
    <Icon name={fallback} size={MESSAGE_ACTION_ICON} selected={name === "pinned"} />
  );
}
