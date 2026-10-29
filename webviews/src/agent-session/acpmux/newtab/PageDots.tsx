// The New Tab page's dots (Leo 2026-10-23: "THE FIRST FUCKING DOT / THEN THE REST GOES TO SEPARATE
// DOTS ... 1 CLAUDE MINIMAL / 2 CLAUDE MINIMAL + NEW TAB/TERMINAL/WHATEVER / 3 CODEX MINIMAL"):
// three dots on every New Tab page, Claude Minimal, Claude Minimal with the quick action pills, and
// Codex Minimal (tabDots.ts: a dot is the composer's look and the quick actions widget, no state of
// its own). A dot changes the look and the pills in place: the page keeps its style, and every page
// draws the look (the screens' .nt-composer, Classic's .acpmux-newtab). The other page styles are
// not dots: with the style dots widget on (off by default on Minimal, always on the other styles)
// they follow in the same row, as the style switch had them (StyleSwitch.tsx).
import { useComposerLook } from "../composerLook";
import { useT } from "../i18n";
import type { WidgetEdit } from "./pageWidgets";
import { useNt } from "./strings";
import { DotSwitch, StyleSwitch } from "./StyleSwitch";
import { dotName, NEW_TAB_DOTS, pickDot, shownDot } from "./tabDots";
import { pageStyle, pickNewTabStyle, type NewTabTemplate, type PageStyle } from "./templates";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

export function PageDots({
  template,
  styleDots,
  actions,
  callNative,
  show,
  showWidgets,
  onCancel,
}: {
  template: NewTabTemplate;
  styleDots: boolean;
  /// Whether the quick actions widget is on (`tabs.newTabWidgets.actions`): the second dot.
  actions: boolean;
  callNative: Native;
  show(style: PageStyle): void;
  /// A dot's widget edit, shown in place at once (the host saves it).
  showWidgets(edit: WidgetEdit): void;
  onCancel(): void;
}) {
  const t = useT();
  const nt = useNt();
  const look = useComposerLook();
  return (
    <div className="nt-page-dots">
      <DotSwitch
        options={NEW_TAB_DOTS}
        current={shownDot(look, actions)}
        label={t("composer.look.label")}
        name={(dot) => dotName(dot, nt)}
        className="nt-style nt-look-dots"
        onPick={(dot) => pickDot(dot, { actions, callNative, show: showWidgets })}
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
