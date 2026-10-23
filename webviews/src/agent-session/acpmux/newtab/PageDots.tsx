// The New Tab page's dots (Leo 2026-10-22: "first dot claude, second dot codex. since it's just all
// looks anyways. first 2 dots minimal on the new tab page"): first the composer's two looks
// (composerLook.ts), Claude's then Codex's, on every New Tab page; on Minimal, with the style dots
// widget off (newtab/pageWidgets.ts, its default), they are the only dots. A look dot switches the
// look only, in place: the page keeps its style, and every page draws the look (the screens'
// .nt-composer, Classic's .acpmux-newtab). With the style dots on (always on the other styles) the
// page's styles follow, Minimal among them, as the style switch had them (StyleSwitch.tsx).
import { COMPOSER_LOOK_NAMES, COMPOSER_LOOKS, setComposerLook, useComposerLook } from "../composerLook";
import { useT } from "../i18n";
import { DotSwitch, StyleSwitch } from "./StyleSwitch";
import { pageStyle, pickNewTabStyle, type NewTabTemplate, type PageStyle } from "./templates";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

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
  const t = useT();
  const look = useComposerLook();
  return (
    <div className="nt-page-dots">
      <DotSwitch
        options={COMPOSER_LOOKS}
        current={look}
        label={t("composer.look.label")}
        name={(option) => COMPOSER_LOOK_NAMES[option]}
        className="nt-style nt-look-dots"
        onPick={setComposerLook}
        onCancel={onCancel}
      />
      {styleDots && (
        <StyleSwitch
          current={pageStyle(template)}
          onCancel={onCancel}
          onPick={(style) => pickNewTabStyle(style, { callNative, show })}
        />
      )}
    </div>
  );
}
