// l10n-allow-file: gallery fixtures (sample paths, git output), not shipped UI.
// The changes view's Commit and Push (cx-ncc.1) over a fake GitWrite: the toolbar with the branch
// ahead, the commit form (Staged or All, Include new files listing them), a busy commit, and a
// refused push with git's output, Retry and Refresh.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { GitToolbarButtons, GitWriteBar } from "./GitActions";
import type { GitWrite, GitWriteState } from "./useGitWrite";

type Props = { formOpen: boolean; state?: GitWriteState; statusFailed?: boolean };

const fakeGit = (state?: GitWriteState, statusFailed = false): GitWrite => ({
  available: true,
  status: { branch: "feat/commit-push", upstream: "origin/feat/commit-push", detached: false, ahead: 2, behind: 0 },
  statusFailed,
  state,
  commit: async () => true,
  listNewFiles: async () => ({ paths: ["src/notes/draft.md", "src/notes/todo.md"], skipped: 0 }),
  push: async () => true,
  retry: () => undefined,
  refresh: () => undefined,
  recheck: () => undefined,
  dismiss: () => undefined,
});

function GitActionsGallery({ formOpen: initiallyOpen, state, statusFailed }: Props) {
  const [formOpen, setFormOpen] = useState(initiallyOpen);
  const git = fakeGit(state, statusFailed);
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8, padding: 12 }}>
      <div style={{ display: "flex", gap: 6 }}>
        <GitToolbarButtons git={git} formOpen={formOpen} onToggleForm={() => setFormOpen(!formOpen)} />
      </div>
      <GitWriteBar git={git} formOpen={formOpen} onCloseForm={() => setFormOpen(false)} />
    </div>
  );
}

const message = () => ({ role: "textbox", name: "Commit message" }) as const;

/// All with Include new files lists the new files before Commit is offered.
const includeNew: Play = async (ctx) => {
  await ctx.click({ role: "radio", name: "All" });
  await ctx.click({ role: "checkbox", name: "Include new files" });
  await ctx.waitFor(() => ctx.document.body.textContent?.includes("src/notes/draft.md"));
};

/// The scope radios are one native radio group that arrows move through; Escape in the message
/// closes the form. WebKit does not focus a radio on click, so the play focuses Staged.
const keyboard: Play = async (ctx) => {
  await ctx.focus({ role: "radio", name: "Staged" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => (ctx.find({ role: "radio", name: "All" }) as HTMLInputElement).checked);
  await ctx.focus(message());
  await ctx.type("Fix the commit form keys");
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-git-form"));
};

export default componentEntry<Props>({
  id: "agent-pane.changes-git-actions",
  title: "Changes Commit and Push",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/changes/GitActions.tsx#GitToolbarButtons",
    "agent-session/acpmux/changes/GitActions.tsx#GitWriteBar",
  ],
  load: async () => GitActionsGallery,
  styles: () => Promise.all([import("../styles.css"), import("./changes.css")]),
  widths: { narrow: 320, normal: 480, wide: 640 },
  variants: {
    toolbar: {
      note: "The form closed: Commit, and Push with the branch two commits ahead.",
      props: { formOpen: false },
    },
    "commit-form": { note: "The open form: a message, Staged or All, Cancel and Commit.", props: { formOpen: true } },
    "include-new": {
      note: "All with Include new files lists the new files before Commit is offered.",
      props: { formOpen: true },
      play: includeNew,
      checks: {
        layoutShiftMax: {
          value: 0.05,
          reason: "Choosing All adds Include new files to the row, so the hint and buttons move along.",
        },
      },
    },
    keyboard: {
      note: "Arrows move the scope radios; Escape in the message closes the form.",
      props: { formOpen: true },
      play: keyboard,
      checks: {
        layoutShiftMax: {
          value: 0.05,
          reason: "Choosing All adds Include new files to the row, so the hint and buttons move along.",
        },
      },
    },
    busy: {
      note: "A commit in flight: the form and buttons wait.",
      props: { formOpen: true, state: { phase: "busy", op: "commit" } },
    },
    "push-refused": {
      note: "A refused push with git's output, Retry and Refresh.",
      props: {
        formOpen: false,
        state: {
          phase: "failed",
          op: "push",
          text: "The remote has commits you don't have. Pull, then push again.",
          failure: {
            kind: "refused",
            reason: "non_fast_forward",
            output: "! [rejected] feat/commit-push -> feat/commit-push (fetch first)",
          },
          canRetry: true,
          canRefresh: true,
        },
      },
    },
  },
});
