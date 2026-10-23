// The New Tab page's style switch (Leo 2026-10-14, after cx-txe89): one small round dot per page
// style under the page, the current one in the accent (a dot that slides to a new pick) and the rest
// dim. A pointer over a dot shows its name over it; a pick shows the picked name for a moment, then
// fades it. Native radios carry the names (the browser owns arrows and focus) and fill each dot's
// hit target, larger than the dot. The row never changes size or place, so nothing shifts. The
// composer's look dots (newtab/PageDots.tsx, LookSwitch.tsx; Leo 2026-10-22) are the same dots
// (DotSwitch) over other options.
import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { ChoiceGroup } from "../../../ui/ChoiceGroup";
import { FOCUS_LOCATION_EVENT } from "../NewTabPage";
import { useNt } from "./strings";
import { PAGE_STYLES, type PageStyle } from "./templates";

/// How long a pick's name stays before it fades.
const PICKED_NAME_MS = 1100;

export function StyleSwitch({
  current,
  onPick,
  onCancel,
}: {
  current: PageStyle;
  onPick(style: PageStyle): void;
  onCancel(): void;
}) {
  const nt = useNt();
  return (
    <DotSwitch
      options={PAGE_STYLES}
      current={current}
      label={nt("templates")}
      name={(style) => nt(`template.${style}`)}
      radioName="nt-style"
      onPick={onPick}
      onCancel={onCancel}
      onPointerPick={(view) => view.dispatchEvent(new view.Event(FOCUS_LOCATION_EVENT))}
    />
  );
}

/// The dots over any options: the page's styles (StyleSwitch), or its and a chat's composer looks.
export function DotSwitch<Option extends string>({
  options,
  current,
  label: groupLabel,
  name,
  radioName,
  className = "nt-style",
  nameAside = false,
  onPick,
  onCancel,
  onPointerPick = () => onCancel(),
}: {
  options: readonly Option[];
  current: Option;
  /// The group's accessible name.
  label: string;
  /// A dot's name: over it while pointed at, and its radio's.
  name(option: Option): string;
  /// The radios' group name; unset, one of the switch's own.
  radioName?: string;
  className?: string;
  /// The name shows after the row, not over the dot (a chat's bottom area has no room over it).
  nameAside?: boolean;
  onPick(option: Option): void;
  /// Escape or Return in the group.
  onCancel(): void;
  /// After a pick by the pointer, in the dots' window: back to the field (unset, as onCancel).
  onPointerPick?(view: Window & typeof globalThis): void;
}) {
  const ownName = useId();
  const group = useRef<HTMLDivElement>(null);
  const mark = useRef<HTMLSpanElement>(null);
  const label = useRef<HTMLSpanElement>(null);
  // A pointer pressed a dot and no key has gone down since: the next pick is the pointer's.
  const pressed = useRef(false);
  // The mark slides only after its first placement, so the page never opens with a slide.
  const [settled, setSettled] = useState(false);
  // The dot whose name shows: the one pointed at, else the one just picked.
  const [hovered, setHovered] = useState<Option | undefined>();
  const [picked, setPicked] = useState<Option | undefined>();
  const named = hovered ?? picked;
  // The last name shown stays in place while it fades.
  const [shown, setShown] = useState<Option | undefined>();
  if (named && named !== shown) setShown(named);

  useEffect(() => {
    if (!picked) return;
    const timer = setTimeout(() => setPicked(undefined), PICKED_NAME_MS);
    return () => clearTimeout(timer);
  }, [picked]);

  useLayoutEffect(() => {
    const option = group.current?.querySelector<HTMLElement>(`[data-style="${current}"]`);
    if (!option || !mark.current) return;
    mark.current.style.transform = `translateX(${option.offsetLeft}px)`;
    const view = option.ownerDocument.defaultView;
    if (settled || !view) return;
    const frame = view.requestAnimationFrame(() => setSettled(true));
    return () => view.cancelAnimationFrame(frame);
  }, [current, settled]);

  useLayoutEffect(() => {
    const option = shown && group.current?.querySelector<HTMLElement>(`[data-style="${shown}"]`);
    if (option && label.current)
      label.current.style.left = nameAside
        ? `${group.current!.offsetWidth}px`
        : `${option.offsetLeft + option.offsetWidth / 2}px`;
  }, [shown, nameAside]);

  return (
    <ChoiceGroup label={groupLabel} className={className} onSubmit={onCancel} onCancel={onCancel}>
      <div
        ref={group}
        className="nt-style-options"
        data-settled={settled ? "" : undefined}
        onPointerOut={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setHovered(undefined);
        }}
      >
        <span ref={label} className="nt-style-name" aria-hidden="true" data-shown={named ? "" : undefined}>
          {shown ? name(shown) : ""}
        </span>
        <span ref={mark} className="nt-style-mark" aria-hidden="true" />
        {options.map((style) => (
          <label
            key={style}
            className="nt-style-option"
            data-style={style}
            onPointerOver={() => setHovered(style)}
            onPointerDown={() => (pressed.current = true)}
          >
            <input
              className="nt-style-input"
              type="radio"
              name={radioName ?? ownName}
              value={style}
              aria-label={name(style)}
              checked={style === current}
              onKeyDown={() => (pressed.current = false)}
              onChange={(event) => {
                // From the events, never a clock: a pointer's pick follows its press on a dot (a key
                // since clears it) or is a click that counts its presses (detail 1 or more); the
                // arrow keys' pick is a click of detail 0, or a plain change event. (By type, not
                // instanceof: the dots may sit in another window than this code's.)
                const native = event.nativeEvent;
                const clicked = native.type === "click" && (native as MouseEvent).detail > 0;
                const fromKeys = !pressed.current && !clicked;
                pressed.current = false;
                const input = event.currentTarget;
                onPick(style);
                setPicked(style);
                // Picked by keys, the new dot's name shows, not the one a resting pointer is over.
                if (fromKeys) setHovered(undefined);
                // After the pick's commit, where a page that mounts for it (Classic, or a screen
                // from Classic) has focused its field: arrow keys keep moving through the styles; a
                // click goes back to the field.
                const view = input.ownerDocument.defaultView;
                view?.requestAnimationFrame(() => (fromKeys ? input.focus() : onPointerPick(view)));
              }}
            />
          </label>
        ))}
      </div>
    </ChoiceGroup>
  );
}
