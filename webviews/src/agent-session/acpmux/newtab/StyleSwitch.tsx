// The New Tab page's style switch (Leo 2026-10-13, cx-txe89): choosing the page's style, in one
// quiet row under the page. Its look is Debug Settings `newTab.styleSwitch` (Leo 2026-10-14 compares
// them before one ships; templates.ts STYLE_SWITCHES):
// - dots: one dot per style, drawn as before #20127 (the sidebar's space dots), named by tooltip;
// - hint (the default): those dots, and a pick's name over them for a moment;
// - strip: a small sketch of each style's layout, named by tooltip;
// - names: the style names (#20336).
// Every look is native radios (the browser owns arrows and focus), the current one on a small fill
// that slides to a new pick (none under Reduce Motion). No capsule, no popup.
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { ChoiceGroup } from "../../../ui/ChoiceGroup";
import { FOCUS_LOCATION_EVENT } from "../NewTabPage";
import { useNt } from "./strings";
import { DEFAULT_STYLE_SWITCH, PAGE_STYLES, type PageStyle, type StyleSwitchLook } from "./templates";

/// How long the hint look names a pick, fades included (screen.css `nt-style-flash`).
const FLASH_MS = 1100;

export function StyleSwitch({
  look = DEFAULT_STYLE_SWITCH,
  current,
  onPick,
  onCancel,
}: {
  look?: StyleSwitchLook;
  current: PageStyle;
  onPick(style: PageStyle): void;
  onCancel(): void;
}) {
  const nt = useNt();
  const group = useRef<HTMLDivElement>(null);
  const mark = useRef<HTMLSpanElement>(null);
  const pointed = useRef(Number.NEGATIVE_INFINITY);
  // The mark slides only after its first placement, so the page never opens with a slide.
  const [settled, setSettled] = useState(false);
  // The pick the hint look names; `count` restarts the name for a pick made while one shows.
  const [flash, setFlash] = useState<{ style: PageStyle; count: number } | null>(null);

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
  }, [current, settled, nt, look]);

  useEffect(() => {
    const view = group.current?.ownerDocument.defaultView;
    if (!flash || !view) return;
    const timer = view.setTimeout(() => setFlash(null), FLASH_MS);
    return () => view.clearTimeout(timer);
  }, [flash]);

  return (
    <ChoiceGroup label={nt("templates")} className="nt-style" onSubmit={onCancel} onCancel={onCancel}>
      <div ref={group} className="nt-style-options" data-look={look} data-settled={settled ? "" : undefined}>
        <span ref={mark} className="nt-style-mark" aria-hidden="true" />
        {PAGE_STYLES.map((style) => {
          const name = nt(`template.${style}`);
          return (
            <label
              key={style}
              className="nt-style-option"
              data-style={style}
              // The page shows a `title` at once (ui/titleTooltips.ts).
              title={look === "names" ? undefined : name}
              onPointerDown={() => (pointed.current = performance.now())}
            >
              <input
                className="nt-style-input"
                type="radio"
                name="nt-style"
                value={style}
                aria-label={name}
                checked={style === current}
                onChange={(event) => {
                  // A pointer down just before marks this one change as a click, not the next ones.
                  const fromKeys = performance.now() - pointed.current > 500;
                  pointed.current = Number.NEGATIVE_INFINITY;
                  const input = event.currentTarget;
                  onPick(style);
                  if (look === "hint") setFlash((last) => ({ style, count: (last?.count ?? 0) + 1 }));
                  // After the pick's commit, where a page that mounts for it (Classic, or a screen
                  // from Classic) has focused its field: arrow keys keep moving through the styles; a
                  // click goes back to the field.
                  const view = input.ownerDocument.defaultView;
                  view?.requestAnimationFrame(() =>
                    fromKeys ? input.focus() : view.dispatchEvent(new view.Event(FOCUS_LOCATION_EVENT)),
                  );
                }}
              />
              {look === "names" ? (
                <span aria-hidden="true">{name}</span>
              ) : look === "strip" ? (
                <StyleSketch style={style} />
              ) : (
                <span className="nt-style-dot" aria-hidden="true" />
              )}
            </label>
          );
        })}
        {flash && (
          // VoiceOver already hears the checked radio's name; this is the sighted echo.
          <span key={flash.count} className="nt-style-flash" aria-hidden="true">
            {nt(`template.${flash.style}`)}
          </span>
        )}
      </div>
    </ChoiceGroup>
  );
}

/// Each style's layout in 14px: the field as a rounded box, chats as lines.
const SKETCHES: Record<PageStyle, ReactNode> = {
  // The field, a few recent chats.
  default: (
    <>
      <rect x="2" y="2.5" width="10" height="4" rx="1.5" />
      <path d="M3 9h8M3 11.5h5" />
    </>
  ),
  // The field alone.
  composer: <rect x="2" y="5" width="10" height="4" rx="1.5" />,
  // The field, then every chat.
  threads: (
    <>
      <rect x="2" y="1.5" width="10" height="3" rx="1.2" />
      <path d="M3 7h8M3 9.5h8M3 12h8" />
    </>
  ),
  // A prompt.
  console: <path d="M3 4.5 6 7 3 9.5M7.5 10h3.5" />,
  // Terminal | Browser | Agent over the field.
  classic: (
    <>
      <path d="M2.5 3.5h2M6 3.5h2M9.5 3.5h2" />
      <rect x="2" y="6.5" width="10" height="5" rx="1.5" />
    </>
  ),
};

function StyleSketch({ style }: { style: PageStyle }) {
  return (
    <svg className="nt-style-sketch" viewBox="0 0 14 14" aria-hidden="true">
      {SKETCHES[style]}
    </svg>
  );
}
