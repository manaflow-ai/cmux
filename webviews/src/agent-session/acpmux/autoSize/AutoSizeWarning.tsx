import { Notice } from "../../../ui/Notice";
import type { AutoSizeWarning } from "./autoSizeWarningModel";

export type AutoSizeWarningLabels = {
  title: string;
  resizeNow: string;
  runOnBuildMachine: string;
  carryOn: string;
};

export type AutoSizeWarningProps = {
  warning: AutoSizeWarning;
  labels: AutoSizeWarningLabels;
  onResizeNow(): void;
  onRunOnBuildMachine(): void;
  onCarryOn(): void;
};

/**
 * The presentation boundary for the known-heavy precheck. Rust decides when this row exists and
 * supplies its complete explanation. The host owns each action, so the gallery and the eventual
 * chat integration exercise the same callbacks.
 */
export function AutoSizeWarning({
  warning,
  labels,
  onResizeNow,
  onRunOnBuildMachine,
  onCarryOn,
}: AutoSizeWarningProps) {
  return (
    <div className="acpmux-autosize-warning" data-command={warning.command} data-project={warning.project}>
      <Notice
        id="autosize-warning"
        kind="warning"
        placement="inline"
        title={labels.title}
        message={warning.text}
        actions={[
          { id: "resize-now", label: labels.resizeNow, primary: true, onSelect: onResizeNow },
          { id: "run-on-build-machine", label: labels.runOnBuildMachine, onSelect: onRunOnBuildMachine },
          { id: "carry-on", label: labels.carryOn, onSelect: onCarryOn },
        ]}
      />
    </div>
  );
}
