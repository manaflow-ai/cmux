// A focusable listbox of actions (recent items): one Tab stop, Up/Down/Home/End move, typing a
// letter jumps to the next row starting with it, Return or Space opens, a click opens. Base UI 1.8
// has no standalone listbox, so this is the wrapper's one implementation (aria-activedescendant).
import { useId, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { cx } from "./cx";

export interface ListboxProps<T> {
  items: readonly T[];
  getKey(item: T): string;
  /** The text typeahead matches. */
  textValue(item: T): string;
  renderItem(item: T): ReactNode;
  itemAttributes?(item: T): Record<string, string | undefined>;
  label: string;
  onOpen(item: T): void;
  /** Takes focus when it mounts, so arrows and Return work at once. */
  autoFocus?: boolean;
  className?: string;
  rowClassName?: string;
}

const TYPEAHEAD_RESET_MS = 700;

export function Listbox<T>({
  items,
  getKey,
  textValue,
  renderItem,
  itemAttributes,
  label,
  onOpen,
  autoFocus = true,
  className,
  rowClassName,
}: ListboxProps<T>) {
  const [highlight, setHighlight] = useState(0);
  const focused = useRef(false);
  const typed = useRef({ text: "", at: 0 });
  const id = useId();
  const current = Math.min(highlight, items.length - 1);

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
      setHighlight(moves[event.key]);
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      const item = items[current];
      if (item) onOpen(item);
    } else if (event.key.length === 1 && /\S/.test(event.key)) {
      const now = event.timeStamp;
      const joined = now - typed.current.at > TYPEAHEAD_RESET_MS ? event.key : typed.current.text + event.key;
      typed.current = { text: joined, at: now };
      // The same letter again cycles through the rows starting with it.
      const text = /^(.)\1*$/su.test(joined) ? event.key : joined;
      const wanted = text.toLocaleLowerCase();
      const order = items.map((_, index) => (current + (text.length === 1 ? 1 : 0) + index) % items.length);
      const match = order.find((index) => textValue(items[index]).toLocaleLowerCase().startsWith(wanted));
      if (match !== undefined) {
        event.preventDefault();
        setHighlight(match);
      }
    }
  };

  return (
    <div
      ref={(element) => {
        if (!element || !autoFocus || focused.current) return;
        focused.current = true;
        element.focus({ preventScroll: true });
      }}
      className={cx("ui-listbox", className)}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a native select cannot hold rich rows.
      role="listbox"
      tabIndex={0}
      aria-label={label}
      aria-activedescendant={items.length ? `${id}-${current}` : undefined}
      onKeyDown={onKeyDown}
    >
      {items.map((item, index) => (
        <div
          key={getKey(item)}
          id={`${id}-${index}`}
          className={cx("ui-listbox-row", rowClassName)}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- rows of the listbox above.
          role="option"
          tabIndex={-1}
          aria-selected={index === current}
          {...itemAttributes?.(item)}
          onMouseMove={() => index !== current && setHighlight(index)}
          onMouseDown={(event) => {
            event.preventDefault();
            onOpen(item);
          }}
        >
          {renderItem(item)}
        </div>
      ))}
    </div>
  );
}
