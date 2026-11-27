import { useExperimentSwitch } from "../../experiments/switches";
import { pointOnVisualViewport } from "../../ui/visualViewportBox";
import { useT } from "./i18n";
import { postNative } from "./native";
import "./composerCustomizer.css";

// The Customize button centered in the quiet row under the chat box (Leo, 2026-11-24: "give my
// nightly some [thing] that i can click in a noticeable spot, say under the middle area of the
// composer, maybe on hover?"). Off by default: Settings > Advanced > Experiments > Customize Button
// Under the Composer (`experiments.composerCustomizer`). It shows while the pointer is over the
// composer or the prompt has focus (composerCustomizer.css). It sits out of the row's flow
// (position: absolute), so the row's fit (composerRowFit.ts) never counts it, and it hides where the
// row has no room for it. A click asks the app for the menu; the lists and groupings are the app's
// (SettingsSchema.quickToggleGroups), so a new switch shows here without a page change.
export function ComposerCustomizer() {
  const on = useExperimentSwitch("composerCustomizer");
  const t = useT();
  if (!on) return null;
  const open = (event: React.MouseEvent<HTMLButtonElement>) => {
    const box = event.currentTarget.getBoundingClientRect();
    const point = pointOnVisualViewport({ x: box.left + box.width / 2, y: box.bottom }, window);
    // `customizations.menu` pops the app's Customizations menu (CustomizationsMenu.swift, the menu
    // bar's) with its top at `point`, the button's bottom center in CSS px of the page's viewport.
    void postNative("customizations.menu", { point }).catch(() => undefined);
  };
  return (
    <button
      type="button"
      className="acpmux-composer-customize"
      data-composer-customize=""
      aria-haspopup="menu"
      onMouseDown={(event) => event.preventDefault()}
      onClick={open}
    >
      <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
        <path
          d="M2 4h7M12 4h2M2 8h2M7 8h7M2 12h9M14 12h0"
          stroke="currentColor"
          strokeWidth="1.4"
          strokeLinecap="round"
          fill="none"
        />
        <circle cx="10.5" cy="4" r="1.5" stroke="currentColor" strokeWidth="1.3" fill="none" />
        <circle cx="5.5" cy="8" r="1.5" stroke="currentColor" strokeWidth="1.3" fill="none" />
        <circle cx="12.5" cy="12" r="1.5" stroke="currentColor" strokeWidth="1.3" fill="none" />
      </svg>
      <span>{t("composer.customize")}</span>
    </button>
  );
}
