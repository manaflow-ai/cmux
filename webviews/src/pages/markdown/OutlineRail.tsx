// The heading outline rail: one short dash per heading at the left of the document, shorter and
// further in for deeper levels, the reader's current section highlighted. Pointing at the rail
// (or a click, or Return on it) opens the table of contents beside it, the headings by name; a
// heading there scrolls to its section. A file with fewer than two headings shows no rail.
import { useEffect, useRef, useState, useSyncExternalStore, type KeyboardEvent } from "react";
import { focusRoute } from "../../ui/focusRoute";
import type { Strings } from "../shared/i18n";
import type { Outline } from "./outline";
import { L } from "./strings";

/** How the panel is open: by pointing (closes when the pointer leaves) or pinned by a click. */
type OpenState = "hover" | "pinned" | null;

export function OutlineRail({ outline, strings }: { outline: Outline; strings: Strings }) {
  const { headings, active } = useSyncExternalStore(outline.subscribe, outline.getState);
  const [open, setOpen] = useState<OpenState>(null);
  const rail = useRef<HTMLButtonElement | null>(null);
  const show = headings.length >= 2;
  useEffect(() => (show ? outline.attach() : undefined), [outline, show]);
  if (!show) return null;
  const top = Math.min(...headings.map((heading) => heading.level));
  const label = strings.t(L.outlineLabel);
  const close = (focusRail: boolean) => {
    setOpen(null);
    if (focusRail) focusRoute(rail.current, "person", "Escape closed the outline contents");
  };
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key !== "Escape" || !open) return;
    event.stopPropagation();
    close(true);
  };
  return (
    <div className="md-outline-host">
      {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape closes the contents from any of its buttons, and leaving the outline closes a hover-opened panel. */}
      <nav
        className="md-outline"
        aria-label={label}
        data-open={open ?? undefined}
        onPointerLeave={() => setOpen((state) => (state === "hover" ? null : state))}
        onKeyDown={onKeyDown}
      >
        <button
          ref={rail}
          type="button"
          className="md-outline-rail"
          aria-label={strings.t(L.outlineShow)}
          aria-expanded={open !== null}
          onPointerEnter={() => setOpen((state) => state ?? "hover")}
          onClick={() => setOpen((state) => (state === "pinned" ? null : "pinned"))}
        >
          {headings.map((heading, index) => (
            <span
              key={`${heading.pos}:${heading.slug}`}
              className="md-outline-dash"
              data-depth={Math.min(heading.level - top, 3)}
              data-active={index === active || undefined}
            />
          ))}
        </button>
        {open ? (
          <ol className="md-outline-panel">
            {headings.map((heading, index) => (
              <li key={`${heading.pos}:${heading.slug}`}>
                <button
                  type="button"
                  className="md-outline-item"
                  data-depth={Math.min(heading.level - top, 3)}
                  aria-current={index === active ? "location" : undefined}
                  onClick={() => {
                    outline.go(heading.slug);
                    close(false);
                  }}
                >
                  {heading.text}
                </button>
              </li>
            ))}
          </ol>
        ) : null}
      </nav>
    </div>
  );
}
