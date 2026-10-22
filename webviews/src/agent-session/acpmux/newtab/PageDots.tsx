// The New Tab page's dots (Leo 2026-10-22: "first dot claude, second dot codex. since it's just all
// looks anyways. first 2 dots minimal on the new tab page"): the first two are the Minimal page with
// the composer's two looks (composerLook.ts), Claude's then Codex's; they show on every New Tab page.
// With the style dots widget on (newtab/pageWidgets.ts, off by default on Minimal, always on the
// other styles) the page's other styles follow them, as the style switch had them (templates.ts).
import { COMPOSER_LOOK_NAMES, COMPOSER_LOOKS, setComposerLook, useComposerLook, type ComposerLook } from "../composerLook";
import { useNt } from "./strings";
import { DotSwitch } from "./StyleSwitch";
import { PAGE_STYLES, pageStyle, pickNewTabStyle, type NewTabTemplate, type PageStyle } from "./templates";

/// A dot: one of the Minimal page's two looks, or another page style.
export type PageDot = ComposerLook | Exclude<PageStyle, "minimal">;

function isLook(dot: PageDot): dot is ComposerLook {
  return COMPOSER_LOOKS.includes(dot as ComposerLook);
}

/// The dots in order: the two looks, then, with the style dots on, the other page styles.
export function pageDots(styleDots: boolean): PageDot[] {
  return [
    ...COMPOSER_LOOKS,
    ...(styleDots ? PAGE_STYLES.filter((style): style is Exclude<PageStyle, "minimal"> => style !== "minimal") : []),
  ];
}

/// The marked dot: on Minimal the composer's look, else the page's style.
export function currentPageDot(template: NewTabTemplate, look: ComposerLook): PageDot {
  const style = pageStyle(template);
  return style === "minimal" ? look : style;
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// A dot picked: a look is the Minimal page (written only when the page shows another style) with
/// that look for every composer; another style is that page, the look kept.
export function pickPageDot(
  dot: PageDot,
  template: NewTabTemplate,
  deps: { callNative: Native; show(style: PageStyle): void },
): void {
  if (!isLook(dot)) return pickNewTabStyle(dot, deps);
  setComposerLook(dot);
  if (pageStyle(template) !== "minimal") pickNewTabStyle("minimal", deps);
}

export function PageDots({
  template,
  styleDots,
  callNative,
  show,
  onCancel,
}: {
  template: NewTabTemplate;
  styleDots: boolean;
  callNative: Native;
  show(style: PageStyle): void;
  onCancel(): void;
}) {
  const nt = useNt();
  const look = useComposerLook();
  return (
    <DotSwitch
      options={pageDots(styleDots)}
      current={currentPageDot(template, look)}
      label={nt("templates")}
      radioName="nt-style"
      name={(dot) => (isLook(dot) ? COMPOSER_LOOK_NAMES[dot] : nt(`template.${dot}`))}
      onPick={(dot) => pickPageDot(dot, template, { callNative, show })}
      onCancel={onCancel}
    />
  );
}
