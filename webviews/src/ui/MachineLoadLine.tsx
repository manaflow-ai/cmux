// The one load line of a machine row (machineLoad.ts): a state dot, its facts (cores busy of total,
// free RAM, live chats) and placement's verdict, the same in the composer's machine picker and in
// Settings > Machines. Each surface gives the words from its own catalog (`say`).
import { machineLoadText, type MachineLoad, type MachineLoadSay } from "./machineLoad";
import "./machineLoad.css";

export function MachineLoadLine({
  load,
  say,
  facts = true,
}: {
  load: MachineLoad;
  say: MachineLoadSay;
  /** Show the numbers before the verdict; a narrow row shows the verdict alone. */
  facts?: boolean;
}) {
  const text = machineLoadText(load, say);
  return (
    <span className="machine-load" data-machine-load={load.verdict}>
      <span className="machine-load-dot" aria-hidden="true" />
      {facts && text.facts.length > 0 && <span className="machine-load-facts">{text.facts.join(" · ")}</span>}
      <span className="machine-load-verdict">{text.verdict}</span>
    </span>
  );
}
