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
import { EnvironmentIcon, EnvironmentPicker } from "../EnvironmentPicker";
import { ChevronIcon } from "../ComposerPickers";
import type { Environment } from "../environments";
import { useT } from "../i18n";

export type NewTabHeadlineProps = {
  projects: Project[];
  /// The folder a prompt starts in (the composer's project); none in no project.
  folder?: string;
  /// The machine whose project list this page represents. With no folder, the machine name is
  /// the inline picker label so the question makes its scope explicit (the list stays machine-wide).
  machineName?: string;
  machines?: Environment[];
  machineId?: string;
  onPickMachine?(id: string): void;
  /// Do not work in a project was picked: it is checked in the menu.
  noProject: boolean;
  onPick(cwd: string, peer?: string): void;
  onNoProject(): void;
  onBrowse?(): void;
};

/// The question over the composer. With a project, its name is the picker inside the question;
/// with none, the question ends there and Choose project sits under it, so a pick is one click.
export function NewTabHeadline(props: NewTabHeadlineProps) {
  const nt = useNt();
  const t = useT();
  const look = experimentArm(newTabHeadline);
  const project = projectName(props.folder);
  const machine = props.machineName?.trim();
  const selectedMachine = props.machines?.find((candidate) => candidate.id === props.machineId);
  const chooser = (
    <ProjectChooser
      projects={props.projects}
      {...(props.folder ? { current: props.folder } : {})}
      noProject={props.noProject}
      {...(project ? { currentLabel: project } : {})}
      icon={<FolderIcon />}
      onPick={(cwd, peer) => props.onPick(cwd, peer)}
      {...(props.onBrowse ? { onBrowse: props.onBrowse } : {})}
      onNoProject={props.onNoProject}
      side="bottom"
      inline={look !== "chip"}
    />
  );
  const machinePicker =
    machine && selectedMachine && props.onPickMachine ? (
      <span className="nt-headline-machine-picker">
        <EnvironmentPicker
          label={t("composer.computer")}
          menu="Computer"
          value={selectedMachine.label}
          face={
            <>
              <EnvironmentIcon kind={selectedMachine.kind} name={selectedMachine.label} />
              <span className="nt-headline-machine-label">{selectedMachine.label}</span>
              <ChevronIcon />
            </>
          }
          environments={props.machines ?? []}
          current={selectedMachine.id}
          onPick={props.onPickMachine}
        />
      </span>
    ) : (
      chooser
    );
  const [before, after] = nt("headline.in").split("{project}");
  const [machineBefore, machineAfter] = nt("headline.machine").split("{machine}");
  return (
    <div className="nt-headline" data-look={look}>
      <h1 className="nt-headline-text">
        {project ? (
          <>
            {before}
            {chooser}
            {after}
          </>
        ) : machine ? (
          <>
            {machineBefore}
            {machinePicker}
            {machineAfter}
          </>
        ) : (
          nt("headline")
        )}
      </h1>
      {!project && <div className="nt-headline-choose">{chooser}</div>}
    </div>
  );
}
