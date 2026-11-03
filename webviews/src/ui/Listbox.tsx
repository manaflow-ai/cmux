// A focusable listbox of actions (recent items): one Tab stop, Up/Down/Home/End move, typing a
// letter jumps to the next row starting with it, Return or Space opens, a click opens. Base UI 1.8
// has no standalone listbox, so this is the wrapper's one implementation (aria-activedescendant).
import {
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
  type Ref,
} from "react";
import { cx } from "./cx";
import { useScrollEdges } from "./scrollEdges";
import "./popupSurface.css";

export interface ListboxProps<T> {
  items: readonly T[];
  getKey(item: T): string;
  /** The text typeahead matches. */
  textValue(item: T): string;
  renderItem(item: T): ReactNode;
  itemAttributes?(item: T): Record<string, string | undefined>;
  getItemId?(item: T, index: number): string;
  label: string;
  onOpen(item: T): void;
  /** Takes focus when it mounts, so arrows and Return work at once. */
  autoFocus?: boolean;
  className?: string;
  rowClassName?: string;
  /** The row highlighted when it mounts (the chosen one); default the first. */
  initialIndex?: number;
  /** Controlled highlight for fields that keep focus in an editor (slash/@ suggestions). */
  activeIndex?: number;
  onActiveIndexChange?(index: number): void;
  listRef?: Ref<HTMLDivElement>;
  empty?: ReactNode;
  /** Content rendered after the rows, such as a loading or status note. */
  footer?: ReactNode;
  "aria-busy"?: boolean;
  id?: string;
}

const TYPEAHEAD_RESET_MS = 700;

export function Listbox<T>({
  items,
  getKey,
  textValue,
  renderItem,
  itemAttributes,
  getItemId,
  label,
  onOpen,
  autoFocus = true,
  className,
  rowClassName,
  initialIndex = 0,
  activeIndex,
  onActiveIndexChange,
  listRef: externalListRef,
  empty,
  footer,
  "aria-busy": ariaBusy,
  id: listId,
}: ListboxProps<T>) {
  const [highlight, setHighlight] = useState(Math.max(0, initialIndex));
  const currentHighlight = activeIndex ?? highlight;
  const setCurrentHighlight = (index: number) => {
    if (activeIndex === undefined) setHighlight(index);
    onActiveIndexChange?.(index);
  };
  const focused = useRef(false);
  const listEdges = useScrollEdges();
  const attachList = useCallback(
    (element: HTMLDivElement | null) => {
      listEdges(element);
      if (typeof externalListRef === "function") externalListRef(element);
      else if (externalListRef) externalListRef.current = element;
      if (!element || !autoFocus || focused.current) return;
      focused.current = true;
      element.focus({ preventScroll: true });
    },
    [autoFocus, externalListRef, listEdges],
  );
  const typed = useRef({ text: "", at: 0 });
  const id = useId();
  const current = Math.min(currentHighlight, items.length - 1);
  useEffect(() => {
    if (current < 0) return;
    const element = document.getElementById(
      getItemId?.(items[current], current) ?? `${id}-${current}`,
    );
    element?.scrollIntoView?.({ block: "nearest" });
  }, [current, getItemId, id, items]);

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    // Cmd, Ctrl and Option chords are the app's.
    if (event.metaKey || event.altKey || event.ctrlKey) return;
    const last = items.length - 1;
    const moves: Record<string, number> = {
      ArrowDown: Math.min(last, current + 1),
      ArrowUp: Math.max(0, current - 1),
      Home: 0,
      End: last,
    };
    if (event.key in moves) {
      event.preventDefault();
      setCurrentHighlight(moves[event.key]);
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      const item = items[current];
      if (item) onOpen(item);
    } else if (event.key.length === 1 && /\S/.test(event.key)) {
      const now = event.timeStamp;
      const joined =
        now - typed.current.at > TYPEAHEAD_RESET_MS ? event.key : typed.current.text + event.key;
      typed.current = { text: joined, at: now };
      // The same letter again cycles through the rows starting with it.
      const text = /^(.)\1*$/su.test(joined) ? event.key : joined;
      const wanted = text.toLocaleLowerCase();
      const order = items.map(
        (_, index) => (current + (text.length === 1 ? 1 : 0) + index) % items.length,
      );
      const match = order.find((index) =>
        textValue(items[index]).toLocaleLowerCase().startsWith(wanted),
      );
      if (match !== undefined) {
        event.preventDefault();
        setCurrentHighlight(match);
      }
    }
  };

  return (
    <div
      ref={attachList}
      id={listId}
      className={cx("ui-listbox ui-scroll-edge-fade", className)}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a native select cannot hold rich rows.
      role="listbox"
      tabIndex={0}
      aria-label={label}
      aria-busy={ariaBusy || undefined}
      aria-activedescendant={
        items.length ? (getItemId?.(items[current], current) ?? `${id}-${current}`) : undefined
      }
      onKeyDown={onKeyDown}
    >
      {items.map((item, index) => (
        <div
          key={getKey(item)}
          id={getItemId?.(item, index) ?? `${id}-${index}`}
          className={cx("ui-listbox-row", rowClassName)}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- rows of the listbox above.
          role="option"
          tabIndex={-1}
          aria-selected={index === current}
          {...itemAttributes?.(item)}
          onMouseMove={() => index !== current && setCurrentHighlight(index)}
          onMouseDown={(event) => {
            // Secondary/middle press and macOS Control-click keep the system context menu.
            if (event.button !== 0 || event.ctrlKey) return;
            event.preventDefault();
            onOpen(item);
          }}
        >
          {renderItem(item)}
        </div>
      ))}
      {items.length === 0 && empty}
      {footer}
    </div>
  );
}
