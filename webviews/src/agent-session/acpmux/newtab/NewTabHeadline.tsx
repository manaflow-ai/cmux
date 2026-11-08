// New Tab's optional headline (Leo 2026-10-22: "new tab page let's have no greeting text by
// default... maybe as toggle but as useful toggle"), as Codex's New Tab asks it: "What should we work
// on in <project ▾>?", the project an inline picker (ProjectChooser, as the new chat's hero draws
// it). Off by default (`tabs.newTabWidgets.greeting`, pageWidgets.ts); never a time-of-day greeting.
// It names the machine the chat starts on too (Leo 2026-10-20: "what should we work on in projects in
// this machine... you can just also at the machine"): "What should we work on in cmux on cosmic-gray?".
// The machine is plain text that follows the location row's pick, not a second machine picker.
// Its look is the `new-tab-headline` experiment (headline.experiment.ts).
import { Fragment } from "react";
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
  /// The machine the chat starts on (the location row's pick, else this Mac's name); none names no
  /// machine, as before.
  machine?: string;
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
  const machine = props.machine ? <span className="nt-headline-machine">{props.machine}</span> : undefined;
  // The question's words around its project and machine, in the language's order (ja and zh put the
  // machine first).
  const template = project
    ? nt(machine ? "headline.inOn" : "headline.in")
    : machine
      ? nt("headline.on")
      : nt("headline");
  const parts = template
    .split(/(\{project\}|\{machine\})/)
    .map((part, index) =>
      part === "{project}" ? (
        <Fragment key={index}>{chooser}</Fragment>
      ) : part === "{machine}" ? (
        <Fragment key={index}>{machine}</Fragment>
      ) : (
        part
      ),
    );
  return (
    <div className="nt-headline" data-look={look}>
      <h1 className="nt-headline-text">{parts}</h1>
      {!project && <div className="nt-headline-choose">{chooser}</div>}
    </div>
  );
}
