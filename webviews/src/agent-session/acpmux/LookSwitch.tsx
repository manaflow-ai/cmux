// The composer's look dots in a chat (Leo 2026-10-22: "when you're in a chat you can also switch the
// dots if you hover on that bottom area"): the New Tab page's first two dots (newtab/PageDots.tsx),
// Claude's look then Codex's (composerLook.ts), in the composer's bottom area. In either look they
// sit in the quiet row's empty middle and show while the pointer is over that area or a dot has the keyboard, and fade when it leaves
// (composerLook.css `.acpmux-look-dots`). ComposerBox keeps one LookSwitch across a look change, so
// arrow keys go on switching and Escape goes back to the prompt. Where the row has no empty middle
// (a narrow pane, a long mode label) the dots would lie over a control and take its click though
// they are not drawn: there they stand aside (`data-crowded`, hidden) until the middle clears, as
// Codex's look hid them in a row too narrow for them (#28901). New Tab's dots still switch the look.
import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import { COMPOSER_LOOK_NAMES, COMPOSER_LOOKS, setComposerLook, useComposerLook } from "./composerLook";
import { useT } from "./i18n";
import { DotSwitch } from "./newtab/StyleSwitch";

export function LookSwitch({ onDone }: { onDone(): void }) {
  const t = useT();
  const look = useComposerLook();
  const slot = useRef<HTMLSpanElement>(null);
  const crowded = useCrowded(slot);
  return (
    <span ref={slot} className="acpmux-look-slot" data-crowded={crowded ? "" : undefined}>
      <DotSwitch
        options={COMPOSER_LOOKS}
        current={look}
        label={t("composer.look.label")}
        name={(option) => COMPOSER_LOOK_NAMES[option]}
        className="nt-style acpmux-look-dots"
        nameAside
        onPick={setComposerLook}
        onCancel={onDone}
      />
    </span>
  );
}

/// Whether the dots in `slot` lie over one of the quiet row's controls. Event-driven: a
/// ResizeObserver on the row, its controls and the dots, and a MutationObserver for controls that
/// come and go; both end on unmount.
function useCrowded(slot: RefObject<HTMLElement | null>): boolean {
  const [crowded, setCrowded] = useState(false);
  useLayoutEffect(() => {
    const dots = slot.current?.querySelector<HTMLElement>(".nt-style-options");
    const foot = slot.current?.closest(".acpmux-composer")?.querySelector<HTMLElement>(".acpmux-composer-foot");
    if (!dots || !foot || typeof ResizeObserver === "undefined") return;
    const controls = () => foot.querySelectorAll<HTMLElement>("button, [role='button'], input, select, a[href]");
    const measure = () => {
      // Hidden dots keep their box (visibility, not display), so this reads where they would draw.
      const own = dots.getBoundingClientRect();
      if (own.width <= 0) return setCrowded(false);
      setCrowded(
        [...controls()].some((control) => {
          const box = control.getBoundingClientRect();
          return (
            box.width > 0 &&
            box.left < own.right &&
            box.right > own.left &&
            box.top < own.bottom &&
            box.bottom > own.top
          );
        }),
      );
    };
    const sizes = new ResizeObserver(measure);
    const watch = () => {
      sizes.disconnect();
      for (const element of [foot, dots, ...controls()]) sizes.observe(element);
    };
    const children = new MutationObserver(() => {
      watch();
      measure();
    });
    children.observe(foot, { childList: true, subtree: true });
    watch();
    measure();
    return () => {
      sizes.disconnect();
      children.disconnect();
    };
  }, [slot]);
  return crowded;
}
