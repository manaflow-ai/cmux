// New Tab's optional headline (Leo 2026-10-22: "new tab page let's have no greeting text by
// default... maybe as toggle but as useful toggle"), as Codex's New Tab asks it: "What should we work
// on in <project ▾>?", the project an inline picker (ProjectChooser, as the new chat's hero draws
// it). Off by default (`tabs.newTabWidgets.greeting`, pageWidgets.ts); never a time-of-day greeting.
// Its look is the `new-tab-headline` experiment (headline.experiment.ts).
import { experimentArm } from "../../../experiments/experiment";
import { FolderIcon } from "../NewTabPage";
import { ProjectChooser, type Project } from "../ProjectChooser";
import { projectName } from "../EmptyState";
import { newTabHeadline } from "./headline.experiment";
import { useNt } from "./strings";

export type NewTabHeadlineProps = {
  projects: Project[];
  /// The folder a prompt starts in (the composer's project); none in no project.
  folder?: string;
  /// Do not work in a project was picked: it is checked in the menu.
  noProject: boolean;
  onPick(cwd: string): void;
  onNoProject(): void;
  onBrowse?(): void;
};

/// The question over the composer. With a project, its name is the picker inside the question;
/// with none, the question ends there and Choose project sits under it, so a pick is one click.
export function NewTabHeadline(props: NewTabHeadlineProps) {
  const nt = useNt();
  const look = experimentArm(newTabHeadline);
  const project = projectName(props.folder);
  const chooser = (
    <ProjectChooser
      projects={props.projects}
      {...(props.folder ? { current: props.folder } : {})}
      noProject={props.noProject}
      {...(project ? { currentLabel: project } : {})}
      icon={<FolderIcon />}
      onPick={(cwd) => props.onPick(cwd)}
      {...(props.onBrowse ? { onBrowse: props.onBrowse } : {})}
      onNoProject={props.onNoProject}
      side="bottom"
      inline={look !== "chip"}
    />
  );
  const [before, after] = nt("headline.in").split("{project}");
  return (
    <div className="nt-headline" data-look={look}>
      <h1 className="nt-headline-text">
        {project ? (
          <>
            {before}
            {chooser}
            {after}
          </>
        ) : (
          nt("headline")
        )}
      </h1>
      {!project && <div className="nt-headline-choose">{chooser}</div>}
    </div>
  );
}
