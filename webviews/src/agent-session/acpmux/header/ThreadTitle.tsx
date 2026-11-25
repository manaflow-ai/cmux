import { Fragment } from "react";
import { useExperimentSwitch } from "../../../experiments/switches";
import type { HarnessIconSpec } from "../../shared/harnessIcons";
import { AgentIdentityChip, type FkaTreatment } from "../AgentIdentityChip";
import { intl } from "../../../ui/intl";
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
 *
 * With Header Path on (`agentPane.display.headerBreadcrumb`, off by default; Taste Board #20), `trail`
 * (headerState.ts `headerBreadcrumb`: repository, branch) leads the title as one monospace slash path,
 * `repo / branch / title`, its separators fainter. The title segment stays the rename target. With no
 * trail the title draws exactly as before.
 *
 * The chat's identity (Leo, 2026-11-22: "BUT WHO IS MANGO?"): the icon it set (acpmux `icon`) else
 * its harness's mark before the name, and the newest name it had before a rename as a quiet "fka"
 * after it (AgentIdentityChip.tsx); the tooltip lists every former name.
 */
export function ThreadTitle({
  title,
  onRename,
  trail,
  glass,
  icon,
  harness,
  formerNames,
  fka,
}: {
  title: string;
  onRename?: () => void;
  trail?: readonly string[];
  glass?: boolean;
  icon?: HarnessIconSpec;
  harness?: string;
  formerNames?: readonly string[];
  fka?: FkaTreatment;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const glassSwitch = useExperimentSwitch(GLASS_TOOLBAR_SWITCH);
  const { workspace } = useHeaderState();
  if ((glass ?? glassSwitch) && workspace)
    return (
      <span className="acpmux-thread-title acpmux-glass-title" onDoubleClick={onRename}>
        <span className="acpmux-glass-title-name">{workspace.title}</span>
        <span className="acpmux-glass-title-detail">
          {t("header.glassChats", {
            n: workspace.chats,
            count: intl.NumberFormat(language).format(workspace.chats),
          })}
        </span>
      </span>
    );
  // No tooltip on the title or the path: their text shows (the tooltip cuts: a tooltip only names a
  // control that shows no text of its own).
  const name = (
    <span className="acpmux-thread-title" onDoubleClick={onRename}>
      {icon || harness || formerNames?.length ? (
        <AgentIdentityChip
          name={title}
          {...(icon && { icon })}
          {...(harness && { harness })}
          {...(formerNames && { formerNames })}
          {...(fka && { fka })}
        />
      ) : (
        title
      )}
    </span>
  );
  if (!trail?.length) return name;
  return (
    <span className="acpmux-thread-crumbs">
      {trail.map((part, index) => (
        <Fragment key={index}>
          <span className="acpmux-thread-crumb">{part}</span>
          <span className="acpmux-thread-crumb-sep" aria-hidden="true">
            {" / "}
          </span>
        </Fragment>
      ))}
      {name}
    </span>
  );
}
