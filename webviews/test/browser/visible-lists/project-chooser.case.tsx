// The composer's ProjectChooser (one row per repository, Add folder… and No folder pinned under
// them), open over N folders with the current one in the middle of the list.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { ProjectChooser, type Project } from "../../../src/agent-session/acpmux/ProjectChooser";
import "../../../src/agent-session/acpmux/styles.css";
import "../../../src/agent-session/acpmux/composerStates.css";
import "../../../src/agent-session/acpmux/composerLocation.css";
import { caseItems, type VisibleListCase } from "./case";
import { paneStrings, openPopover, popoverControls } from "./popoverCase";

let changeOne = () => {};

export const projectsOf = (n: number): Project[] =>
  caseItems(n).map((item) => ({ cwd: `/Users/leo/Projects/${item.id}`, label: item.label }));

function Chooser({ n }: { n: number }) {
  const [projects, setProjects] = useState(() => projectsOf(n));
  useEffect(() => {
    changeOne = () =>
      setProjects((previous) =>
        previous.map((project, index) => (index === 2 ? { ...project, label: `${project.label}!` } : project)),
      );
  }, []);
  const current = projects[Math.floor(n / 2)]!;
  return (
    <ProjectChooser
      projects={projects}
      current={current.cwd}
      currentLabel={current.label}
      icon={null}
      side="bottom"
      onPick={(cwd) => (window as unknown as { __submitted: string[] }).__submitted.push(cwd)}
      onBrowse={() => undefined}
      onNoProject={() => undefined}
    />
  );
}

export default {
  async mount(root, n) {
    await paneStrings();
    (window as unknown as { __submitted: string[] }).__submitted = [];
    flushSync(() => createRoot(root).render(<Chooser n={n} />));
    await openPopover(root.querySelector<HTMLElement>(".acpmux-project-button")!);
    return popoverControls(["ComboboxOption", "ProjectBadge"], { changeOne: () => changeOne() });
  },
} satisfies VisibleListCase;
