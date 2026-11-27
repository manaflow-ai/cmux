// Add folder's AddProjectPanel at its directory step, listing a folder of N directories (a home
// folder with thousands is real): a stand-in host lists them, the way the gallery's does.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { AddProjectPanel } from "../../../src/agent-session/acpmux/AddProjectPanel";
import type { ProjectDirectoryHost } from "../../../src/agent-session/acpmux/projectDirectory";
import "../../../src/agent-session/acpmux/styles.css";
import "../../../src/agent-session/acpmux/composerStates.css";
import { caseItems, type VisibleListCase } from "./case";
import { paneStrings, listbox, popoverControls, until } from "./popoverCase";

const HOME = "/Users/leo";

export default {
  async mount(root, n) {
    await paneStrings();
    (window as unknown as { __submitted: string[] }).__submitted = [];
    const directories = caseItems(n).map((item) => `${HOME}/${item.label}`);
    // A picked directory opens: its path is the pick.
    const host: ProjectDirectoryHost = {
      list: async (path) => {
        if (path === "~" || path === HOME) return { path: HOME, parent: "/Users", home: HOME, directories };
        (window as unknown as { __submitted: string[] }).__submitted.push(path);
        return { path, parent: HOME, home: HOME, directories: [] };
      },
      reveal: async () => undefined,
    };
    // The panel draws in its dialog's place: a box of the dialog's size.
    root.style.cssText = "width: 560px; height: 520px; display: flex; flex-direction: column;";
    flushSync(() =>
      createRoot(root).render(
        <AddProjectPanel
          host={host}
          localName="This Mac"
          onPick={(path) => (window as unknown as { __submitted: string[] }).__submitted.push(path)}
          onClose={() => undefined}
        />,
      ),
    );
    // This Mac, then Local folder: the directory step.
    await until(() => !!root.querySelector('[role="option"]'), "the environment step");
    root.querySelector<HTMLElement>('[role="option"]')!.click();
    await until(() => root.querySelector('[data-add-project-step="source"]') !== null, "the source step");
    root.querySelector<HTMLElement>('[role="option"]')!.click();
    await until(() => (listbox()?.querySelectorAll('[role="option"]').length ?? 0) > 1, "the directory listing");
    const controls = popoverControls(["ComboboxOption", "FolderIcon"]);
    return { ...controls, list: () => root, resizeTarget: () => root };
  },
} satisfies VisibleListCase;
