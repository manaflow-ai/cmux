// l10n-allow-file: bench fixture folder names, not shipped UI.
// The new chat's Projects picker (FolderPopover) alone, with N synthetic folders, for
// project-picker-open.bench.ts. `#n=1000` sets N. A stand-in host answers `project.icon` the way the
// app does (a glyph, after a tick) and counts the asks, so the badges' cost is in the numbers.
/// <reference types="vite/client" />
import { createRoot } from "react-dom/client";
import { FolderPopover, type FolderChoice } from "../../src/agent-session/acpmux/FolderPopover";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerLocation.css";

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);

declare global {
  interface Window {
    benchIconAsks: number;
    benchReady: boolean;
  }
}
window.benchIconAsks = 0;
(window as unknown as { webkit: unknown }).webkit = {
  messageHandlers: {
    agentSession: {
      postMessage: (message: { method: string }) => {
        if (message.method === "project.icon") window.benchIconAsks += 1;
        return new Promise((resolve) =>
          setTimeout(
            () => resolve({ ok: true, value: message.method === "project.icon" ? { glyph: "swift" } : {} }),
            1,
          ),
        );
      },
    },
  },
};

/// N folders the way a busy Mac lists them: about two in three are repositories of their own (the
/// host read their `.git`), the rest worktrees of a few of them (lane checkouts, `.worktrees`) and
/// plain folders the host said nothing about.
function syntheticFolders(count: number): FolderChoice[] {
  const folders: FolderChoice[] = [];
  const repos: { root: string; name: string; github: string }[] = [];
  for (let index = 0; folders.length < count; index++) {
    const kind = index % 6;
    if (kind <= 3 || repos.length === 0) {
      const name = `project-${index}`;
      const root = `/Users/leo/Projects/${name}`;
      const repo = { root, name, github: `acme/${name}` };
      repos.push(repo);
      folders.push({ id: root, label: name, repo: { ...repo, top: root, branch: "main" } });
    } else if (kind === 4) {
      const repo = repos[index % Math.min(repos.length, 40)]!;
      const branch = `lane-${index}`;
      const id = `/Users/leo/Projects/checkouts/${repo.name}/${branch}`;
      folders.push({ id, label: branch, repo: { ...repo, top: id, branch } });
    } else {
      const id = `/Users/leo/Projects/scratch/folder-${index}`;
      folders.push({ id, label: `folder-${index}` });
    }
  }
  return folders;
}

const folders = syntheticFolders(n);
const root = document.getElementById("root")!;
createRoot(root).render(
  // Not in a composer, at the top: the menu opens below, clear of the trigger, so the press's release
  // never lands on a row.
  <div style={{ position: "fixed", left: 40, top: 40, width: 600 }}>
    <FolderPopover
      label="Project"
      menu="Location"
      face={<span>Projects ▾</span>}
      folders={folders}
      current={folders[0]?.id}
      onPick={() => undefined}
      onBrowse={() => undefined}
      onNoProject={() => undefined}
      onNewWorktree={() => undefined}
    />
  </div>,
);
window.benchReady = true;
