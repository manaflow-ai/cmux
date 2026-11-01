// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { TrustRepo } from "./folderTrust";
import { TrustAsk } from "./TrustAsk";
import { answerFolder, type FolderTrustAsk } from "./useFolderTrustAsk";

type Props = {
  initialAsk: FolderTrustAsk;
};

const cwd = "/Users/leo/Projects/demo-app";
const repoRoot = "/Users/leo/Projects/atlas-web";
const inRepo = { cwd: `${repoRoot}/packages/fetch`, repo: { root: repoRoot, worktree: false } };
const worktree = {
  cwd: "/Users/leo/.cmux/worktrees/atlas-web/fix-retry",
  repo: { root: repoRoot, worktree: true } satisfies TrustRepo,
};
const atRoot = { cwd: repoRoot, repo: { root: repoRoot, worktree: false } };

function ask(state: FolderTrustAsk["state"], where: Pick<FolderTrustAsk, "cwd" | "repo" | "via"> = { cwd }) {
  if (state === "decided") return { ...where, state, level: "trusted" } as FolderTrustAsk;
  return { ...where, state } as FolderTrustAsk;
}

/// Answers as the pane does: Trust repo records the repository, so the folder reads "via repo".
function GalleryTrustAsk({ initialAsk }: Props) {
  const [current, setCurrent] = useState(initialAsk);
  const answer = (level: "trusted" | "untrusted", recorded: string) =>
    setCurrent({
      cwd: current.cwd,
      ...(current.repo ? { repo: current.repo } : {}),
      ...(recorded !== current.cwd ? { via: recorded } : {}),
      state: "decided",
      level,
    });
  return (
    <div className="acpmux-shell" data-trust-fixture>
      <div className="acpmux-composer">
        <TrustAsk
          ask={current}
          agent="Claude Code"
          onTrust={() => answer("trusted", current.cwd)}
          onTrustRepo={() => answer("trusted", answerFolder(current, "repo"))}
          onDistrust={() => answer("untrusted", answerFolder(current, "repo"))}
          onContinueWithoutFolder={() => undefined}
          onUndo={() => setCurrent({ cwd: current.cwd, ...(current.repo ? { repo: current.repo } : {}), state: "ask" })}
        />
      </div>
    </div>
  );
}

const text = (ctx: Parameters<Play>[0]) => ctx.document.querySelector(".acpmux-trust-ask-text")?.textContent;

const trustFolder: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Trust folder" });
  await ctx.waitFor(() => text(ctx) === "Trusted demo-app");
};

const trustRepo: Play = async (ctx) => {
  ctx.find({ role: "button", name: "Only this folder" });
  await ctx.click({ role: "button", name: "Trust repo" });
  await ctx.waitFor(() => text(ctx) === "Trusted via repo atlas-web");
};

const notNow: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Not now" });
  await ctx.waitFor(() => text(ctx) === "Not trusted: Claude Code won't run in the atlas-web repo");
};

const undo: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Undo" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Trust folder" }));
};

/// Not now is reversible without opening another surface: Trust stays the primary action.
const trustAfterNotNow: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Trust folder" });
  await ctx.waitFor(() => text(ctx) === "Trusted demo-app");
};

const trustRepoAfterNotNow: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Trust repo" });
  await ctx.waitFor(() => text(ctx) === "Trusted via repo atlas-web");
};

export default componentEntry<Props>({
  id: "agent-pane.trust-ask",
  title: "Folder trust ask",
  area: "Agent pane",
  height: 170,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-trust-fixture]" }],
  covers: ["agent-session/acpmux/TrustAsk.tsx#TrustAsk"],
  styles: () => import("./styles.css"),
  load: async () => GalleryTrustAsk,
  variants: {
    "grid-ask": {
      note: "Grid measurement: unanswered folder trust bar.",
      props: { initialAsk: ask("ask") },
    },
    ask: { note: "A folder outside any repository.", props: { initialAsk: ask("ask") }, play: trustFolder },
    "ask-repo": {
      note: "A folder inside a repository: Trust repo (every worktree), Only this folder, Not now.",
      props: { initialAsk: ask("ask", inRepo) },
      play: trustRepo,
    },
    "ask-worktree": {
      note: "A worktree cmux made: trusting the repository answers this and every other worktree once.",
      props: { initialAsk: ask("ask", worktree) },
      play: trustRepo,
    },
    "ask-repo-root": {
      note: "The repository's own folder: no separate Only this folder.",
      props: { initialAsk: ask("ask", atRoot) },
      play: notNow,
    },
    failed: { props: { initialAsk: ask("failed") } },
    remote: { props: { initialAsk: ask("remote") } },
    trusted: { props: { initialAsk: ask("decided") }, play: undo },
    "trusted-via-repo": { props: { initialAsk: ask("decided", { ...worktree, via: repoRoot }) } },
    "declined-folder": {
      height: 240,
      note: "Declined folder: text-only continuation leaves attachments in the original chat.",
      props: { initialAsk: { cwd, state: "decided", level: "untrusted" } },
    },
    "declined-repo": {
      height: 240,
      note: "Declined repository: continuation does not load its project hooks or config.",
      props: { initialAsk: { ...inRepo, via: repoRoot, state: "decided", level: "untrusted" } },
    },
    untrusted: {
      height: 240,
      note: "After Not now, the chat remains readable and Trust folder is the primary recovery action.",
      props: { initialAsk: { cwd, state: "decided", level: "untrusted" } },
      play: trustAfterNotNow,
    },
    "untrusted-repo": {
      height: 240,
      note: "After Not now on a repository, Trust repo remains the primary recovery action.",
      props: { initialAsk: { ...inRepo, via: repoRoot, state: "decided", level: "untrusted" } },
      play: trustRepoAfterNotNow,
    },
  },
});
