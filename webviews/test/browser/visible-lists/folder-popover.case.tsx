// The new chat's FolderPopover over N folders (about one in six a worktree of an earlier repository,
// grouped under it). `folderCase(false)`: no actions, so no pinned rows; `folderCase(true)`: Add
// folder…, New Worktree and No folder pinned under the list, and a Cloud chat's GitHub repositories
// listed first, so the GitHub heading and This Mac's sit in their first rows' top margins
// (composerLocation.css `data-section`, margin-top 18-20px).
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { FolderPopover, type FolderChoice } from "../../../src/agent-session/acpmux/FolderPopover";
import type { GitHubPicker } from "../../../src/agent-session/acpmux/githubRepos";
import "../../../src/agent-session/acpmux/styles.css";
import "../../../src/agent-session/acpmux/composerStates.css";
import "../../../src/agent-session/acpmux/composerLocation.css";
import { caseItems, type VisibleListCase } from "./case";
import { paneStrings, openPopover, popoverControls } from "./popoverCase";

export function foldersOf(n: number): FolderChoice[] {
  const repos: { root: string; name: string; github: string }[] = [];
  return caseItems(n).map((item, index) => {
    if (index % 6 === 4 && repos.length > 0) {
      const repo = repos[index % repos.length]!;
      const id = `/Users/leo/Projects/checkouts/${repo.name}/${item.id}`;
      return { id, label: item.label, repo: { ...repo, top: id, branch: item.id } };
    }
    const root = `/Users/leo/Projects/${item.id}`;
    const repo = { root, name: item.id, github: `acme/${item.id}` };
    repos.push(repo);
    return { id: root, label: item.label, repo: { ...repo, top: root, branch: "main" } };
  });
}

const github: GitHubPicker = {
  state: {
    status: { state: "ready", reposScope: "all" },
    repos: Array.from({ length: 30 }, (_, index) => ({
      fullName: `acme/repository-${index}`,
      private: false,
      defaultBranch: "main",
    })),
    query: null,
    truncated: false,
    loading: false,
    waiting: false,
  },
  onOpen: () => undefined,
  onConnect: () => undefined,
  onSearch: () => undefined,
  onRetry: () => undefined,
};

export function folderCase(pinned: boolean): VisibleListCase {
  return {
    async mount(root, n) {
      await paneStrings();
      (window as unknown as { __submitted: string[] }).__submitted = [];
      const folders = foldersOf(n);
      const submitted = (value: string) =>
        void (window as unknown as { __submitted: string[] }).__submitted.push(value);
      flushSync(() =>
        createRoot(root).render(
          <FolderPopover
            label="Project"
            menu="Location"
            face={<span>Projects</span>}
            folders={folders}
            current={folders[Math.floor(n / 2)]?.id}
            onPick={submitted}
            {...(pinned
              ? {
                  onBrowse: () => undefined,
                  onNewWorktree: () => undefined,
                  onNoProject: () => undefined,
                  github,
                  githubFirst: true,
                }
              : {})}
          />,
        ),
      );
      await openPopover(root.querySelector<HTMLElement>(".acpmux-location-button")!);
      return popoverControls(["ComboboxOption", "ProjectBadge"]);
    },
  };
}

export default folderCase(false);
