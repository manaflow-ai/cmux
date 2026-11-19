import { useExperimentSwitch } from "../../../experiments/switches";
import { usePaneLanguage, useT } from "../i18n";
import { GLASS_TOOLBAR_SWITCH } from "./glassToolbar.experiment";
import { useHeaderState } from "./headerState";

/**
 * The chat's name in the header: plain text, as Claude Code and ChatGPT desktop draw it. It is not
 * a dropdown and draws no pill (Leo, 2026-11-01: "still background on the top right ... why is
 * there a dropdown of this"); the chat's actions are in the header's ⋮ menu. A double-click renames,
 * as ⌘R does.
 *
 * With the glass toolbar on (Settings > Advanced > Experiments, `experiments.glassToolbarGroups`,
 * off by default) it reads as a window toolbar's title: the chat's workspace, with its chat count
 * under it, while the App has said which workspace that is; the chat's own name is the tooltip.
 * `glass` is the gallery's pick; else the person's switch.
 */
export function ThreadTitle({ title, onRename, glass }: { title: string; onRename?: () => void; glass?: boolean }) {
  const t = useT();
  const language = usePaneLanguage();
  const glassSwitch = useExperimentSwitch(GLASS_TOOLBAR_SWITCH);
  const { workspace } = useHeaderState();
  if ((glass ?? glassSwitch) && workspace)
    return (
      <span className="acpmux-thread-title acpmux-glass-title" title={title} onDoubleClick={onRename}>
        <span className="acpmux-glass-title-name">{workspace.title}</span>
        <span className="acpmux-glass-title-detail">
          {t("header.glassChats", {
            n: workspace.chats,
            count: new Intl.NumberFormat(language).format(workspace.chats),
          })}
        </span>
      </span>
    );
  return (
    <span className="acpmux-thread-title" title={title} onDoubleClick={onRename}>
      {title}
    </span>
  );
}
