// The composer's EnvironmentPicker as the machine control (`rows="machines"`): This Mac, then N SSH
// machines, searchable, Add Machine… last. Its rows go through useRowPresence (rowPresence.ts): a
// machine that connects, arrives or goes while the list is open grows, shrinks or swaps in place.
// `window.__environmentCase` adds and drops a machine as the host's answer would.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { EnvironmentPicker, type MoveTarget } from "../../../src/agent-session/acpmux/EnvironmentPicker";
import type { Environment } from "../../../src/agent-session/acpmux/environments";
import "../../../src/agent-session/acpmux/styles.css";
import "../../../src/agent-session/acpmux/composerStates.css";
import "../../../src/agent-session/acpmux/composerLocation.css";
// The machine card's Continue on heading (MachineCard.tsx imports it in the app).
import "../../../src/agent-session/acpmux/machineCard.css";
import { caseItems, type VisibleListCase } from "./case";
import { paneStrings, openPopover, popoverControls } from "./popoverCase";

export interface EnvironmentCaseControls {
  /** A machine arrives after `afterIndex` (its row grows in). */
  add(afterIndex: number, id: string): void;
  /** A machine goes (its row shrinks out). */
  remove(id: string): void;
  ids(): string[];
}

let changeOne = () => {};

const machinesOf = (n: number): Environment[] => [
  { id: "local", label: "This Mac", kind: "local", connected: true },
  ...caseItems(n).map((item): Environment => ({ id: item.id, label: item.label, kind: "ssh", connected: true })),
];

function Machines({ n, card }: { n: number; card: boolean }) {
  const [environments, setEnvironments] = useState(() => machinesOf(n));
  useEffect(() => {
    // One machine's link drops: its row says so, in place.
    changeOne = () =>
      setEnvironments((previous) =>
        previous.map((machine, index) => (index === 3 ? { ...machine, connected: !machine.connected } : machine)),
      );
    (window as unknown as { __environmentCase: EnvironmentCaseControls }).__environmentCase = {
      add: (afterIndex, id) =>
        setEnvironments((previous) => [
          ...previous.slice(0, afterIndex + 1),
          { id, label: `arrived ${id}`, kind: "ssh", connected: true },
          ...previous.slice(afterIndex + 1),
        ]),
      remove: (id) => setEnvironments((previous) => previous.filter((machine) => machine.id !== id)),
      ids: () => environments.map((machine) => machine.id),
    };
  });
  const submitted = (id: string) => (window as unknown as { __submitted: string[] }).__submitted.push(id);
  // A started Cloud chat's card: its own row, then Continue on over every place it can go (the
  // first carries the hairline, `.acpmux-env-row[data-divider]`).
  const targets: MoveTarget[] = card
    ? caseItems(n).map((item) => ({ id: item.id, label: item.label, kind: "cloud" }))
    : [];
  return (
    <div className="acpmux-composer">
      <EnvironmentPicker
        label="Computer"
        menu="Computer"
        value="This Mac"
        face={<span className="case-environment-face">This Mac</span>}
        environments={environments}
        current="local"
        onPick={submitted}
        onConnect={(kind) => submitted(`connect:${kind}`)}
        {...(card
          ? {
              card: {
                header: <div className="case-card-header">Cloud machine</div>,
                actions: [{ id: "wake", text: "Wake machine", icon: null, run: () => submitted("wake") }],
                continueOn: "Continue on",
              },
              moveTargets: targets,
              onMoveTo: submitted,
            }
          : { rows: "machines" as const })}
      />
    </div>
  );
}

export function environmentCase(card: boolean): VisibleListCase {
  return {
    async mount(root, n) {
      await paneStrings();
      (window as unknown as { __submitted: string[] }).__submitted = [];
      flushSync(() => createRoot(root).render(<Machines n={n} card={card} />));
      await openPopover(root.querySelector<HTMLElement>(".acpmux-location-button")!);
      return popoverControls(["ComboboxOption", "EnvironmentIcon"], { changeOne: () => changeOne() });
    },
  };
}

export default environmentCase(false);
