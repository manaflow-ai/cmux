// The New Tab page's style switch (Leo 2026-10-14, after cx-txe89): one small round dot per page
// style under the page, the current one in the accent (a dot that slides to a new pick) and the rest
// dim. A pointer over a dot shows its name over it; a pick shows the picked name for a moment, then
// fades it. Native radios carry the names (the browser owns arrows and focus) and fill each dot's
// hit target, larger than the dot. The row never changes size or place, so nothing shifts.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
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
  const group = useRef<HTMLDivElement>(null);
  const mark = useRef<HTMLSpanElement>(null);
  const label = useRef<HTMLSpanElement>(null);
  const pointed = useRef(0);
  // The mark slides only after its first placement, so the page never opens with a slide.
  const [settled, setSettled] = useState(false);
  // The dot whose name shows: the one pointed at, else the one just picked.
  const [hovered, setHovered] = useState<PageStyle | undefined>();
  const [picked, setPicked] = useState<PageStyle | undefined>();
  const named = hovered ?? picked;
  // The last name shown stays in place while it fades.
  const [shown, setShown] = useState<PageStyle | undefined>();
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
    if (option && label.current) label.current.style.left = `${option.offsetLeft + option.offsetWidth / 2}px`;
  }, [shown]);

  return (
    <ChoiceGroup label={nt("templates")} className="nt-style" onSubmit={onCancel} onCancel={onCancel}>
      <div
        ref={group}
        className="nt-style-options"
        data-settled={settled ? "" : undefined}
        onPointerOut={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setHovered(undefined);
        }}
      >
        <span ref={label} className="nt-style-name" aria-hidden="true" data-shown={named ? "" : undefined}>
          {shown ? nt(`template.${shown}`) : ""}
        </span>
        <span ref={mark} className="nt-style-mark" aria-hidden="true" />
        {PAGE_STYLES.map((style) => (
          <label
            key={style}
            className="nt-style-option"
            data-style={style}
            onPointerOver={() => setHovered(style)}
            onPointerDown={() => (pointed.current = performance.now())}
          >
            <input
              className="nt-style-input"
              type="radio"
              name="nt-style"
              value={style}
              aria-label={nt(`template.${style}`)}
              checked={style === current}
              onChange={(event) => {
                const fromKeys = performance.now() - pointed.current > 500;
                const input = event.currentTarget;
                onPick(style);
                setPicked(style);
                // Picked by keys, the new dot's name shows, not the one a resting pointer is over.
                if (fromKeys) setHovered(undefined);
                // After the pick's commit, where a page that mounts for it (Classic, or a screen
                // from Classic) has focused its field: arrow keys keep moving through the styles; a
                // click goes back to the field.
                const view = input.ownerDocument.defaultView;
                view?.requestAnimationFrame(() =>
                  fromKeys ? input.focus() : view.dispatchEvent(new view.Event(FOCUS_LOCATION_EVENT)),
                );
              }}
            />
          </label>
        ))}
      </div>
    </ChoiceGroup>
  );
}
