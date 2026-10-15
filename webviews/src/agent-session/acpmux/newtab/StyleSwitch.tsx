// The New Tab page's style switch (Leo 2026-10-13, cx-txe89): the old template dots looked,
// clicked and moved badly, but choosing the style was good. One quiet row of the style names under
// the page: native radios (the browser owns arrows and focus), the current one marked by a small
// fill that slides to a new pick. No capsule, no popup.
import { useLayoutEffect, useRef, useState } from "react";
import { ChoiceGroup } from "../../../ui/ChoiceGroup";
import { FOCUS_LOCATION_EVENT } from "../NewTabPage";
import { useNt } from "./strings";
import { PAGE_STYLES, type PageStyle } from "./templates";

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
  const pointed = useRef(0);
  // The mark slides only after its first placement, so the page never opens with a slide.
  const [settled, setSettled] = useState(false);

  useLayoutEffect(() => {
    const option = group.current?.querySelector<HTMLElement>(`[data-style="${current}"]`);
    const fill = mark.current;
    if (!option || !fill) return;
    fill.style.width = `${option.offsetWidth}px`;
    fill.style.transform = `translateX(${option.offsetLeft}px)`;
    const view = option.ownerDocument.defaultView;
    if (settled || !view) return;
    const frame = view.requestAnimationFrame(() => setSettled(true));
    return () => view.cancelAnimationFrame(frame);
  }, [current, settled, nt]);

  return (
    <ChoiceGroup label={nt("templates")} className="nt-style" onSubmit={onCancel} onCancel={onCancel}>
      <div ref={group} className="nt-style-options" data-settled={settled ? "" : undefined}>
        <span ref={mark} className="nt-style-mark" aria-hidden="true" />
        {PAGE_STYLES.map((style) => (
          <label
            key={style}
            className="nt-style-option"
            data-style={style}
            onPointerDown={() => (pointed.current = performance.now())}
          >
            <input
              className="ui-sr-only"
              type="radio"
              name="nt-style"
              value={style}
              aria-label={nt(`template.${style}`)}
              checked={style === current}
              onChange={(event) => {
                const fromKeys = performance.now() - pointed.current > 500;
                const input = event.currentTarget;
                onPick(style);
                // After the pick's commit, where a page that mounts for it (Classic, or a screen
                // from Classic) has focused its field: arrow keys keep moving through the styles; a
                // click goes back to the field.
                const view = input.ownerDocument.defaultView;
                view?.requestAnimationFrame(() =>
                  fromKeys ? input.focus() : view.dispatchEvent(new view.Event(FOCUS_LOCATION_EVENT)),
                );
              }}
            />
            <span aria-hidden="true">{nt(`template.${style}`)}</span>
          </label>
        ))}
      </div>
    </ChoiceGroup>
  );
}
