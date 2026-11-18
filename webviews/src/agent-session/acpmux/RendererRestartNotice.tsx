import { useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import { dismissRendererRestart, useRendererRestartLine } from "./rendererRestartStore";

/// One quiet line in the composer's notice slot after the app's watchdog ended this chat's hung
/// renderer and reloaded it (rendererRestartStore.ts): the app's own words, with Dismiss. Every
/// chat of that renderer draws its own, in its own pane.
export function RendererRestartNotice() {
  const t = useT();
  const line = useRendererRestartLine();
  return (
    <Notice id="renderer-restart" tier="status" when={line}>
      <output className="acpmux-switch-notice acpmux-folder-choice" data-renderer-restart="">
        <span>{line}</span>{" "}
        <button type="button" className="acpmux-folder-choice-button" onClick={dismissRendererRestart}>
          {t("dictation.dismiss")}
        </button>
      </output>
    </Notice>
  );
}
