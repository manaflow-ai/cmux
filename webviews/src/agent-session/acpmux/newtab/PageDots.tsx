// The New Tab page's dots (Leo 2026-10-23: "THE FIRST FUCKING DOT / THEN THE REST GOES TO SEPARATE
// DOTS"): the look dots on every New Tab page, Claude Minimal and Codex Minimal (tabDots.ts: a dot is
// the composer's look, no state of its own). A dot changes the look in place: the page keeps its
// style, and every page draws the look (the screens' .nt-composer, Classic's .acpmux-newtab). On
// every style but Minimal the other page styles follow in the same row, as the style switch had
// them (StyleSwitch.tsx); Minimal is the composer alone (Lawrence 2026-11-09: no widgets).
import { useComposerLook } from "../composerLook";
import { useT } from "../i18n";
import { useNt } from "./strings";
import { DotSwitch, StyleSwitch } from "./StyleSwitch";
import { dotName, NEW_TAB_DOTS, pickDot, shownDot } from "./tabDots";
import { pageStyle, pickNewTabStyle, type NewTabTemplate, type PageStyle } from "./templates";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

export function PageDots({
  template,
  callNative,
  show,
  onCancel,
}: {
  template: NewTabTemplate;
  callNative: Native;
  show(style: PageStyle): void;
  onCancel(): void;
}) {
  const t = useT();
  const nt = useNt();
  const look = useComposerLook();
  const style = pageStyle(template);
  return (
    <div className="nt-page-dots">
      <DotSwitch
        options={NEW_TAB_DOTS}
        current={shownDot(look)}
        label={t("composer.look.label")}
        name={(dot) => dotName(dot, nt)}
        className="nt-style nt-look-dots"
        onPick={pickDot}
        onCancel={onCancel}
      />
      {style !== "minimal" && (
        <StyleSwitch
          current={style}
          onCancel={onCancel}
          onPick={(next) => pickNewTabStyle(next, { callNative, show })}
        />
      )}
    </div>
  );
}
