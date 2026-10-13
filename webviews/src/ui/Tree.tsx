// A focusable tree (a file tree): one Tab stop, Up/Down/Home/End move, Right opens a folder and then
// steps into it, Left closes it and then steps to its parent, Return or Space activates, and typing
// selects the next row whose text starts with it. A click selects and toggles a folder; a double
// click activates a leaf. The caller owns the selection and which folders are open; notes (a folder's
// "loading" or "empty" line) sit between rows but are never selected. Base UI 1.8 has no tree, so
// this is the wrapper's one implementation (aria-activedescendant), as Listbox is for lists.
import { useEffect, useId, useRef, type CSSProperties, type KeyboardEvent, type ReactNode } from "react";
import { cx } from "./cx";

export interface TreeItem {
  kind: "item";
  key: string;
  /** 0 for the root's children. */
  depth: number;
  /** The text typeahead matches. */
  text: string;
  expandable: boolean;
  expanded: boolean;
  content: ReactNode;
}

export interface TreeNote {
  kind: "note";
  key: string;
  content: ReactNode;
}

export type TreeLine = TreeItem | TreeNote;

export interface TreeProps {
  /** Every visible line, in order. */
  lines: readonly TreeLine[];
  selected?: string;
  label: string;
  onSelect(key: string): void;
  onExpand(key: string, open: boolean): void;
  onActivate(item: TreeItem): void;
  /** Takes focus when it mounts and whenever its window comes forward. */
  autoFocus?: boolean;
  className?: string;
  rowClassName?: string;
  rowStyle?(item: TreeItem): CSSProperties;
}

const TYPEAHEAD_RESET_MS = 600;

export function Tree({
  lines,
  selected,
  label,
  onSelect,
  onExpand,
  onActivate,
  autoFocus = true,
  className,
  rowClassName,
  rowStyle,
}: TreeProps) {
  const element = useRef<HTMLDivElement>(null);
  const typed = useRef({ text: "", at: 0 });
  const id = useId();
  const rowId = (key: string) => `${id}-${encodeURIComponent(key)}`;
  const items = lines.filter((line): line is TreeItem => line.kind === "item");
  const index = items.findIndex((item) => item.key === selected);
  const current = index >= 0 ? items[index] : undefined;

  useEffect(() => {
    if (!autoFocus) return;
    const focus = () => element.current?.focus({ preventScroll: true });
    focus();
    window.addEventListener("focus", focus);
    return () => window.removeEventListener("focus", focus);
  }, [autoFocus]);

  // The selected row stays in view as the keys move it.
  useEffect(() => {
    if (selected !== undefined)
      element.current?.ownerDocument.getElementById(rowId(selected))?.scrollIntoView({ block: "nearest" });
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- rowId only reads the stable useId.
  }, [selected]);

  const move = (to: number) => {
    const item = items[Math.max(0, Math.min(items.length - 1, to))];
    if (item) onSelect(item.key);
  };
  const parent = (item: TreeItem) =>
    items
      .slice(0, items.indexOf(item))
      .reverse()
      .find((row) => row.depth < item.depth);

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    // Cmd, Ctrl and Option chords are the app's.
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const handled = (() => {
      switch (event.key) {
        case "ArrowDown":
          return (move(index + 1), true);
        case "ArrowUp":
          return (move(index < 0 ? 0 : index - 1), true);
        case "Home":
          return (move(0), true);
        case "End":
          return (move(items.length - 1), true);
        case "ArrowRight":
          if (!current?.expandable) return false;
          if (current.expanded) move(index + 1);
          else onExpand(current.key, true);
          return true;
        case "ArrowLeft": {
          if (!current) return false;
          const up = current.expanded ? undefined : parent(current);
          if (current.expanded) onExpand(current.key, false);
          else if (up) onSelect(up.key);
          return true;
        }
        case "Enter":
        case " ":
          return current ? (onActivate(current), true) : false;
      }
      if (event.key.length !== 1) return false;
      const now = event.timeStamp;
      const text = (now - typed.current.at < TYPEAHEAD_RESET_MS ? typed.current.text : "") + event.key.toLowerCase();
      typed.current = { text, at: now };
      const start = text.length === 1 ? index + 1 : Math.max(0, index);
      const order = [...items.slice(start), ...items.slice(0, start)];
      const match = order.find((item) => item.text.toLowerCase().startsWith(text));
      if (match) onSelect(match.key);
      return true;
    })();
    if (handled) event.preventDefault();
  };

  return (
    <div
      ref={element}
      className={cx("ui-tree", className)}
      role="tree"
      tabIndex={0}
      aria-label={label}
      aria-activedescendant={current ? rowId(current.key) : undefined}
      onKeyDown={onKeyDown}
    >
      {lines.map((line) =>
        line.kind === "note" ? (
          <div key={line.key}>{line.content}</div>
        ) : (
          // The tree above owns focus and every key, so a row takes only the pointer.
          // oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/interactive-supports-focus
          <div
            key={line.key}
            id={rowId(line.key)}
            className={cx("ui-tree-row", rowClassName, line.key === selected && "is-selected")}
            role="treeitem"
            aria-level={line.depth + 1}
            aria-selected={line.key === selected}
            aria-expanded={line.expandable ? line.expanded : undefined}
            style={rowStyle?.(line)}
            onPointerDown={() => {
              onSelect(line.key);
              element.current?.focus({ preventScroll: true });
            }}
            onClick={() => line.expandable && onExpand(line.key, !line.expanded)}
            onDoubleClick={() => !line.expandable && onActivate(line)}
          >
            {line.content}
          </div>
        ),
      )}
    </div>
  );
}
