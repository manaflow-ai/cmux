import { FolderIcon } from "./NewTabPage";
import { ProjectChooser, type Project } from "./ProjectChooser";
import { useT } from "./i18n";
import { EMPTY_STATE_LABELS, type EmptyStateStart } from "./emptyStateModel";
import { experimentArm } from "../../experiments/experiment";
import { emptyStateContext } from "./emptyStateContext.experiment";
import { TourOffer, type TourOfferActions } from "./repoTour/TourOffer";
/// The hero's project picker (cx-9g0w): the chat's folder choices and what a pick does.
export type EmptyStateProjects = {
  projects: Project[];
  /// The chat's project folder; none in no project (the agent-home folder).
  current?: string;
  currentPeer?: string;
  /// The chat is in no project (its agent-home folder): No folder is checked.
  noProject?: boolean;
  onPick(cwd: string, peer?: string): void;
  onBrowse?(): void;
  onNoProject?(): void;
};

export type { EmptyStateStart } from "./emptyStateModel";

/// A new chat's hero, centered in place of the empty transcript and kept quiet:
/// a small prompt glyph and one line naming the session's project. With `picker` the project's
/// name is a picker (ChatGPT style): a pick moves the new chat to that folder. With `tour`, a folder no chat has
/// used yet offers a repo tour under the question (repoTour/TourOffer.tsx).
export function EmptyState({
  project,
  picker,
  tour,
  starts,
}: {
  project?: string;
  picker?: EmptyStateProjects;
  tour?: TourOfferActions;
  starts?: readonly EmptyStateStart[];
}) {
  const t = useT();
  const contextual = experimentArm(emptyStateContext) === "contextual";
  const [before, after] = t(EMPTY_STATE_LABELS.promptIn).split("{project}");
  const chooser = picker && (
    <ProjectChooser
      projects={picker.projects}
      current={picker.current}
      currentPeer={picker.currentPeer}
      noProject={picker.noProject}
      {...(project ? { currentLabel: project } : {})}
      icon={<FolderIcon />}
      onPick={picker.onPick}
      onBrowse={picker.onBrowse}
      onNoProject={picker.onNoProject}
      side="bottom"
      inline
    />
  );
  return (
    <div className="acpmux-empty">
      <div className="acpmux-empty-title-anchor">
        <h2 className="acpmux-empty-title">
          {project ? (
            <>
              {before}
              {chooser ?? <span className="acpmux-empty-project">{project}</span>}
              {after}
            </>
          ) : (
            t(EMPTY_STATE_LABELS.prompt)
          )}
        </h2>
        {project && tour && <TourOffer {...tour} />}
      </div>
      {contextual && starts && starts.length > 0 && (
        <div className="acpmux-empty-starts">
          {starts.slice(0, 3).map((start) => (
            <button key={start.id} type="button" className="acpmux-empty-start" onClick={start.onPick}>
              <span className="acpmux-empty-start-label">{start.label}</span>
              {start.time && <span className="acpmux-empty-start-time">{start.time}</span>}
            </button>
          ))}
        </div>
      )}
      {/* No project yet: the picker sits under the question, so a folder can still be chosen. */}
      {!project && chooser && <div className="acpmux-empty-choose">{chooser}</div>}
    </div>
  );
}
