import type { ReactNode } from "react";
import { ContextMenu } from "./ContextMenu";

/**
 * A piece of optional chrome that hides the macOS way (like Hide Mini): right-click it for
 * "Hide <name>", right-click the area it sat in for "Show <name>". `shown` and `setShown` are the
 * persisted setting, global to the app, so a hidden piece stays hidden everywhere and after a
 * relaunch; Settings can mirror the same setting.
 */
export interface HideableChromeItem {
  id: string;
  /** "Hide Dictation Button". */
  hideLabel: string;
  /** "Show Dictation Button". */
  showLabel: string;
  /** The thing's own icon, shown beside both labels. */
  icon?: ReactNode;
  shown: boolean;
  setShown(show: boolean): void;
}

/** The piece itself: nothing while hidden, and its right-click offers Hide. */
export function HideableChrome({
  item,
  className,
  onHide,
  children,
}: {
  item: HideableChromeItem;
  className?: string;
  /** Runs before the piece goes, such as ending a dictation session its button runs. */
  onHide?(): void;
  children: ReactNode;
}) {
  if (!item.shown) return null;
  return (
    <ContextMenu
      className={className}
      items={[
        {
          id: `hide-${item.id}`,
          label: item.hideLabel,
          icon: item.icon,
          onSelect: () => {
            onHide?.();
            item.setShown(false);
          },
        },
      ]}
    >
      {children}
    </ContextMenu>
  );
}

/**
 * The area hideable pieces sit in (a button row): its right-click offers Show for each hidden one.
 * A piece's own menu wins over the area's; with nothing hidden the area keeps no menu.
 */
export function ChromeArea({
  items,
  className,
  children,
}: {
  items: readonly HideableChromeItem[];
  className?: string;
  children: ReactNode;
}) {
  // Always the same wrapper, so hiding or showing a piece never remounts the row.
  const hidden = items.filter((item) => !item.shown);
  return (
    <ContextMenu
      className={className}
      // A popup a piece in the row opened (a picker and its search field) keeps its own menu.
      targets="own"
      items={hidden.map((item) => ({
        id: `show-${item.id}`,
        label: item.showLabel,
        icon: item.icon,
        onSelect: () => item.setShown(true),
      }))}
    >
      {children}
    </ContextMenu>
  );
}
